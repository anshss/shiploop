#!/usr/bin/env bash
# Regression for ticket #48: a low-disk condition must never silently brick a govern run.
# Covers the two load-bearing pieces of the fix:
#   1. worktree/new.sh disk guard is non-interactive-safe (assume-yes / no-TTY / interactive).
#   2. the "slim a preserved worktree" strip removes regenerable dirs but keeps source + diffs.
# Plus static assertions that spawn-worker passes WORKTREE_ASSUME_YES and run-loop has the
# pre-flight guard + slim calls wired in.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

# new.sh sources scripts/lib/workspace.sh + worktree/lib/registry.sh (for ROOT_PM, wsp_repos_csv),
# present only in a real workspace; its no-TTY exit-3 message references $ROOT_PM, so under set -u it
# would crash (exit 1, no message) when they're absent — exactly the template layout. Run a verbatim
# copy from a stubbed scripts/ tree that mirrors the workspace layout so the guard branches are
# exercised faithfully with no aquanode workspace present (#255).
SB="$(mktemp -d)"
mkdir -p "$SB/scripts/worktree/lib" "$SB/scripts/lib"
cp "$DIR/../../worktree/new.sh" "$SB/scripts/worktree/new.sh"
: > "$SB/scripts/worktree/lib/registry.sh"
cat > "$SB/scripts/lib/workspace.sh" <<'EOF'
ROOT_PM=npm
WORKTREE_BASE=/tmp/wt-stub
wsp_repos_csv() { echo alpha; }
EOF
NEW="$SB/scripts/worktree/new.sh"

# ── 1. new.sh disk guard branches (check-only mode → exits right after the guard) ──
# assert.sh runs `set -e`, so capture the (intentionally non-zero) exit codes safely.
WORKTREE_FREE_GB_OVERRIDE=10 WORKTREE_DISK_CHECK_ONLY=1 bash "$NEW" diag </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "0" "free>=5GB: guard is a no-op (exit 0)"

WORKTREE_FREE_GB_OVERRIDE=2 WORKTREE_DISK_CHECK_ONLY=1 bash "$NEW" diag </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "3" "free<5GB + no TTY + no assume-yes: distinct exit 3 (NOT a silent abort)"

WORKTREE_FREE_GB_OVERRIDE=2 WORKTREE_ASSUME_YES=1 WORKTREE_DISK_CHECK_ONLY=1 bash "$NEW" diag </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "0" "free<5GB + WORKTREE_ASSUME_YES=1: proceeds (exit 0)"

# the no-TTY branch must emit an actionable message, not vanish
msg="$(WORKTREE_FREE_GB_OVERRIDE=1 WORKTREE_DISK_CHECK_ONLY=1 bash "$NEW" diag </dev/null 2>&1 >/dev/null || true)"
assert_contains "$msg" "WORKTREE_ASSUME_YES=1" "no-TTY guard tells the caller how to proceed"

# ── 2. the slim strip: regenerable dirs go, source + uncommitted diffs stay ──
T="$(mktemp -d)"; trap 'rm -rf "$T" "$SB"' EXIT
mkdir -p "$T/sub/node_modules/pkg" "$T/sub/.next/cache" "$T/sub/dist" "$T/sub/src"
echo junk > "$T/sub/node_modules/pkg/index.js"
echo built > "$T/sub/.next/cache/x"
echo dist  > "$T/sub/dist/bundle.js"
echo source > "$T/sub/src/app.ts"
echo "uncommitted work" > "$T/sub/src/wip.ts"
# exact strip command used by run-loop's slim_worktree()
find "$T" -type d \( -name node_modules -o -name .next -o -name dist \) -prune -exec rm -rf {} + 2>/dev/null || true
assert_eq "$([ -d "$T/sub/node_modules" ] && echo y || echo n)" "n" "slim removes node_modules"
assert_eq "$([ -d "$T/sub/.next" ] && echo y || echo n)" "n" "slim removes .next"
assert_eq "$([ -d "$T/sub/dist" ] && echo y || echo n)" "n" "slim removes dist"
assert_eq "$(cat "$T/sub/src/app.ts")" "source" "slim keeps source files"
assert_eq "$(cat "$T/sub/src/wip.ts")" "uncommitted work" "slim keeps uncommitted work"

# ── 3. wiring is actually in place (so the fix can't silently regress) ──
assert_contains "$(cat "$SPAWN")" "WORKTREE_ASSUME_YES=1" "spawn-worker passes WORKTREE_ASSUME_YES to worktree:new"
assert_contains "$(cat "$RL")" "slim_worktree" "run-loop defines + calls slim_worktree"
assert_contains "$(cat "$RL")" "GOVERN_MIN_FREE_GB" "run-loop has the pre-flight disk guard"

assert_done
