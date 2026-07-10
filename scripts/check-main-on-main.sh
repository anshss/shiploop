#!/usr/bin/env bash
# SessionStart hook: verify the MAIN checkout (root meta-repo + every sub-repo) is
# on `main`. Generic — repo list comes from scripts/lib/workspace.sh.
#
# Workspace invariant: the main checkout is for reading, planning, and main-branch
# ops only. ALL branch work happens in worktrees (`<pm> run worktree:new -- <slug>`).
# Meta-repo / workspace-coordination files (CLAUDE.md, tickets.md, learnings.md,
# scripts/) commit directly to main here — never branched or PR'd.
#
# Warns (non-blocking, exit 0 always) if any repo in the main checkout has drifted
# off main. Safe to run from inside a worktree: it resolves the primary (main)
# checkout via the shared git-common-dir, so it always verifies the main checkout,
# not the worktree it was invoked from.
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$SELF_ROOT/scripts/lib/workspace.sh" 2>/dev/null || source "$SELF_ROOT/lib/workspace.sh" 2>/dev/null || true

# Resolve the MAIN checkout even when invoked from a worktree. git-common-dir
# points at the primary worktree's .git (relative from the main checkout root,
# absolute from a linked worktree).
COMMON=$(git -C "$SELF_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON" in
  /*) ;;                          # already absolute
  *) COMMON="$SELF_ROOT/$COMMON" ;;
esac
MAIN_CHECKOUT=$(cd "$(dirname "$COMMON")" && pwd 2>/dev/null) || exit 0

OFF=()
check() {
  local label="$1" dir="$2"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
  local br
  br=$(git -C "$dir" branch --show-current 2>/dev/null)
  # Detached HEAD (empty) is fine for sub-repo content; only flag a named
  # non-main branch, which is the drift we care about.
  if [ -n "$br" ] && [ "$br" != "main" ]; then
    OFF+=("$label → $br")
  fi
}

check "(root)" "$MAIN_CHECKOUT"
for r in "${REPOS[@]:-}"; do check "$r" "$MAIN_CHECKOUT/$r"; done

if [ "${#OFF[@]}" -gt 0 ]; then
  echo "⚠ main checkout is NOT all-on-main ($MAIN_CHECKOUT):"
  for o in "${OFF[@]}"; do echo "    $o"; done
  echo "  Workspace rule: the main checkout stays on main; do branch work in a worktree:"
  echo "    ${ROOT_PM:-npm} run worktree:new -- <slug>"
  echo "  To restore: ${ROOT_PM:-npm} run switch -- main   (or per-repo: git -C <repo> switch main)"
fi
exit 0
