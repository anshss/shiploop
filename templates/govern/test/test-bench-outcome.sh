#!/usr/bin/env bash
# bench: the attempt-outcome breakdown ("no attempt-outcome dimension").
#
# `--scope all` prices every attempt unconditionally, which is honest for cost but leaves
# infrastructure failures indistinguishable from capability ones. outcomeBreakdown() reads
# spawn-worker.sh's per-attempt LEDGER (`attempts.jsonl`, sibling of the transcript) where it
# exists and says WHY each attempt happened, without changing what is priced.
#
# `bench/fixtures/replay-outcome-fleet` (make-outcome-fixture.mjs) has three tickets:
#   ticket-701  two attempts, ledger present: attempt 1 (first-attempt, failed), superseded by
#               attempt 2 (judgment, resolved) -- the worker.attempt1.jsonl / worker.jsonl
#               rotation the classifier keys off.
#   ticket-702  one attempt, ledger present, retryClass "infra".
#   ticket-703  one attempt, NO ledger at all -- must land in `unclassified` (reason `no-ledger`).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-outcome-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-outcome-fleet"
j="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --json 2>&1)"
assert_eq "$?" "0" "--json exits 0 on the outcome fixture"

# ── the census counts every attempt, unconditionally, like --scope all's own total ────────────
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.totalAttempts')" "4" \
  "3 tickets, 4 attempts total (ticket-701 has two)"

# ── present: a class the ledger actually names shows up with the right count and tokens ───────
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["first-attempt"].attempts')" "1" \
  "ticket-701's attempt 1 is classified first-attempt"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["judgment"].attempts')" "1" \
  "ticket-701's attempt 2 is classified judgment (it superseded a failed first attempt)"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["infra"].attempts')" "1" \
  "ticket-702's single attempt is classified infra -- not just whichever class sorts first"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["first-attempt"].tokens')" "36000" \
  "a classified attempt's tokens are the SAME sessionTokens() figure the headline prices, not a second count"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["judgment"].tokens')" "47000" \
  "attempt 2's tokens are its own transcript's, not attempt 1's"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["ci"].attempts')" "0" \
  "an unused canonical class is still named, at zero, never omitted"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["budget"].attempts')" "0" \
  "same for budget"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.classes["unknown"].attempts')" "0" \
  "same for the classifier's own unknown verdict -- none of this fixture's ledger rows use it"

# ── absent: no ledger at all is unclassified with a named reason, never folded into "unknown" ──
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.unclassified.attempts')" "1" \
  "ticket-703 carries no attempts.jsonl, so its one attempt is unclassified"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.unclassified.reasons["no-ledger"]')" "1" \
  "and the reason is explicit: no ledger, not a silent bucket"
assert_eq "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.unclassified.tokens')" "21000" \
  "the unclassified attempt still carries its own real token count"

# ── nothing is double-counted or dropped between the classes and the unclassified bucket ──────
assert_eq "$(printf '%s' "$j" | jq -r '([.outcomeBreakdown.classes[].attempts] | add) + .outcomeBreakdown.unclassified.attempts')" \
  "$(printf '%s' "$j" | jq -r '.outcomeBreakdown.totalAttempts')" \
  "every attempt lands in exactly one bucket"

# ── the breakdown is additive, never a filter: the headline total is untouched by any of this ──
all="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --scope all --json 2>&1)"
resolved="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --scope resolved --json 2>&1)"
assert_eq "$(printf '%s' "$all" | jq -r '.outcomeBreakdown.totalAttempts')" \
  "$(printf '%s' "$resolved" | jq -r '.outcomeBreakdown.totalAttempts')" \
  "the census is computed over every attempt regardless of --scope, exactly like the ledger itself"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].shiploopTokens')" \
  "$(printf '%s' "$j" | jq -r '.arms["1m"].shiploopTokens')" \
  "and adding the breakdown never moves the headline token total"

# ── driverScope: unmissable in the JSON on every fleet, not just here
assert_eq "$(printf '%s' "$j" | jq -r '.driverScope.excluded')" "true" \
  "the interactive driver session's exclusion is a stated field, present on every report"

assert_done
