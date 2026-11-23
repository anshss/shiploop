#!/usr/bin/env bash
# `npm run sync` (sync.sh) and the opt-in live-run probe: before either HEAD move, a checkout the probe
# reports live is skipped and leaves a pending-sync marker; with no probe declared the behavior is
# unchanged; any successful fast-forward deletes an existing marker.
#   1. live (probe exit 0): skipped with the documented warning, HEAD untouched, live-run marker.
#   2. the same on a feature branch (the `fetch origin main:main` move): local main untouched too.
#   3. no probe declared: fast-forwards, writes no marker.
#   4. a successful fast-forward deletes an existing marker, on main and from a feature branch.
#   5. a probe that reports no live run behaves like no probe.
# Negative control (the pre-1.20.7 shape): with the helpers' lib absent, a declared probe counts as
# LIVE: the checkout is skipped forever and no marker is ever written.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$DIR/../../sync.sh"
PROBE_LIB="$DIR/../../lib/run-probe.sh"
[[ -f "$SYNC" && -f "$PROBE_LIB" ]] || { echo "SKIP: sync.sh / run-probe.sh template not found"; exit 77; }
source "$DIR/assert.sh"
set +e

S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
mkdir -p "$S/scripts/lib" "$S/governor"
cp "$SYNC" "$S/scripts/sync.sh"
cp "$PROBE_LIB" "$S/scripts/lib/run-probe.sh"
cat > "$S/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
META_ROOT="\${META_ROOT:-$S}"
ROOT_PM="npm"
REPOS=(alpha)
EOF

git init -q --bare -b main "$S/origin.git"
git clone -q "$S/origin.git" "$S/alpha" 2>/dev/null
( cd "$S/alpha" && git config user.email t@t && git config user.name t \
  && git checkout -q -b main 2>/dev/null; echo a > a.txt && git add a.txt && git commit -qm a && git push -q origin main -u 2>/dev/null )
git clone -q "$S/origin.git" "$S/pusher" 2>/dev/null
( cd "$S/pusher" && git config user.email t@t && git config user.name t )
LAG=0
lag() { LAG=$((LAG+1)); ( cd "$S/pusher" && echo "$LAG" > "lag$LAG.txt" && git add . && git commit -qm "lag $LAG" && git push -q origin main ); origin_head="$(git -C "$S/origin.git" rev-parse main)"; }
main_head() { git -C "$S/alpha" rev-parse main; }
state() { [[ "$(main_head)" == "$origin_head" ]] && echo synced || echo untouched; }
MARKER="$S/governor/.pending-sync/alpha"
marker() { cat "$MARKER" 2>/dev/null || echo "(none)"; }
run_sync() { ( cd "$S" && env "$@" bash "$S/scripts/sync.sh" 2>&1 ); }

cat > "$S/probe.sh" <<'PROBE'
#!/usr/bin/env bash
exit "$(cat "$PROBE_RC_FILE" 2>/dev/null || echo 0)"
PROBE
chmod +x "$S/probe.sh"
export PROBE_RC_FILE="$S/probe.rc"

# ── 1. live run, checkout on main ────────────────────────────────────────────────────────────────
lag; echo 0 > "$PROBE_RC_FILE"
out="$(run_sync GOVERN_RUN_PROBE=probe.sh)"
assert_eq "$(state)" "untouched" "1. a live run: the repo is skipped and main is not moved"
assert_contains "$out" "LIVE RUN reported by the run probe: skipped, run sync again when it ends" "1. ...with the documented warning"
assert_contains "$(marker)" "$origin_head" "1. ...and the marker records the origin sha"
assert_contains "$(marker)" " live-run" "1. ...and the reason is live-run"

# ── 2. live run, checkout on a feature branch ────────────────────────────────────────────────────
( cd "$S/alpha" && git checkout -q -b feature )
rm -f "$MARKER"
out="$(run_sync GOVERN_RUN_PROBE=probe.sh)"
assert_eq "$(state)" "untouched" "2. a live run on a feature branch: local main is not moved either"
assert_contains "$(marker)" " live-run" "2. ...and a marker is written"

# ── 4a. a successful fast-forward from the feature branch deletes the marker ─────────────────────
echo 1 > "$PROBE_RC_FILE"
out="$(run_sync GOVERN_RUN_PROBE=probe.sh)"
assert_eq "$(state)" "synced" "5. a probe reporting no live run: local main is updated from the feature branch"
assert_eq "$(marker)" "(none)" "4. ...and the marker is deleted"
( cd "$S/alpha" && git checkout -q main )

# ── 3 / 4b. no probe declared on main: unchanged behavior, marker deleted ────────────────────────
lag
mkdir -p "$S/governor/.pending-sync"; printf 'deadbeef 2026-01-01T00:00:00Z live-run\n' > "$MARKER"
out="$(run_sync A=1)"
assert_eq "$(state)" "synced" "3. no probe declared: main is fast-forwarded exactly as before"
assert_not_contains "$out" "LIVE RUN" "3. ...and no probe output appears"
assert_eq "$(marker)" "(none)" "4. a successful fast-forward on main deletes an existing marker"

# ── 3b. no probe declared and nothing to do: no marker appears ───────────────────────────────────
out="$(run_sync A=1)"
assert_not_contains "$out" "LIVE RUN" "3. an up-to-date repo with no probe is reported without probe output"
assert_eq "$(marker)" "(none)" "3. ...and writes no marker"

# ── 6. negative control (the pre-1.20.7 shape): helpers' lib absent ─────────────────────────────
# A workspace whose scripts/lib/run-probe.sh never arrived (an update that has not run yet) keeps the
# old fail-safe: a declared probe counts as LIVE forever and no marker is written.
S2="$(mktemp -d)"
mkdir -p "$S2/scripts/lib" "$S2/governor"
cp "$SYNC" "$S2/scripts/sync.sh"
cat > "$S2/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
META_ROOT="\${META_ROOT:-$S2}"
ROOT_PM="npm"
REPOS=(alpha)
EOF
git init -q --bare -b main "$S2/origin.git"
git clone -q "$S2/origin.git" "$S2/alpha" 2>/dev/null
( cd "$S2/alpha" && git config user.email t@t && git config user.name t \
  && echo a > a.txt && git add a.txt && git commit -qm a && git push -q origin main -u 2>/dev/null )
git clone -q "$S2/origin.git" "$S2/pusher" 2>/dev/null
( cd "$S2/pusher" && git config user.email t@t && git config user.name t \
  && echo n > n.txt && git add . && git commit -qm n && git push -q origin main )
origin2="$(git -C "$S2/origin.git" rev-parse main)"
( cd "$S2" && GOVERN_RUN_PROBE=probe.sh bash "$S2/scripts/sync.sh" >/dev/null 2>&1 )
h2="$(git -C "$S2/alpha" rev-parse main)"
[ "$h2" != "$origin2" ] && lagged2=lagged || lagged2=synced
assert_eq "$lagged2" "lagged" \
  "6. negative control: no run-probe.sh lib, probe declared: the repo counts as LIVE and main is not moved"
[ -f "$S2/governor/.pending-sync/alpha" ] && m2=yes || m2=no
assert_eq "$m2" "no" "6. ...and the pre-1.20.7 bug shows: no pending-sync marker is written"
rm -rf "$S2"

assert_done
