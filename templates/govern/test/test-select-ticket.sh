#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SEL="$DIR/../select-ticket.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"  # hermetic workspace stub (independent of the live workspace.sh)
cat > "$TMP/tickets.md" <<'EOF'
## #2 — low one
**Severity:** Low — minor.
---
## #5 — high one
**Severity:** High — bad.
---
## #3 — medium one
**Severity:** Medium — meh.
---
EOF
cat > "$TMP/escalations.md" <<'EOF'
## Open
### #5 — already parked
- **Reason:** x
## Resolved
EOF

# Highest severity first → #5, but #5 is parked open → next is #3 (medium) over #2 (low).
out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/escalations.md" "$SEL")"
assert_eq "$out" "3" "skips open-escalation #5, picks medium #3 over low #2"

# With no escalations file, highest severity wins → #5
out2="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/none.md" "$SEL")"
assert_eq "$out2" "5" "picks highest-severity #5 when nothing parked"

# CLI exclude arg removes #5 and #3 → low #2 remains
out3="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/none.md" "$SEL" "5,3")"
assert_eq "$out3" "2" "respects CLI exclude list"

# #92: a ticket whose body carries a bold "NOT govern-automatable" marker is auto-skipped — even
# the highest-severity one — so the governor never burns a worker on it. A ticket that merely
# MENTIONS the phrase in prose (no bold anchor) stays selectable.
cat > "$TMP/na.md" <<'EOF'
## #5 — high but not automatable
**Severity:** High — needs the GitHub Actions web UI.
**NOT govern-automatable (supervisor):** a headless worker can't read web-UI logs. Handle interactively.
---
## #6 — high, only discusses automatability in prose
**Severity:** High — this ticket is about "NOT govern-automatable" markers and "handle interactively" notes.
The selector should still pick me — I only mention the phrase, I'm not marked.
---
## #7 — medium normal
**Severity:** Medium — fine.
---
EOF
out4="$(GOVERN_TICKETS_FILE="$TMP/na.md" GOVERN_ESCALATIONS_FILE="$TMP/none.md" "$SEL")"
assert_eq "$out4" "6" "auto-skips bold-marked #5, picks prose-only #6 (mention ≠ marker)"

out5="$(GOVERN_TICKETS_FILE="$TMP/na.md" GOVERN_ESCALATIONS_FILE="$TMP/none.md" "$SEL" "6")"
assert_eq "$out5" "7" "with #6 excluded, marked #5 stays skipped → medium #7, never #5"

# the helper itself reports exactly the marked ticket + its reason keyword
na="$(GOVERN_TICKETS_FILE="$TMP/na.md" bash -c 'source "'"$DIR"'/../lib/common.sh"; govern::not_automatable_tickets "'"$TMP/na.md"'"')"
assert_eq "$na" "$(printf '5\tNOT govern-automatable')" "helper flags only the bold-marked ticket"

assert_done
