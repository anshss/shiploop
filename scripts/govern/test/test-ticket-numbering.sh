#!/usr/bin/env bash
# Regression for ticket #73: ticket numbering must be collision-safe across the GOVERNOR path
# (govern-bookkeep) AND any MANUAL filing (file-ticket.sh / govern::next_ticket_number). The bug:
# a manual append read a stale .ticket-seq (which only bookkeep ever bumped), didn't read the live
# tickets.md max, didn't bump the seq, and wasn't serialized — so two sessions reused #67.
# This proves: (1) next_ticket_number = max(filemax, seq)+1 and bumps seq; (2) file-ticket.sh files
# through it; (3) govern-bookkeep routes through it; (4) the duplicate-heading detector + lint catch
# a collision; (5) deleting the highest ticket leaves a GAP (monotonic, never reused).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"
FILE_TICKET="$DIR/../file-ticket.sh"
LINT="$DIR/../lint-tickets.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"                  # hermetic workspace stub (independent of the live workspace.sh)
export GOVERN_QUEUE_DIR="$T"     # queue refactor: keep this fixture's tickets.md at the sandbox root
mkdir -p "$T/governor"
source "$DIR/../lib/common.sh"   # helpers bound to the temp WS_ROOT

mk_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets

## #1 — alpha

**Severity:** High

body one

---

## #5 — gamma

**Severity:** Low

body three

---
EOF
}

# ── 1. next_ticket_number = max(filemax, seq) + 1, and bumps the seq ──
mk_tickets
rm -f "$T/governor/.ticket-seq"           # no seq yet → filemax (5) governs
n="$(govern::next_ticket_number "$T/tickets.md")"
assert_eq "$n" "6" "next_ticket_number: max(filemax=5, seq=0)+1 = 6"
assert_eq "$(cat "$T/governor/.ticket-seq")" "6" "next_ticket_number: seq bumped to 6"
# A second call (file unchanged) keeps climbing off the seq → never hands out 6 twice.
n2="$(govern::next_ticket_number "$T/tickets.md")"
assert_eq "$n2" "7" "next_ticket_number: consecutive calls never collide (6 -> 7)"
assert_eq "$(cat "$T/governor/.ticket-seq")" "7" "next_ticket_number: seq bumped to 7"

# seq AHEAD of filemax (the #73 scenario: a prior filing bumped seq past the live max) → seq governs.
mk_tickets                                # filemax back to 5
printf '20\n' > "$T/governor/.ticket-seq" # seq = 20
n="$(govern::next_ticket_number "$T/tickets.md")"
assert_eq "$n" "21" "next_ticket_number: stale-low filemax ignored when seq (20) is higher → 21"

# ── 2. file-ticket.sh files a MANUAL ticket through the helper (number + seq bump) ──
mk_tickets
printf '13\n' > "$T/governor/.ticket-seq"  # seq=13 > filemax=5
got="$(printf 'Where: x\nDone when: y\n' | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "manual filing" Low)"
assert_eq "$got" "14" "file-ticket.sh: manual filing computed from live max(seq=13) -> #14"
assert_eq "$(grep -c '^## #14 — manual filing' "$T/tickets.md")" "1" "file-ticket.sh: appended ## #14 block"
assert_eq "$(cat "$T/governor/.ticket-seq")" "14" "file-ticket.sh: bumped .ticket-seq to 14"
# A manual append followed by another manual append cannot reuse #14.
got2="$(printf 'body\n' | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "second" Low)"
assert_eq "$got2" "15" "file-ticket.sh: second manual filing -> #15 (no reuse)"

# ── 3. govern-bookkeep numbers newTickets through the SAME helper (no reuse) ──
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
mk_tickets
printf '30\n' > "$T/governor/.ticket-seq"   # seq=30, filemax=5 → bookkeep must allocate 31,32
( cd "$T" && git add -A && git commit -q -m init )
rpt='{"status":"resolved","pr":{"repo":"alpha","number":9},"newTickets":[{"title":"born-a","severity":"Low","body":"b"},{"title":"born-b","severity":"Low","body":"b"}],"lessonPatch":null}'
GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_NO_PUSH=1 printf '%s' "$rpt" | bash "$BK" 1 >/dev/null 2>&1
assert_eq "$(grep -c '^## #31 — born-a' "$T/tickets.md")" "1" "bookkeep: first newTicket allocated #31 off the seq high-water mark"
assert_eq "$(grep -c '^## #32 — born-b' "$T/tickets.md")" "1" "bookkeep: second newTicket allocated #32 (consecutive, no reuse)"
assert_eq "$(cat "$T/governor/.ticket-seq")" "32" "bookkeep: seq persisted at 32"
assert_eq "$(grep -c '^## #1 — alpha' "$T/tickets.md")" "0" "bookkeep: resolved #1 block deleted"

# ── 4. duplicate-heading detector + lint catch a real collision ──
mk_tickets
govern::duplicate_ticket_headings "$T/tickets.md" >/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "duplicate detector: clean tickets.md returns 0"
bash "$LINT" "$T/tickets.md" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "lint-tickets.sh: clean file exits 0"
# Plant a collision: a second ## #5 heading.
printf '\n## #5 — DUPLICATE\n\n**Severity:** Low\n\nb\n\n---\n' >> "$T/tickets.md"
out="$(govern::duplicate_ticket_headings "$T/tickets.md")" && rc=0 || rc=1
assert_eq "$rc" "1" "duplicate detector: collision returns 1"
assert_contains "$out" "#5" "duplicate detector: names the colliding number #5"
bash "$LINT" "$T/tickets.md" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "lint-tickets.sh: collision exits non-zero"
# #5 vs #50 must NOT be confused as a duplicate of each other.
mk_tickets
printf '\n## #50 — fifty\n\n**Severity:** Low\n\nb\n\n---\n' >> "$T/tickets.md"
govern::duplicate_ticket_headings "$T/tickets.md" >/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "duplicate detector: #5 and #50 are distinct, not a collision"

# ── 5. deleting the highest ticket leaves a GAP (monotonic; never reclaim a number) ──
mk_tickets                                  # #1, #5
printf '5\n' > "$T/governor/.ticket-seq"
# resolve #5 (the highest) — bookkeep deletes it; seq stays at 5.
( cd "$T" && git add -A && git commit -q -m pre5 )
GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_NO_PUSH=1 \
  printf '{"status":"resolved","pr":{"repo":"alpha","number":1},"newTickets":[],"lessonPatch":null}' | bash "$BK" 5 >/dev/null 2>&1
assert_eq "$(grep -c '^## #5 ' "$T/tickets.md")" "0" "gap: highest ticket #5 deleted"
# next number is 6 (off the seq), NOT 2 (reclaiming below the deleted max) and NOT 5 (reuse).
n="$(govern::next_ticket_number "$T/tickets.md")"
assert_eq "$n" "6" "gap: after deleting #5, next number is 6 — #5 is never reused"

# ── 6. wiring assertions (so the safety can't silently regress) ──
# The Stop hook resolves to templates/hooks/ (in-place) or scripts/ (scaffold) via GOVERN_HOOKS_DIR.
SWEEP_HOOK="${GOVERN_HOOKS_DIR:-$DIR/../..}/ticket-sweep-reminder.sh"
assert_contains "$(cat "$BK")" "next_ticket_number" "bookkeep routes numbering through the shared helper"
assert_contains "$(cat "$SWEEP_HOOK")" "lint-tickets.sh" "Stop hook runs the duplicate-heading lint"

assert_done
