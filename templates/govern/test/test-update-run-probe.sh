#!/usr/bin/env bash
# Regression: the live-run probe machinery (wsp_run_live and the pending-sync markers) ships in
# scripts/lib/run-probe.sh, a mechanism lib the update installs and refreshes through the keep
# machinery, NOT in the workspace.sh template, the one file /shiploop:update never regenerates.
# The workspace.sh template holds only the knobs (GOVERN_RUN_PROBE, GOVERN_POST_MERGE_SYNC), so a
# fresh scaffold and a workspace scaffolded before the helpers shipped behave identically.
#   a. fresh scaffold: workspace.sh defines no probe helper; with the lib absent (deleted here to
#      simulate a pre-1.20.7 workspace whose update never delivered it) the negative control shows
#      the old bug: a declared probe counts as LIVE forever and no pending-sync marker is written.
#   b. one /shiploop:update run installs scripts/lib/run-probe.sh.
#   c. after it: probe exit 0 skips the checkout, writes the marker the SessionStart hook prints;
#      probe exit 1 lets sync.sh fast-forward and clears the marker; a declared probe whose file is
#      missing counts as LIVE with the documented warning.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LOG="$ROOT/out.log"

run_scaffold() { # <workspace> [extra scaffold args...]
  local ws="$1"; shift
  bash "$SCAFFOLD" --workspace-dir "$ws" --templates "$TEMPLATES" "$@" --yes </dev/null >"$LOG" 2>&1 &
  bg_reap "$!"
  wait $!
}

W="$ROOT/ws"; mkdir -p "$W"
run_scaffold "$W" --pm npm --org testorg --repos "alpha::echo alpha" \
  --merge-allowlist "" --worktree-base "$W.wt" --component workspace-sh
for c in core-scripts govern; do run_scaffold "$W" --component "$c"; done

# ── a. fresh scaffold + the lib never arrived = the pre-1.20.7 shape ────────────────────────
grep -q '^wsp_run_live()' "$W/scripts/lib/workspace.sh" && defs=yes || defs=no
assert_eq "$defs" "no" "a. fresh scaffold: workspace.sh defines no probe helper (knobs only)"
[ -x "$W/scripts/lib/run-probe.sh" ] && lib=yes || lib=no
assert_eq "$lib" "yes" "a. fresh scaffold: the probe lib is installed"
mv "$W/scripts/lib/run-probe.sh" "$ROOT/run-probe.stowed"

git init -q --bare -b main "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$W/alpha" 2>/dev/null
( cd "$W/alpha" && git config user.email t@t && git config user.name t \
  && echo a > a.txt && git add a.txt && git commit -qm a && git push -q origin main -u 2>/dev/null )
git init -q -b main "$W" && git -C "$W" config user.email t@t && git -C "$W" config user.name t
git clone -q "$ROOT/origin.git" "$ROOT/pusher" 2>/dev/null
( cd "$ROOT/pusher" && git config user.email t@t && git config user.name t )
lag() { ( cd "$ROOT/pusher" && echo "$1" > "lag$1.txt" && git add . && git commit -qm "lag $1" \
  && git push -q origin main ); git -C "$ROOT/origin.git" rev-parse main; }

cat > "$W/probe.sh" <<'PROBE'
#!/usr/bin/env bash
exit "$(cat "$PROBE_RC_FILE" 2>/dev/null || echo 0)"
PROBE
chmod +x "$W/probe.sh"
export PROBE_RC_FILE="$ROOT/probe.rc"

origin_head="$(lag 1)"
h_before="$(git -C "$W/alpha" rev-parse main)"
echo 0 > "$PROBE_RC_FILE"
( cd "$W" && GOVERN_RUN_PROBE=probe.sh bash "$W/scripts/sync.sh" >/dev/null 2>&1 )
h1="$(git -C "$W/alpha" rev-parse main)"
[ "$h1" = "$h_before" ] && m1=same || m1=moved
assert_eq "$m1" "same" \
  "a. negative control (lib absent, probe declared): the checkout counts as LIVE and is not moved"
[ -f "$W/governor/.pending-sync/alpha" ] && mk1=yes || mk1=no
assert_eq "$mk1" "no" "a. ...and the pre-1.20.7 bug shows: no pending-sync marker is written"

# ── b. one /shiploop:update run installs the lib ────────────────────────────────────────────────
run_scaffold "$W" --component core-scripts
[ -x "$W/scripts/lib/run-probe.sh" ] && lib2=yes || lib2=no
assert_eq "$lib2" "yes" "b. one update run installs scripts/lib/run-probe.sh"
cmp -s "$W/scripts/lib/run-probe.sh" "$TEMPLATES/lib/run-probe.sh" && same=hub || same=other
assert_eq "$same" "hub" "b. ...byte-identical to the shipped lib"

# ── c. with the lib in place the probe works ────────────────────────────────────────────────────
echo 0 > "$PROBE_RC_FILE"
origin_head="$(lag 2)"
h_before="$(git -C "$W/alpha" rev-parse main)"
out="$( cd "$W" && GOVERN_RUN_PROBE=probe.sh bash "$W/scripts/sync.sh" 2>&1 )"
h2="$(git -C "$W/alpha" rev-parse main)"
[ "$h2" = "$h_before" ] && m2=same || m2=moved
assert_eq "$m2" "same" "c. probe exit 0: sync skips the live checkout"
assert_contains "$(cat "$W/governor/.pending-sync/alpha" 2>/dev/null || true)" "$origin_head" \
  "c. ...and writes the marker with the origin sha"
hookout="$( cd "$W" && bash "$W/scripts/check-main-on-main.sh" 2>&1 )"
assert_contains "$hookout" "alpha: local main is behind origin (live-run since" \
  "c. the SessionStart hook prints the pending marker"

echo 1 > "$PROBE_RC_FILE"
out="$( cd "$W" && GOVERN_RUN_PROBE=probe.sh bash "$W/scripts/sync.sh" 2>&1 )"
assert_eq "$(git -C "$W/alpha" rev-parse main)" "$origin_head" "c. probe exit 1: sync fast-forwards"
[ -f "$W/governor/.pending-sync/alpha" ] && mk3=yes || mk3=no
assert_eq "$mk3" "no" "c. ...and the successful fast-forward clears the marker"

origin_head="$(lag 3)"
h_before="$(git -C "$W/alpha" rev-parse main)"
mv "$W/probe.sh" "$W/probe.stowed"
out="$( cd "$W" && GOVERN_RUN_PROBE=probe.sh bash "$W/scripts/sync.sh" 2>&1 )"
h3="$(git -C "$W/alpha" rev-parse main)"
[ "$h3" = "$h_before" ] && m3=same || m3=moved
assert_eq "$m3" "same" "c. a declared probe whose file is missing counts as LIVE"
assert_contains "$out" "missing or not executable" "c. ...with the documented warning"

assert_done
