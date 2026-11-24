#!/usr/bin/env bash
# The queue stale-copy check: a working-tree queue file that is an older copy written over newer work
# is refused by every queue writer (exit 12, with the diff) and warned about at SessionStart; normal
# edits pass.
#   1. a stale copy (deletes a live ticket, brings back a resolved one) is flagged by the function.
#   2. a normal append of a new number is not flagged.
#   3. a deletion whose resolve commit already landed is not flagged.
#   4. file-ticket.sh and land-resolution.sh refuse a stale copy with exit 12 and leave it byte-identical.
#   5. a normal append is not refused by the stale check.
#   6. GOVERN_QUEUE_STALE_GUARD=0 turns the check off.
#   7. session-reconcile.sh warns with the diff on a stale copy and stays silent on a clean file.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

FILE_TICKET="$DIR/../file-ticket.sh"
BK="$DIR/../land-resolution.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
export GOVERN_NO_PUSH=1
export GOVERN_QUEUE_STALE_GUARD=1
mkdir -p "$T/queue" "$T/governor" "$T/scripts/govern/lib" "$T/scripts/hooks"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
TF="$T/queue/tickets.md"
source "$DIR/../lib/common.sh"
set +e

block() { printf '\n## #%s — ticket %s\n\n**Severity:** Low\n\nbody %s\n\n---\n' "$1" "$1" "$1"; }
commit_all() { ( cd "$T" && git add -A >/dev/null 2>&1 && git commit -qm "$1" >/dev/null 2>&1 ); }
file_sha() { shasum -a 256 "$TF" | cut -d' ' -f1; }

# History: #1, #2 filed; #2 resolved (block deleted, `resolve #2` commit); #3 filed afterwards.
printf '# Tickets\n' > "$TF"; block 1 >> "$TF"; block 2 >> "$TF"; commit_all "docs(tickets): file #1, #2"
cp "$TF" "$T/old-copy.md"
printf '# Tickets\n' > "$TF"; block 1 >> "$TF"; commit_all "docs(tickets): resolve #2 (alpha#9)"
block 3 >> "$TF"; commit_all "docs(tickets): file #3"
GOOD="$(cat "$TF")"

# ── 1. stale copy: the old buffer is back (brings #2 back, drops live #3) ────────────────────────
cp "$T/old-copy.md" "$TF"
out="$(govern::queue_stale_copy "$TF")"
assert_contains "$out" "deletes live ticket: ## #3" "1. a vanished live ticket is named"
assert_contains "$out" "brings back resolved ticket: ## #2" "1. a resurrected resolved ticket is named"
assert_contains "$out" "@@" "1. the head of the diff is printed"

# ── 4. writers refuse the stale copy, byte-identical afterwards ──────────────────────────────────
before="$(file_sha)"; head_before="$(git -C "$T" rev-parse HEAD)"
printf 'Where: x\nObserved: y\nDone when: z\n' | bash "$FILE_TICKET" "New one" Low >/dev/null 2>"$T/ft.err"; rc=$?
assert_eq "$rc" "12" "4. file-ticket.sh refuses a stale copy with exit 12"
assert_contains "$(cat "$T/ft.err")" "stale copy" "4. file-ticket.sh names the stale copy"
assert_eq "$(file_sha)" "$before" "4. file-ticket.sh left the file byte-identical"
printf '%s' '{"status":"resolved","pr":null,"newTickets":[],"lessonPatch":null}' | bash "$BK" 3 >/dev/null 2>"$T/bk.err"; rc=$?
assert_eq "$rc" "12" "4. land-resolution.sh refuses a stale copy with exit 12"
assert_eq "$(file_sha)" "$before" "4. land-resolution.sh left the file byte-identical"
assert_eq "$(git -C "$T" rev-parse HEAD)" "$head_before" "4. nothing was committed"

# ── 6. kill switch ────────────────────────────────────────────────────────────────────────────────
out="$(GOVERN_QUEUE_STALE_GUARD=0 govern::queue_stale_copy "$TF")"
assert_eq "$out" "" "6. GOVERN_QUEUE_STALE_GUARD=0 prints nothing for the same stale copy"

# ── 7. session-reconcile.sh ──────────────────────────────────────────────────────────────────────
# A scaffolded workspace has the hook at scripts/; the hub checkout has it under templates/hooks/.
for _h in "$DIR/../../session-reconcile.sh" "$DIR/../../hooks/session-reconcile.sh"; do
  [[ -f "$_h" ]] && { cp "$_h" "$T/scripts/session-reconcile.sh"; break; }
done
cp "$DIR/../lib/common.sh" "$T/scripts/govern/lib/common.sh"
out="$(env -u GOVERN_RUN bash "$T/scripts/session-reconcile.sh" 2>&1)"
assert_contains "$out" "queue integrity" "7. session-reconcile.sh warns on a stale copy"
assert_contains "$out" "deletes live ticket: ## #3" "7. the warning carries the findings"

# ── 2. normal append passes ──────────────────────────────────────────────────────────────────────
printf '%s\n' "$GOOD" > "$TF"; block 4 >> "$TF"
out="$(govern::queue_stale_copy "$TF")"
assert_eq "$out" "" "2. appending a new number is not flagged"
out="$(env -u GOVERN_RUN bash "$T/scripts/session-reconcile.sh" 2>&1)"
assert_not_contains "$out" "queue integrity" "7. session-reconcile.sh is silent on a normal append"
commit_all "docs(tickets): file #4"

# ── 3. a deletion with a resolve commit after the block was added passes ─────────────────────────
printf '%s\n' "$GOOD" > "$TF"
out="$(govern::queue_stale_copy "$TF")"
assert_contains "$out" "deletes live ticket: ## #4" "3a. control: deleting #4 by hand with no resolve commit IS flagged"
( cd "$T" && git commit -q --allow-empty -m "docs(tickets): resolve #4 (alpha#10)" )
out="$(govern::queue_stale_copy "$TF")"
assert_eq "$out" "" "3b. the same deletion once a resolve #4 commit exists is not flagged"
printf '%s\n' "$GOOD" > "$TF"; block 4 >> "$TF"

# ── 5. a normal append is not refused by the stale check ─────────────────────────────────────────
printf 'Where: x\nObserved: y\nDone when: z\n' | bash "$FILE_TICKET" "Filed fine" Low >/dev/null 2>"$T/ft2.err"; rc=$?
assert_eq "$rc" "0" "5. file-ticket.sh on a clean queue is not refused"

assert_done
