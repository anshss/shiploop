#!/usr/bin/env bash
# Regression: assert.sh must expose the auto-merge test seam
# (_GOVERN_ASSUME_MERGE_ALLOWED=1) at TOP LEVEL — not only inside mk_ws_stub().
#
# Why: v1.2.0 moved the seam-set from top-level into mk_ws_stub. Any adopter test
# that sources assert.sh and does its own workspace bootstrap (i.e. never calls
# mk_ws_stub) then lost the seam and merge-pr.sh would exit 5 with
# "external-author" — silently red for ~14 tests on adopter instances.
#
# v1.2.1 emits BOTH: top-level (back-compat) + inside mk_ws_stub (so callers that
# unset it earlier land on 1 after the stub runs). This test locks the top-level
# path in — it deliberately does NOT call mk_ws_stub.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Unset first so we're proving assert.sh sets it, not the parent env.
unset _GOVERN_ASSUME_MERGE_ALLOWED

source "$DIR/assert.sh"

# NOTE: intentionally do NOT call mk_ws_stub.

assert_eq "${_GOVERN_ASSUME_MERGE_ALLOWED:-}" "1" \
  "assert.sh sets _GOVERN_ASSUME_MERGE_ALLOWED=1 at top level (back-compat seam)"

assert_done
