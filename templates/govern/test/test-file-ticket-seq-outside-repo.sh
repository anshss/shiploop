#!/usr/bin/env bash
# file-ticket.sh commits every filing even when its seq file lives outside the tickets repo.
#
# The commit is pathspec-scoped to the tickets file AND the seq file. A pathspec git cannot match
# (a seq file outside the repo, as GOVERN_TICKET_SEQ_FILE fixtures place it, or one the repo
# ignores) fails the whole commit, and its `|| true` hid that: the filing stayed staged but
# uncommitted, so the NEXT filing's foreign-changes guard saw a heading it did not write and
# refused with exit 12. Covers:
#   1. two filings in a row with the seq file outside the repo both exit 0 and both are committed;
#   2. a seq file the repo tracks is still committed alongside the tickets file;
#   3. negative control: the same sequence against a copy of file-ticket.sh without the
#      untracked-seq fallback leaves filing one uncommitted and refuses filing two with exit 12.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh arms -e; the rc-expecting runs below need it off
FILE_TICKET="$DIR/../file-ticket.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"

mk_queue_repo() { # <dir> -> a committed repo holding tickets.md
  mkdir -p "$1"
  printf '# Tickets\n\n## #500 - placeholder about an unrelated subsystem\n\nbody\n\n---\n' > "$1/tickets.md"
  ( cd "$1" && git init -q . && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
}

file_one() { # <file-ticket.sh> <queue-dir> <seq-file> <title> -> "<rc>|<number>"
  local out rc=0
  out="$(printf 'Where: x\nObserved: y\nDone when: z\n' \
    | GOVERN_TICKETS_FILE="$2/tickets.md" GOVERN_TICKETS_PARKED_FILE="$2/tickets-parked.md" \
      GOVERN_TICKET_SEQ_FILE="$3" GOVERN_BOOKKEEP_LOCK="$T/locks/$(basename "$2").lock" \
      GOVERN_NO_PUSH=1 bash "$1" "$4" Medium 2>"$T/err.txt")" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

mkdir -p "$T/locks" "$T/outside"

# 1. Seq file outside the repo: both filings exit 0 and both land as commits.
Q="$T/q"; mk_queue_repo "$Q"
r1="$(file_one "$FILE_TICKET" "$Q" "$T/outside/.ticket-seq" "first filing with an outside seq file")"
assert_eq "${r1%%|*}" "0" "1. first filing exits 0"
assert_eq "$(git -C "$Q" status --porcelain -- tickets.md)" "" "1. first filing is committed (tickets.md clean)"
n1="${r1##*|}"
assert_contains "$(git -C "$Q" log -1 --format=%s)" "docs(tickets): file #$n1" "1. HEAD is the first filing's commit"
r2="$(file_one "$FILE_TICKET" "$Q" "$T/outside/.ticket-seq" "second filing right after it")"
assert_eq "${r2%%|*}" "0" "1. second filing exits 0 (no foreign-changes refusal)"
n2="${r2##*|}"
assert_eq "$(grep -cE "^## #${n2:-x}[[:space:]]" "$Q/tickets.md")" "1" "1. second filing's heading is on disk"
assert_eq "$(git -C "$Q" status --porcelain -- tickets.md)" "" "1. second filing is committed too"

# 2. Seq file the repo tracks: still committed with the tickets file.
Q2="$T/q2"; mk_queue_repo "$Q2"
mkdir -p "$Q2/governor"; printf '600\n' > "$Q2/governor/.ticket-seq"
( cd "$Q2" && git add -A && git commit -qm seq ) >/dev/null 2>&1
r3="$(file_one "$FILE_TICKET" "$Q2" "$Q2/governor/.ticket-seq" "filing with a tracked seq file")"
assert_eq "${r3%%|*}" "0" "2. filing with a tracked seq file exits 0"
assert_contains "$(git -C "$Q2" show --name-only --format= HEAD)" "governor/.ticket-seq" "2. the tracked seq file is part of the filing commit"
assert_eq "$(git -C "$Q2" status --porcelain)" "" "2. nothing is left uncommitted"

# 3. Negative control: without the fallback line the first filing stays uncommitted and the
#    second refuses with exit 12.
mkdir -p "$T/neg"
ln -s "$(cd "$DIR/../lib" && pwd)" "$T/neg/lib"
sed '/git ls-files --error-unmatch -- "\$SEQ_FILE"/d' "$FILE_TICKET" > "$T/neg/file-ticket.sh"
assert_eq "$(( $(wc -l < "$FILE_TICKET") - $(wc -l < "$T/neg/file-ticket.sh") ))" "1" "3. the control copy drops exactly the fallback line"
Q3="$T/q3"; mk_queue_repo "$Q3"
r4="$(file_one "$T/neg/file-ticket.sh" "$Q3" "$T/outside/.ticket-seq-neg" "control first filing")"
assert_eq "${r4%%|*}" "0" "3. control: the first filing still appends (exit 0)"
assert_eq "$(git -C "$Q3" status --porcelain -- tickets.md)" "M  tickets.md" "3. control: the first filing is left staged but uncommitted"
r5="$(file_one "$T/neg/file-ticket.sh" "$Q3" "$T/outside/.ticket-seq-neg" "control second filing")"
assert_eq "${r5%%|*}" "12" "3. control: the second filing is refused with exit 12"

assert_done
