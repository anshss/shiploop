#!/usr/bin/env bash
# The allocator counts exactly two terms: the highest live `## #N` heading in tickets.md and the
# persisted high-water mark in governor/.ticket-seq. Numbers named ONLY in commit subjects
# ("file #N", "resolve #N", "delete #N") never raise the floor: a hand-minted filing that was
# renumbered away must not burn the range above it (the 235/240 incident, 2026-11-25, where two
# bogus "file #N" subjects made the allocator jump a clean serial straight past 110 numbers).
#   1. next = max(live headings, seq) + 1; the seq file is bumped to it.
#   2. a `file #N` / `resolve #N` / `delete #N` commit subject, on any ref, does NOT raise the number.
#   3. GOVERN_SEQ_PEEK=1 computes without writing the seq file.
#   4. not a git repo (or a repo with no subjects): the file and the seq alone decide.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/queue" "$T/governor"
source "$DIR/../lib/common.sh"
TF="$T/queue/tickets.md"
SEQ="$T/governor/.ticket-seq"

( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
printf '# Tickets\n\n## #5 - five\n\n**Severity:** Low\n\nb\n\n---\n' > "$TF"
( cd "$T" && git add -A && git commit -qm "init queue" )
printf '3\n' > "$SEQ"

# ── 1. the two terms: max(live heading, seq) + 1 ────────────────────────────────────────────────
assert_eq "$(govern::next_ticket_number "$TF")" "6" "1. live heading 5, seq 3: next is 6"
assert_eq "$(cat "$SEQ")" "6" "1. ...and the seq file is bumped to it"
printf '9\n' > "$SEQ"
assert_eq "$(govern::next_ticket_number "$TF")" "10" "1. a seq above the live file raises the floor to 10"

# ── 2. commit subjects never raise the floor (regression: the 235/240 burn) ─────────────────────
( cd "$T" && git commit -q --allow-empty -m "docs(tickets): file #50: filed by hand, renumbered away" )
( cd "$T" && git commit -q --allow-empty -m "docs(tickets): resolve #60 (alpha#9)" )
( cd "$T" && git commit -q --allow-empty -m "queue: Delete #70" )
( cd "$T" && git checkout -q -b side && git commit -q --allow-empty -m "docs(tickets): file #80 on another ref" && git checkout -q - )
assert_eq "$(govern::next_ticket_number "$TF")" "11" "2. file/resolve/delete subjects on any ref never raise the number"

# ── 3. peek computes without writing the seq ────────────────────────────────────────────────────
printf '10\n' > "$SEQ"
n="$(GOVERN_SEQ_PEEK=1 govern::next_ticket_number "$TF")"
assert_eq "$n" "11" "3. GOVERN_SEQ_PEEK=1 reports the same number"
assert_eq "$(cat "$SEQ")" "10" "3. ...and leaves the seq file untouched"

# ── 4. not a git repo: the file and the seq alone decide ────────────────────────────────────────
NG="$(mktemp -d)"
printf '# Tickets\n\n## #7 - seven\n\n**Severity:** Low\n\nb\n\n---\n' > "$NG/tickets.md"
assert_eq "$(GOVERN_TICKET_SEQ_FILE="$NG/seq" govern::next_ticket_number "$NG/tickets.md")" "8" "4. a tickets file outside any git repo allocates off the file alone"
rm -rf "$NG"

assert_done
