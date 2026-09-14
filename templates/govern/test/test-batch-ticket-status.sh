#!/usr/bin/env bash
# Per-ticket outcome lookup for a BATCHED worker report: a group that partially fails must report
# per-ticket outcomes, never collapse to one verdict — otherwise bookkeeping marks unfixed tickets
# resolved and DELETES them. Proves govern::batch_ticket_status/govern::batch_ticket_note read the
# report's `tickets` array (one `{ticket,status,note}` per ticket in the group) and are FAIL-CLOSED:
# only an explicit `resolved` entry maps to resolved; a different status, a missing entry, an empty
# array and an unparseable report all map to "" (⇒ the caller leaves the ticket in tickets.md).
# resolve-ticket.sh calls these once a group worker reports a `tickets` array.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT"
source "$DIR/../lib/common.sh"

report='{"status":"resolved","pr":{"repo":"alpha","number":7},"tickets":[
  {"ticket":1,"status":"resolved","note":"landed in the group PR"},
  {"ticket":2,"status":"parked","note":"needs an operator call"},
  {"ticket":3,"status":"failed","note":"could not reproduce"}]}'
assert_eq "$(govern::batch_ticket_status "$report" 1)" "resolved" "F1: explicit resolved maps to resolved"
assert_eq "$(govern::batch_ticket_status "$report" 2)" "parked"   "F2: parked is NOT collapsed into the group verdict"
assert_eq "$(govern::batch_ticket_status "$report" 3)" "failed"   "F3: failed is NOT collapsed into the group verdict"
assert_eq "$(govern::batch_ticket_status "$report" 4)" ""         "F4: a ticket ABSENT from the array maps to '' (stays in queue)"
assert_eq "$(govern::batch_ticket_note   "$report" 2)" "needs an operator call" "F5: per-ticket note is carried through"
# The dangerous shapes: a group-level "resolved" must never leak onto a batched ticket.
assert_eq "$(govern::batch_ticket_status '{"status":"resolved","tickets":[]}' 9)" "" "F6: empty tickets array ⇒ '' despite a resolved GROUP status"
assert_eq "$(govern::batch_ticket_status '{"status":"resolved"}' 9)"             "" "F7: no tickets array at all ⇒ '' (legacy single-ticket report)"
assert_eq "$(govern::batch_ticket_status 'not json at all' 9)"                   "" "F8: unparseable report ⇒ '' — fail closed, never resolved"
assert_eq "$(govern::batch_ticket_status '{"tickets":[{"ticket":9}]}' 9)"        "" "F9: entry present but status missing ⇒ ''"

assert_done
