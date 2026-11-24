#!/usr/bin/env bash
# file-ticket.sh filing guards, ported onto the 1.20.7 numbering + queue guard:
#   1. NOTHING exits silently: an ERR trap names the failing line, and the EXIT trap reports any
#      exit that appended nothing ("EXITED WITHOUT FILING"), forcing it non-zero.
#   2. Outcome assertion: the append only counts as filed once the heading is READ BACK from disk.
#   3. The emitter owns `**Severity:**`: a copy the caller put in the body is stripped (marker
#      only — any rationale survives as prose), so a block never carries two fields.
#   4. Duplicate scan reaches the parked file and the git ledger (previously-filed), not just the
#      live queue.
# Negative controls: a body with no Severity field is untouched, a clean-title filing carries no
# duplicate marker, and numbering stays collision-safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh arms -e; the git-ledger fixture and rc-expecting runs below need it off
FILE_TICKET="$DIR/../file-ticket.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"

printf '# Tickets\n' > "$T/tickets.md"

block_of() { # <N> <file> — the ticket block, tolerant boundaries (same shape govern::ticket_block)
  awk -v n="$1" '
    /^##[[:space:]]+#[0-9]+/ { if ($0 ~ ("^##[[:space:]]+#" n "([^0-9]|$)")) { grab=1 } else if (grab) exit }
    grab { print }
  ' "$2"
}

# 1. Severity strip: a body carrying its own field ends up with exactly ONE Severity line (the
#    emitter's), and the rationale survives as prose.
n1="$(printf 'Where: x\n**Severity:** High — a caller restated it in the body\nObserved: y\nDone when: z\n' \
  | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "severity strip case" Medium)"
blk="$(block_of "$n1" "$T/tickets.md")"
assert_contains "$blk" "**Severity:** Medium" "the emitter's own Severity field is present"
sev_count="$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]*(-[[:space:]]+)?\*\*Severity' || true)"
assert_eq "$sev_count" "1" "exactly ONE Severity field survives the strip (was 2 before)"
assert_contains "$blk" "a caller restated it in the body" "the rationale is kept as prose"
assert_not_contains "$blk" "**Severity:** High" "the duplicate marker itself is gone"

# 2. Negative control: a body with NO Severity field is untouched, and no strip log fires.
stderr2="$(printf 'Where: x\nObserved: plain body with no field\nDone when: z\n' \
  | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "no-field control case" Low 2>&1 >/dev/null)"
if printf '%s' "$stderr2" | grep -q "marker is stripped"; then
  echo "FAIL - strip log fired on a body with no Severity field"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - no strip log on a clean body"
fi

# 3. Nothing exits silently: a failing run reports EXITED WITHOUT FILING and never exits 0.
err="$(printf 'body\n' | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" 2>&1 >/dev/null || true)"
assert_contains "$err" "EXITED WITHOUT FILING" "an exit that appended nothing names itself"
assert_contains "$err" "Do NOT record a ticket number" "the no-number warning is present"
rc4=0
printf 'body\n' | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" >/dev/null 2>/dev/null || rc4=$?
if [[ "$rc4" -eq 0 ]]; then
  echo "FAIL - a no-op filing exited 0"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - a no-op filing never exits 0 (got rc $rc4)"
fi

# 4. Read-back verification: each filed number IS on disk exactly once.
assert_eq "$(grep -cE "^## #$n1[[:space:]]" "$T/tickets.md")" "1" "the filed heading reads back exactly once"

# 5. Duplicate scan over the LIVE queue file (existing behavior, kept as a control).
n5="$(printf 'Where: x\nObserved: the release wrapper is stuck again\nDone when: z\n' \
  | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "severity strip case again" Low)"
assert_contains "$(block_of "$n5" "$T/tickets.md")" "possible duplicate of #$n1" "a live-queue title overlap still flags (control)"

# 6. Ledger duplicate scan: a git history holding `docs(tickets): file #900 — <title>` flags a
#    similarly-titled new ticket as `previously-filed #900`, even though the block is deleted.
L="$(mktemp -d)"
mk_ws_stub "$L"
( cd "$L" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b main )
mkdir -p "$L/queue"
printf '# Tickets\n' > "$L/queue/tickets.md"
git -C "$L" add -A && git -C "$L" commit -qm init
printf '\n## #900 — publish failed on v0.5.3 wrapper stuck\n\n**Severity:** High\nbody\n---\n' >> "$L/queue/tickets.md"
git -C "$L" add -A && git -C "$L" commit -qm "docs(tickets): file #900 — publish failed on v0.5.3 wrapper stuck"
printf '# Tickets\n' > "$L/queue/tickets.md"
git -C "$L" add -A && git -C "$L" commit -qm "docs(tickets): resolve #900 (none)"
led_out="$(printf 'Where: x\nObserved: the release wrapper is stuck again\nDone when: z\n' \
  | GOVERN_WS_ROOT="$L" GOVERN_TICKETS_FILE="$L/queue/tickets.md" bash "$FILE_TICKET" "publish failed on v0.5.4 wrapper stuck" Low 2>&1)"
assert_contains "$led_out" "previously-filed #900" "a deleted ticket's ledger commit still flags a duplicate"
assert_contains "$(cat "$L/queue/tickets.md")" "possible duplicate of previously-filed #900" "the body marker names the ledger hit"

# 7. Negative control: an unrelated title over the same ledger files with NO marker.
unrelated="$(printf 'Where: x\nObserved: totally different area\nDone when: z\n' \
  | GOVERN_WS_ROOT="$L" GOVERN_TICKETS_FILE="$L/queue/tickets.md" bash "$FILE_TICKET" "unrelated layout regression in a panel" Low 2>&1)"
assert_not_contains "$unrelated" "possible duplicate" "an unrelated title files clean over the same ledger"

assert_done
