#!/usr/bin/env bash
# Remove a worktree: clean up its deploys, then git-worktree-remove each sub-repo
# and the meta-worktree, then free the registry slot.
#
# Usage:  <pm> run worktree:rm -- <name> [--force] [--keep-branch]
#
# --force        skip the dirty-tree refusal
# --keep-branch  don't delete the sub-repo branches after worktree removal
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"

NAME=""
FORCE=0
KEEP_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
    -h|--help)
      echo "usage: $ROOT_PM run worktree:rm -- <name> [--force] [--keep-branch]"
      exit 0
      ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"; else echo "extra arg: $1" >&2; exit 2; fi
      shift
      ;;
  esac
done

[ -n "$NAME" ] || { echo "usage: $ROOT_PM run worktree:rm -- <name> [--force] [--keep-branch]" >&2; exit 2; }
[ "$NAME" = "__main__" ] && { echo "refusing to remove main checkout" >&2; exit 1; }

WORKTREE_PATH=$(wt_registry_path_for "$NAME") || exit 1

# Dirty-tree check
if [ "$FORCE" -ne 1 ]; then
  for repo in "${REPOS[@]}"; do
    dir="$WORKTREE_PATH/$repo"
    [ -d "$dir" ] || continue
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      echo "✗ '$repo' has uncommitted changes in $dir" >&2
      echo "  pass --force to discard, or commit them first" >&2
      exit 1
    fi
  done
fi

# Run the project-specific session-cleanup hook before tearing down (best-effort).
# This is where project-specific teardown lives — e.g. closing billable test
# deploys against a cloud provider. We do NOT bake that here because it is
# entirely project-specific.
if [ -x "$ROOT/scripts/lib/session-cleanup.sh" ]; then
  echo "→ running scripts/lib/session-cleanup.sh for slot's stack"
  ( cd "$WORKTREE_PATH" && bash "$ROOT/scripts/lib/session-cleanup.sh" ) || \
    echo "  (session-cleanup failed — continuing; stack may already be down)"
fi

# Kill this worktree's orphaned dev stack BEFORE removing the dir (Leak B).
# `git worktree remove` deletes the tree but leaves any dev process (orchestrator /
# server / Next.js) that was booted inside it running — a prod-pointed process then
# outlives its worktree as a zombie squatting the slot's port. The kill is
# OWNERSHIP-scoped (anti-pattern #10): a process on a slot port is killed ONLY if its
# cwd is under THIS worktree, so a parallel session on a colliding slot is never
# cross-killed. Ports come from the worktree's own worktree.env (the WORKTREE_<REPO>_PORT
# vars written by new.sh: slot × SLOT_PORT_STEP offset). If worktree.env is gone we can't
# resolve the ports/owner root — skip gracefully, never an unscoped kill.
kill_worktree_stack() {
  local wt_root="$1" envf="$1/worktree.env"
  [ -f "$envf" ] || { echo "  (no worktree.env — skipping stack kill; nothing to scope to)"; return 0; }
  # shellcheck disable=SC1090
  source "$envf"
  local var port pids pid pcwd killed=0
  # Iterate every WORKTREE_<REPO>_PORT the worktree.env declares (repo-agnostic — no REPOS needed, so
  # this stays self-contained when extracted for testing). WORKTREE_SLOT/OFFSET are skipped (not _PORT).
  for var in ${!WORKTREE_*}; do
    case "$var" in *_PORT) : ;; *) continue ;; esac
    port="${!var:-}"
    [ -n "$port" ] || continue
    pids=$(lsof -ti tcp:"$port" 2>/dev/null) || true
    for pid in $pids; do
      pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      case "$pcwd" in
        "$wt_root"|"$wt_root"/*) kill -9 "$pid" 2>/dev/null && killed=$((killed + 1)) || true ;;
        *) : ;;  # a process from another checkout on this port — never ours to kill
      esac
    done
  done
  [ "$killed" -gt 0 ] && echo "  killed $killed orphaned stack process(es) owned by this worktree"
  return 0
}
echo "→ killing this worktree's dev stack (ownership-scoped)"
kill_worktree_stack "$WORKTREE_PATH"

# Remove each sub-repo worktree
for repo in "${REPOS[@]}"; do
  src="$ROOT/$repo"
  dst="$WORKTREE_PATH/$repo"
  [ -d "$src/.git" ] || [ -f "$src/.git" ] || continue
  if [ -e "$dst" ]; then
    echo "→ removing $repo worktree"
    git -C "$src" worktree remove --force "$dst" 2>&1 | sed "s/^/[$repo] /" || true
  fi
  # Delete the feature branch unless --keep-branch
  if [ "$KEEP_BRANCH" -ne 1 ]; then
    if git -C "$src" rev-parse --verify "$NAME" >/dev/null 2>&1; then
      git -C "$src" branch -D "$NAME" 2>&1 | sed "s/^/[$repo] /" || true
    fi
  fi
done

# Remove meta-repo worktree. The meta root is detached at main (no <name>
# branch — workspace files commit directly to main in the main checkout), so
# there's nothing to `branch -D` here. Guard the legacy case where an older
# worktree:new created a meta branch, so cleaning up pre-existing worktrees
# still works.
echo "→ removing meta-repo worktree"
git -C "$ROOT" worktree remove --force "$WORKTREE_PATH" 2>&1 | sed 's/^/[meta] /' || true
if [ "$KEEP_BRANCH" -ne 1 ] && git -C "$ROOT" rev-parse --verify "$NAME" >/dev/null 2>&1; then
  git -C "$ROOT" branch -D "$NAME" 2>&1 | sed 's/^/[meta] /' || true
fi

# Free slot
FREED_SLOT=$(wt_registry_with_lock wt_registry_remove "$NAME")
echo "✓ Worktree '$NAME' removed; slot $FREED_SLOT freed"
