#!/usr/bin/env bash
# Merge a PR IF its repo is auto-mergeable AND CI is green. Usage: merge-pr.sh <repo> <pr>
# Refuses frontend repos with exit 2. GOVERN_ECHO=1 prints instead of running.
# GOVERN_SKIP_CI=1 skips the green check (tests/dry-run only).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

REPO="${1:?repo required}"; PR="${2:?pr number required}"

if ! govern::is_merge_repo "$REPO"; then
  govern::log "refusing to merge $REPO#$PR — frontend is PR-only (other account merges)."
  exit 2
fi

if [[ "${GOVERN_SKIP_CI:-0}" != "1" ]]; then
  state="$("$DIR/await-ci.sh" "$REPO" "$PR")"
  # "none" = repo has no PR-level checks (CI runs post-merge, e.g. a deploy pipeline) → treat as
  # mergeable (operator decision). Only red/pending block.
  if [[ "$state" != "green" && "$state" != "none" ]]; then
    govern::log "not merging $REPO#$PR — CI is '$state' (not green/none)."
    exit 3
  fi
fi

# --delete-branch removes the REMOTE ticket-<N> head on merge (a surviving origin/ticket-<N>
# collides when the ticket is re-opened and re-run).
cmd=(gh pr merge "$PR" --repo "$(govern::repo_slug "$REPO")" --squash --delete-branch)
if [[ "${GOVERN_ECHO:-0}" == "1" ]]; then
  printf 'WOULD RUN: %s\n' "${cmd[*]}"
else
  govern::log "merging $REPO#$PR (squash)"
  "${cmd[@]}"
  # Also delete the LOCAL ticket-<N> branch in the repo's checkout. `gh pr merge --repo X
  # --delete-branch` reliably removes only the remote head when run from outside a clone of X, so
  # a local ticket-<N> branch can survive in the sub-repo (or the meta checkout for harness PRs)
  # and make a later re-run check out the merged branch instead of branching fresh off origin/main.
  #
  # At merge time the worker's worktree almost always still has ticket-<N> CHECKED OUT, so a bare
  # `branch -D` would be a structurally-guaranteed no-op — git refuses to delete a branch that's
  # checked out in a worktree. Cleanup of that case is tied to worktree TEARDOWN (worktree:rm
  # removes the worktree first, THEN deletes the branch). We only `branch -D` here when the branch
  # is NOT checked out in any worktree — i.e. a genuinely-lingering local branch, which is exactly
  # the case where `branch -D` can actually succeed.
  head="$(gh pr view "$PR" --repo "$(govern::repo_slug "$REPO")" --json headRefName -q '.headRefName' 2>/dev/null || true)"
  if [[ -n "$head" ]]; then
    localdir="$(govern::repo_localdir "$REPO")"
    if [[ -d "$localdir/.git" || -f "$localdir/.git" ]] && git -C "$localdir" rev-parse --verify "$head" >/dev/null 2>&1; then
      if git -C "$localdir" worktree list --porcelain 2>/dev/null | grep -q "^branch refs/heads/${head}$"; then
        : # checked out in a worktree → worktree:rm deletes it on teardown; skip silently (no noise)
      else
        git -C "$localdir" branch -D "$head" >/dev/null 2>&1 \
          && govern::log "deleted lingering local branch $head in $localdir" \
          || govern::log "could not delete local branch $head in $localdir — harmless"
      fi
    fi
  fi
fi
