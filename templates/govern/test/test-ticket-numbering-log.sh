#!/usr/bin/env bash
# The allocator never reissues a number the queue's own history already used. A ticket filed by hand
# and later resolved and deleted leaves no heading in tickets.md and no bump in .ticket-seq, but its
# `file #N` / `resolve #N` / `delete #N` commit subjects still carry it.
#   1. a number present only in a `file #N` subject is never reissued.
#   2. `resolve #N` and `delete #N` count too, case-insensitively, on every ref.
#   3. a `repo#230` PR reference, or a verb glued to a longer word, never raises the number.
#   4. not a git repo: contributes nothing.
#   5. GOVERN_SEQ_PEEK=1 still reads the history and still does not bump the seq file.
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
printf '3\n' > "$SEQ"                      # high-water mark and live file both below the history

# ── 1. a number present only in a `file #N` subject ──────────────────────────────────────────────
( cd "$T" && git commit -q --allow-empty -m "docs(tickets): file #50: filed by hand, later resolved and deleted" )
n="$(govern::next_ticket_number "$TF")"
assert_eq "$n" "51" "1. #50 exists only in a commit subject: the next number is 51, not 6"
assert_eq "$(cat "$SEQ")" "51" "1. ...and the seq file is bumped to it"

# ── 2. resolve / delete verbs, case-insensitive, on every ref ────────────────────────────────────
( cd "$T" && git commit -q --allow-empty -m "docs(tickets): resolve #60 (alpha#9)" )
assert_eq "$(govern::next_ticket_number "$TF")" "61" "2. a 'resolve #60' subject raises the floor"
( cd "$T" && git commit -q --allow-empty -m "queue: Delete #70" )
assert_eq "$(govern::next_ticket_number "$TF")" "71" "2. a 'Delete #70' subject counts (case-insensitive)"
( cd "$T" && git checkout -q -b side && git commit -q --allow-empty -m "docs(tickets): file #80 on another ref" && git checkout -q - )
assert_eq "$(govern::next_ticket_number "$TF")" "81" "2. a subject on a ref that HEAD does not contain still counts (log --all)"

# ── 3. things that must NOT count ────────────────────────────────────────────────────────────────
( cd "$T" && git commit -q --allow-empty -m "fix(thing): tighten the retry (repo#230)" \
          && git commit -q --allow-empty -m "chore: unfile #900 and profile #800" \
          && git commit -q --allow-empty -m "docs: see file-ticket #700 for details" )
assert_eq "$(govern::next_ticket_number "$TF")" "82" "3. repo#230, unfile #900, profile #800 and file-ticket #700 never raise the number"

# ── 4. not a git repo ────────────────────────────────────────────────────────────────────────────
NG="$(mktemp -d)"
printf '# Tickets\n\n## #7 - seven\n\n**Severity:** Low\n\nb\n\n---\n' > "$NG/tickets.md"
assert_eq "$(govern::ticket_logmax "$NG/tickets.md")" "0" "4. a tickets file outside any git repo contributes 0"
assert_eq "$(GOVERN_TICKET_SEQ_FILE="$NG/seq" govern::next_ticket_number "$NG/tickets.md")" "8" "4. ...so the allocator still works off the file alone"
rm -rf "$NG"

# ── 5. peek reads the history and never writes the seq ───────────────────────────────────────────
printf '10\n' > "$SEQ"
n="$(GOVERN_SEQ_PEEK=1 govern::next_ticket_number "$TF")"
assert_eq "$n" "81" "5. GOVERN_SEQ_PEEK=1 reports the history-derived number"
assert_eq "$(cat "$SEQ")" "10" "5. ...and leaves the seq file untouched"

assert_done
