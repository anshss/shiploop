#!/usr/bin/env bash
# The post-merge fast-forward (GOVERN_POST_MERGE_SYNC=1) and the opt-in live-run probe
# (GOVERN_RUN_PROBE, wsp_run_live in lib/workspace.sh), exercised through resolve-ticket.sh.
#   a. a probe exiting 0 leaves the checkout untouched and writes a `live-run` marker.
#   b. the probe is called as `<probe> <repo> <checkout-dir>`.
#   c. a declared probe that is missing, or not executable, counts as LIVE.
#   d. a probe slower than the 5s bound counts as LIVE.
#   e. a dirty checkout (the fast-forward fails) writes an `ff-failed` marker.
#   f. a probe exiting non-zero (not live) fast-forwards and deletes an existing marker.
#   g. no probe declared: exactly the plain behavior, a marker only when the fast-forward is skipped
#      or fails, and a successful fast-forward deletes it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
PROBE_LIB="$DIR/../../lib/run-probe.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }
[[ -f "$PROBE_LIB" ]] || { echo "SKIP: run-probe.sh template not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
# The stub workspace.sh has no probe helpers: common.sh sources them from the shipped
# scripts/lib/run-probe.sh mechanism lib, exactly as a real workspace does.
cp "$PROBE_LIB" "$T/scripts/lib/run-probe.sh"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue" "$T/governor"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"
[[ -f "$DIR/../post-merge-check.sh" ]] && cp "$DIR/../post-merge-check.sh" "$T/bin/"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *headRefName*) echo "stub-branch" ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin"/*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH"
printf '# Tickets\n\n## #41 - x\n\n**Severity:** Low\n\nb\n\n---\n' > "$T/queue/tickets.md"
( cd "$T" && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1 )

rpt() { printf '{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"prs":[]}'; }
sync_rt() { # [env assignments...] -> stderr of a green resolve with the post-merge sync knob on
  ( cd "$T" && printf '%s' "$(rpt)" | env GOVERN_POST_MERGE_SYNC=1 "$@" bash "$T/bin/resolve-ticket.sh" 41 2>&1 >/dev/null )
}

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/alpha" 2>/dev/null
( cd "$T/alpha" && git config user.email t@t && git config user.name t \
  && git checkout -q -b main 2>/dev/null; echo a > a.txt && git add a.txt && git commit -qm a && git push -q origin main \
  && git remote set-head origin main >/dev/null 2>&1 )
git clone -q "$T/origin.git" "$T/pusher" 2>/dev/null
( cd "$T/pusher" && git config user.email t@t && git config user.name t )
LAG=0
lag() { # advance origin by one commit that adds lag<N>.txt; sets origin_head and LAGFILE
  LAG=$((LAG+1)); LAGFILE="lag$LAG.txt"
  ( cd "$T/pusher" && echo "$LAG" > "$LAGFILE" && git add "$LAGFILE" && git commit -qm "lag $LAG" && git push -q origin main )
  origin_head="$(git -C "$T/origin.git" rev-parse main)"
}
alpha_head() { git -C "$T/alpha" rev-parse HEAD; }
state() { [[ "$(alpha_head)" == "$origin_head" ]] && echo synced || echo untouched; }
MARKER="$T/governor/.pending-sync/alpha"
marker() { cat "$MARKER" 2>/dev/null || echo "(none)"; }

PROBE_LOG="$T/probe.log"
cat > "$T/probe.sh" <<'PROBE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROBE_LOG"
exit "$(cat "$PROBE_RC_FILE" 2>/dev/null || echo 0)"
PROBE
chmod +x "$T/probe.sh"
export PROBE_LOG PROBE_RC_FILE="$T/probe.rc"

# ── a/b. a probe that reports a live run ─────────────────────────────────────────────────────────
lag
echo 0 > "$PROBE_RC_FILE"
err="$(sync_rt GOVERN_RUN_PROBE=probe.sh)"
assert_eq "$(state)" "untouched" "a. a live run (probe exit 0) leaves the checkout untouched"
assert_contains "$err" "LIVE RUN reported by the run probe" "a. ...and says why on stderr"
assert_contains "$(marker)" "$origin_head" "a. ...and the marker records the origin sha"
assert_contains "$(marker)" " live-run" "a. ...and the reason is live-run"
assert_eq "$(marker | wc -w | tr -d ' ')" "3" "a. ...and the marker is one line of three fields (sha time reason)"
assert_contains "$(cat "$PROBE_LOG")" "alpha $T/alpha" "b. the probe is called as '<probe> <repo> <checkout-dir>'"

# ── c. declared but missing / not executable counts as live ──────────────────────────────────────
rm -f "$MARKER"
err="$(sync_rt GOVERN_RUN_PROBE=no-such-probe.sh)"
assert_eq "$(state)" "untouched" "c. a declared probe that does not exist is treated as live: checkout untouched"
assert_contains "$(marker)" " live-run" "c. ...with a live-run marker"
assert_contains "$err" "missing or not executable" "c. ...and a warning that the probe itself is broken"
printf '#!/bin/sh\nexit 1\n' > "$T/noexec.sh"; chmod 644 "$T/noexec.sh"
rm -f "$MARKER"
err="$(sync_rt GOVERN_RUN_PROBE=noexec.sh)"
assert_eq "$(state)" "untouched" "c. a non-executable probe is treated as live: checkout untouched"

# ── d. a probe over the 5s bound counts as live ──────────────────────────────────────────────────
printf '#!/bin/sh\nsleep 30\nexit 1\n' > "$T/slow.sh"; chmod +x "$T/slow.sh"
rm -f "$MARKER"
start="$(date +%s)"
err="$(sync_rt GOVERN_RUN_PROBE=slow.sh)"
elapsed=$(( $(date +%s) - start ))
assert_eq "$(state)" "untouched" "d. a probe slower than the bound is treated as live: checkout untouched"
assert_contains "$err" "did not answer within 5s" "d. ...with a timeout warning"
assert_eq "$([[ "$elapsed" -lt 20 ]] && echo bounded || echo "hung ${elapsed}s")" "bounded" "d. ...and the call returned well before the probe's own 30s"

# ── e. a dirty checkout: the fast-forward fails and leaves an ff-failed marker ───────────────────
rm -f "$MARKER"
echo 1 > "$PROBE_RC_FILE"                       # probe: no live run
echo "local" > "$T/alpha/$LAGFILE"              # untracked file the incoming commit would overwrite
err="$(sync_rt GOVERN_RUN_PROBE=probe.sh)"
assert_eq "$(state)" "untouched" "e. a dirty checkout is left untouched"
assert_contains "$err" "not fast-forwarded" "e. ...with the existing note"
assert_contains "$(marker)" " ff-failed" "e. ...and an ff-failed marker"
rm -f "$T/alpha/$LAGFILE"

# ── f. probe reports no live run: fast-forward, and the stale marker is deleted ──────────────────
mkdir -p "$T/governor/.pending-sync"; printf 'deadbeef 2026-01-01T00:00:00Z live-run\n' > "$MARKER"
sync_rt GOVERN_RUN_PROBE=probe.sh >/dev/null
assert_eq "$(state)" "synced" "f. no live run: the checkout is fast-forwarded"
assert_eq "$(marker)" "(none)" "f. ...and a successful fast-forward deletes the marker"

# ── g. no probe declared: the plain behavior ─────────────────────────────────────────────────────
lag
unset GOVERN_RUN_PROBE
sync_rt >/dev/null
assert_eq "$(state)" "synced" "g. no probe declared: fast-forwarded exactly as before"
assert_eq "$(marker)" "(none)" "g. ...and no marker is written"
lag
( cd "$T/alpha" && git checkout -q -b feature )
err="$(sync_rt)"
assert_eq "$(state)" "untouched" "g. no probe, checkout on a feature branch: untouched"
assert_contains "$err" "is on 'feature', not 'main'" "g. ...with the existing note"
assert_contains "$(marker)" " ff-failed" "g. ...and the skip leaves an ff-failed marker"
( cd "$T/alpha" && git checkout -q main )
sync_rt >/dev/null
assert_eq "$(state)" "synced" "g. back on main: fast-forwarded"
assert_eq "$(marker)" "(none)" "g. ...and the marker is gone"
lag
sync_rt GOVERN_POST_MERGE_SYNC=0 GOVERN_RUN_PROBE=probe.sh >/dev/null
assert_eq "$(state)" "untouched" "g. knob 0: the checkout is never touched"
assert_eq "$(marker)" "(none)" "g. knob 0: no marker is written (the sync step does not run at all)"

assert_done
