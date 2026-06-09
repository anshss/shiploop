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

cmd=(gh pr merge "$PR" --repo "$GITHUB_ORG/$REPO" --squash --delete-branch)
if [[ "${GOVERN_ECHO:-0}" == "1" ]]; then
  printf 'WOULD RUN: %s\n' "${cmd[*]}"
else
  govern::log "merging $REPO#$PR (squash)"
  "${cmd[@]}"
fi
