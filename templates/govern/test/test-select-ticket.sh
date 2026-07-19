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

# #314: a ticket that edits a file with an OPEN sync-port manual-port escalation is auto-skipped
# (would collide with that in-progress port's sync-auto branch). Full-path match only — a bare
# basename mention does NOT collide — and a RESOLVED sync-port escalation does NOT exclude.
cat > "$TMP/sp-tickets.md" <<'EOF'
## #20 — high, edits a file with an OPEN sync-port port
**Severity:** High — refactor `scripts/govern/run-loop.sh` heartbeat.
---
## #21 — medium, untouched by any sync-port escalation
**Severity:** Medium — tweak the docs.
---
## #22 — low, only names a bare basename (not the full path)
**Severity:** Low — run-loop.sh logging polish.
---
EOF
cat > "$TMP/sp-esc-open.md" <<'EOF'
## Open
### #99 — sync-port: 1 file(s) need manual porting
- **Branch:** sync-auto-abc123def-1f
- **Files:** scripts/govern/run-loop.sh
## Resolved
EOF
cat > "$TMP/sp-esc-resolved.md" <<'EOF'
## Open
## Resolved
### #99 — sync-port: 1 file(s) need manual porting — RESOLVED
- **Files:** scripts/govern/run-loop.sh
EOF

# helper flags ONLY the full-path open-collision ticket (#20); the untouched #21 and the
# bare-basename mention #22 are clear.
sp="$(GOVERN_TICKETS_FILE="$TMP/sp-tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/sp-esc-open.md" \
  bash -c 'source "'"$DIR"'/../lib/common.sh"; govern::sync_port_collision_tickets')"
assert_eq "$sp" "$(printf '20\tscripts/govern/run-loop.sh')" "sync-port helper flags only the full-path open-collision ticket"

# select-ticket EXCLUDES the colliding High #20 → picks Medium #21 over Low #22 (proves the
# High collider was skipped, not merely deprioritized).
spout="$(GOVERN_TICKETS_FILE="$TMP/sp-tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/sp-esc-open.md" "$SEL")"
assert_eq "$spout" "21" "select-ticket skips open-sync-port-collision #20, picks medium #21"

# a RESOLVED sync-port escalation carries no in-flight branch → #20 is selectable again (High wins).
spout2="$(GOVERN_TICKETS_FILE="$TMP/sp-tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/sp-esc-resolved.md" "$SEL")"
assert_eq "$spout2" "20" "resolved sync-port escalation does NOT exclude #20 (High picked)"

# helper is a clean no-op when the escalations file has no OPEN sync-port entries.
sp3="$(GOVERN_TICKETS_FILE="$TMP/sp-tickets.md" GOVERN_ESCALATIONS_FILE="$TMP/sp-esc-resolved.md" \
  bash -c 'source "'"$DIR"'/../lib/common.sh"; govern::sync_port_collision_tickets')"
assert_eq "$sp3" "" "sync-port helper emits nothing when no OPEN sync-port escalation matches"

assert_done
