#!/usr/bin/env bash
# Merge-vocabulary guard. The governor's merge vocabulary is "allowlisted" (auto-merge,
# GOVERN_MERGE_REPOS) vs "human-merge" (PR-only, derived GOVERN_HUMAN_MERGE_REPOS), never the
# fleet-shaped "backend"/"frontend" repo-class names that leaked into early templates. Blocks the
# old vocabulary and the old `frontend-left-open` disposition string from returning in the
# mechanism scripts, and names the new terms so a silent re-rename fails here first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

MECH_FILES=(
  "$DIR/../merge-pr.sh"
  "$DIR/../resolve-ticket.sh"
  "$DIR/../dry-run.sh"
  "$DIR/../preflight-base-ci.sh"
  "$DIR/../lib/common.sh"
  "$DIR/../../lib/workspace.sh"
)

# The old disposition string must not survive anywhere under the govern dir (mechanism + tests).
hits="$(grep -r --exclude="$(basename "${BASH_SOURCE[0]}")" 'frontend-left-open' "$DIR/.." || true)"
assert_eq "$hits" "" "old frontend-left-open disposition string is gone from the govern tree"

# The old repo-class vocabulary must not survive in the merge mechanism scripts or the workspace
# config template. (Fixture repos literally NAMED backend/frontend in test fixtures and exec.sh's
# repo-name match patterns are outside this list on purpose.)
for f in "${MECH_FILES[@]}"; do
  hits="$(grep -icE 'frontend|backend' "$f" || true)"
  assert_eq "$hits" "0" "$(basename "$f") carries no backend/frontend merge vocabulary"
done

# Name the NEW terms: the disposition and the class word must be present, so a future rename that
# forgets its consumers fails here instead of stranding the vocabulary half-migrated.
assert_contains "$(cat "$DIR/../resolve-ticket.sh")" "human-merge-left-open" \
  "the human-merge left-open disposition exists"
assert_contains "$(cat "$DIR/../merge-pr.sh")" "human-merge" \
  "merge-pr.sh speaks the human-merge vocabulary"

assert_done
