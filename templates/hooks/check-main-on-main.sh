#!/usr/bin/env bash
# SessionStart hook: verify the MAIN checkout (root meta-repo + every sub-repo) is
# on its own default branch. Generic — repo list comes from scripts/lib/workspace.sh.
#
# Workspace invariant: the main checkout is for reading, planning, and main-branch
# ops only. ALL branch work happens in worktrees (`<pm> run worktree:new -- <slug>`).
# Meta-repo / workspace-coordination files (CLAUDE.md, tickets.md, learnings.md,
# scripts/) commit directly to main here — never branched or PR'd.
#
# Warns (non-blocking, exit 0 always) if any repo in the main checkout has drifted
# off its default branch. Safe to run from inside a worktree: it resolves the
# primary (main) checkout via the shared git-common-dir, so it always verifies the
# main checkout, not the worktree it was invoked from.
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

# Resolve a repo's actual default branch, no network calls (SessionStart must
# stay fast): the cached remote symref if one exists, else whichever of
# origin/main / origin/master is present, else "main" as a last resort.
default_branch() {
  local dir="$1" ref
  ref=$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  if git -C "$dir" show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    echo "main"
    return 0
  fi
  if git -C "$dir" show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
    echo "master"
    return 0
  fi
  echo "main"
  return 0
}

OFF=()
check() {
  local label="$1" dir="$2"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
  local br
  br=$(git -C "$dir" branch --show-current 2>/dev/null)
  # Detached HEAD (empty) is fine for sub-repo content; only flag a named
  # branch that isn't this repo's own default, which is the drift we care about.
  [ -n "$br" ] || return 0
  local def
  def=$(default_branch "$dir")
  if [ "$br" != "$def" ]; then
    OFF+=("$label → $br (want $def)")
  fi
  return 0
}

check "(root)" "$MAIN_CHECKOUT"
for r in "${REPOS[@]:-}"; do check "$r" "$MAIN_CHECKOUT/$r"; done

if [ "${#OFF[@]}" -gt 0 ]; then
  echo "⚠ off default branch ($MAIN_CHECKOUT):"
  for o in "${OFF[@]}"; do echo "    $o"; done
  echo "  Restore: ${ROOT_PM:-npm} run switch -- <branch shown above>"
fi
exit 0
