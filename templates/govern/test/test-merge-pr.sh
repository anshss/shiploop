#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"

# Hermetic config: alpha is auto-mergeable, web is frontend (PR-only) — independent of the live workspace.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# Frontend repo → refused (exit 2), regardless of CI.
set +e
out="$(GOVERN_ECHO=1 "$MERGE" web 9 2>&1)"; code=$?
set -e
assert_eq "$code" "2" "web (frontend) merge refused with exit 2"
assert_contains "$out" "PR-only" "refusal explains frontend is PR-only"

# Allowlisted repo in echo mode → prints the gh merge command, does not run it, exit 0.
set +e
out2="$(GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code2=$?
set -e
assert_eq "$code2" "0" "alpha merge in echo mode exits 0"
assert_contains "$out2" "gh pr merge 42" "echo mode prints the merge command"
assert_done
