#!/usr/bin/env bash
# land-resolution.sh commits ONLY the paths it staged: the resolve commit used to be a bare
# `git commit` (no pathspec), which publishes the WHOLE index — an operator's unrelated staged
# work rode in under "resolve #N". The queue foreign-changes guard upstream cannot catch this: it
# inspects tickets.md's own state, and unrelated STAGED files leave tickets.md clean while
# poisoning the index.
# Negative control: the resolve still commits the queue file (and seq), and an empty staging set
# never commits (an empty pathspec would fall back to the whole index).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
BK="$DIR/../land-resolution.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b main )

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — some ticket

**Severity:** Medium

Done when: it is done.

---
TIX
printf 'operator work\n' > "$T/notes-operator.txt"
git -C "$T" add -A
git -C "$T" commit -qm init
SNAPSHOT="$(git -C "$T" rev-parse HEAD)"

# The operator stages an unrelated refactor deletion (tickets.md stays clean).
printf 'delete me later\n' > "$T/staged-refactor.txt"
git -C "$T" add "$T/staged-refactor.txt"

report='{"status":"resolved","pr":{"repo":"alpha","number":7},"newTickets":[],"lessonPatch":null}'
out="$( cd "$T" && printf '%s' "$report" | GOVERN_TICKETS_FILE="$T/queue/tickets.md" GOVERN_NO_PUSH=1 bash "$BK" 60 2>&1 )"
code=$?
assert_eq "$code" "0" "the resolve lands (control)"

# The resolve commit carries tickets.md but NOT the operator's staged file.
last_msg="$(git -C "$T" log -1 --name-only --format=%s)"
assert_contains "$last_msg" "resolve #60" "the resolve commit exists"
assert_contains "$last_msg" "queue/tickets.md" "the resolve commit carries the queue file"
if printf '%s' "$last_msg" | grep -q "staged-refactor.txt"; then
  echo "FAIL - the operator's staged file rode in under the resolve commit"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - the operator's staged file is NOT in the resolve commit"
fi

# And it survives the landing: still staged, never committed away or discarded.
status="$(git -C "$T" status --porcelain)"
assert_contains "$status" "A  staged-refactor.txt" "the operator's staged work is still staged after the resolve"

assert_done
