#!/usr/bin/env bash
# Regression for #28: govern-bookkeep must FAIL CLOSED when TICKETS_FILE's directory is MISSING.
# Otherwise commit_dir resolves to "" and the later `cd "$commit_dir"` (= `cd ""`, a no-op) leaves git
# running against the CURRENT working directory — so bookkeep could commit/push into the WRONG repo
# (it actually did, twice, during the queue/ refactor). The guard must abort and touch NO repo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # GOVERN_WS_ROOT=$T + a stub workspace.sh so common.sh sources cleanly

# A separate "real" repo that bookkeep must NEVER touch. We run bookkeep with cwd INSIDE it — the exact
# danger: if commit_dir is empty, `cd ""` keeps git here and a commit/push would land in THIS repo.
REAL="$T/real"; mkdir -p "$REAL"
( cd "$REAL" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'x\n' > f.txt && git add -A && git commit -q -m init )
before="$( cd "$REAL" && git rev-parse HEAD )"

# TICKETS_FILE points at a MISSING directory → commit_dir resolves empty → bookkeep must die, not cd "".
report='{"status":"resolved","pr":{"repo":"alpha","number":1},"newTickets":[],"lessonPatch":null}'
set +e
out="$( cd "$REAL" && printf '%s' "$report" \
  | GOVERN_TICKETS_FILE="$T/does-not-exist/tickets.md" GOVERN_NO_PUSH=1 bash "$BK" 1 2>&1 )"
code=$?
set -e

assert_eq "$code" "1" "bookkeep aborts (exit 1) when the queue dir is missing"
assert_contains "$out" "not a git work-tree" "aborts with the #28 fail-closed message"
after="$( cd "$REAL" && git rev-parse HEAD )"
assert_eq "$after" "$before" "made NO commit into the current-directory repo"

assert_done
