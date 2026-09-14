#!/usr/bin/env bash
# Regression: a low-disk condition must never silently brick a govern run.
# Covers: worktree/new.sh disk guard is non-interactive-safe (assume-yes / no-TTY / interactive),
# plus a static assertion that the pre-flight guard is wired into pre-dispatch-check.sh (the gate
# a session runs before spawning anything).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
PDC="$DIR/../pre-dispatch-check.sh"

# new.sh sources scripts/lib/workspace.sh + worktree/lib/registry.sh (for ROOT_PM, wsp_repos_csv),
# present only in a real workspace; its no-TTY exit-3 message references $ROOT_PM, so under set -u it
# would crash (exit 1, no message) when they're absent — exactly the template layout. Run a verbatim
# copy from a stubbed scripts/ tree that mirrors the workspace layout so the guard branches are
# exercised faithfully with no real workspace present.
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
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

# ── wiring is actually in place (so the fix can't silently regress) ──
assert_contains "$(cat "$PDC")" "GOVERN_MIN_FREE_GB" "pre-dispatch-check carries the pre-flight disk guard"

assert_done
