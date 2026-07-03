#!/usr/bin/env bash
# Proves the shared ticket-block parser (govern::ticket_block / govern::ticket_block_delete)
# is bounded by the next `## #<digits>` heading, NOT by the first `^---$`. Regression coverage
# for three collapsed bugs (parser bug batch):
#   (1) A bare `---` inside a ticket BODY (a legit markdown divider) no longer truncates the
#       worker prompt (spawn-worker.sh) or leaves orphaned body lines under the next heading
#       when the block is deleted (govern-bookkeep.sh).
#   (2) The block delete consumes the block's trailing `---` separator so tickets.md never
#       accumulates doubled separators after a resolved delete.
#   (3) The block delete on a heading that isn't present is a silent no-op.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # seed workspace stub BEFORE sourcing common.sh (its init reads workspace.sh)
source "$DIR/../lib/common.sh"

# Fixture: #5's body contains a bare `---` divider (legit markdown, NOT a ticket boundary).
# The block-parser must swallow it and keep going to the next `## #` heading.
cat > "$T/tickets.md" <<'EOF'
# Tickets

## #5 — parser trap: body contains a bare markdown divider
**Severity:** High

Observed: something is broken.

---

More prose after a legit `---` divider inside the body.
Line X.
Line Y.
---

## #6 — the next ticket
**Severity:** Medium

body6
---
EOF

# ── Extract: the whole #5 block (heading through last body line) must be returned, INCLUDING
# every line PAST the bare `---` (the previous parser stopped at the first `---`).
block="$(govern::ticket_block 5 "$T/tickets.md")"
assert_contains "$block" "## #5 — parser trap" "extract: heading line present"
assert_contains "$block" "Line X." "extract: body past a bare '---' is NOT truncated"
assert_contains "$block" "Line Y." "extract: body past a bare '---' is NOT truncated (Line Y)"
# The next ticket's content must NOT bleed in.
if grep -q "^## #6 " <<<"$block"; then f=1; else f=0; fi
assert_eq "$f" "0" "extract: bounded by next '## #' heading — #6 does NOT leak into #5"

# Ticket #6 (last block, no successor) — extract must reach EOF, no trailing sibling heading.
b6="$(govern::ticket_block 6 "$T/tickets.md")"
assert_contains "$b6" "## #6 — the next ticket" "extract: last-block heading present"
assert_contains "$b6" "body6" "extract: last-block body present"

# ── Delete: the whole #5 block must be removed AND its trailing `---` separator consumed with
# it, so the file layout after the delete is exactly what it would have been if #5 never existed.
cp "$T/tickets.md" "$T/tickets.md.bak"
govern::ticket_block_delete 5 "$T/tickets.md"
after="$(cat "$T/tickets.md")"
if grep -q "## #5 " "$T/tickets.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "delete: #5 heading removed"
if grep -q "Line X\." "$T/tickets.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "delete: body past the bare '---' removed too (no orphaned lines)"
if grep -q "Line Y\." "$T/tickets.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "delete: entire block removed (Line Y gone)"
# #6 must survive intact.
assert_contains "$after" "## #6 — the next ticket" "delete: #6 heading preserved"
assert_contains "$after" "body6" "delete: #6 body preserved"

# No doubled `---` separators anywhere in the remaining file (a doubled separator means the
# block's trailing separator was left behind).
dash_lines="$(grep -c '^---$' "$T/tickets.md" || true)"
# Expect EXACTLY one `---` (the one that closes #6). The old parser sometimes left #5's
# trailing `---` behind.
assert_eq "$dash_lines" "1" "delete: exactly one '---' remains (only #6's trailing separator)"

# ── Delete of an ABSENT ticket = silent no-op (file unchanged).
before="$(cat "$T/tickets.md")"
govern::ticket_block_delete 999 "$T/tickets.md"
after2="$(cat "$T/tickets.md")"
assert_eq "$after2" "$before" "delete: absent ticket = silent no-op"

assert_done
