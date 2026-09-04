#!/usr/bin/env bash
# bench: the replay model.
#
# Locks the arithmetic of bench/replay.mjs against bench/fixtures/replay-fleet, a synthetic fleet
# whose numbers are hand-derivable (derivation table: bench/fixtures/README.md).
#
#   shiploop arm (measured, from result events)   5,215,000 tokens   $5.9386
#   vanilla arm, uncapped                        12,679,000 tokens   $8.6806
#   vanilla arm, 1m                              11,779,000 tokens   $8.5006
#   vanilla arm, 200k                             5,779,000 tokens   $5.9506
#
# The fixture's reported total_cost_usd is set to exactly what the published rates give, so the
# reconciliation ratio pins at 1.000 and any drift in the rate table shows up here.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-fleet"
run_replay() { node "$HUB/bench/replay.mjs" --fleet "$FLEET" "$@" 2>&1; }

# ── the provenance banner is a line in the report, not a footnote ────────────
report="$(run_replay --arm 1m)"
assert_eq "$?" "0" "replay.mjs exits 0 on the fixture fleet"
assert_contains "$report" "MODELED COUNTERFACTUAL" "the report says the vanilla arm is modeled"
assert_contains "$report" "No vanilla session was ever run" "and that no vanilla session exists"
assert_contains "$report" "a 1M-context session" "the banner names the arm it modeled"

# ── the result-event trap ────────────────────────────────────────────────────
# Every assistant event in the fixture reports output_tokens: 4, three events per turn, 22 turns.
# Summing them gives 264. The result events report 115,000. A tool that sums the stream would
# report a shiploop total 114,736 tokens light and a saving that never happened.
naive="$(grep -h '"type":"assistant"' "$FLEET"/logs/govern/*/ticket-10[1-4]/worker.jsonl \
  | jq -s '[.[].message.usage.output_tokens] | add')"
truth="$(grep -h '"type":"result"' "$FLEET"/logs/govern/*/ticket-10[1-4]/worker.jsonl \
  | jq -s '[.[].usage.output_tokens] | add')"
assert_eq "$naive" "264" "the streamed per-event output snapshots sum to a tiny number"
assert_eq "$truth" "115000" "the result events report the real output"

j="$(run_replay --arm 1m --json)"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].shiploopTokens')" "5215000" \
  "the shiploop arm is taken from result events, not from summed stream snapshots"
# 5,215,000 - 115,000 output = 5,100,000 of context. Had the tool summed the stream it would have
# reported 5,100,264 instead. Assert the trap is not merely close but exactly avoided.
assert_eq "$(printf '%s' "$j" | jq -r 'if .arms["1m"].shiploopTokens == 5100264 then "TRAPPED" else "ok" end')" "ok" \
  "the summed-snapshot total is not what got reported"

# ── pricing reconciles against published rates ───────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.reconciliation.medianComputedOverReported')" "1" \
  "computed cost over reported cost is exactly 1.000 on the fixture"
assert_eq "$(printf '%s' "$j" | jq -r '.reconciliation.within2pct')" "1" \
  "every fixture session reconciles within 2%"
assert_eq "$(printf '%s' "$j" | jq -r '.reconciliation.n')" "4" \
  "four sessions carried a reported cost to reconcile against"

# ── the excluded session is excluded and counted ─────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.sessionsExcludedNoResultEvent')" "1" \
  "the session with no result event is excluded and the exclusion is reported"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].tickets')" "4" \
  "it contributes no ticket, so it is never priced at zero"

# ── all three arms, exact ────────────────────────────────────────────────────
all="$(run_replay --arm all --json)"
cents() { printf '%s' "$all" | jq -r "(.arms[\"$1\"].$2 * 10000 | round)"; }

assert_eq "$(printf '%s' "$all" | jq -r '.arms["200k"].vanillaTokens')" "5779000" "200k arm vanilla tokens"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].vanillaTokens')" "11779000" "1m arm vanilla tokens"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["uncapped"].vanillaTokens')" "12679000" "uncapped arm vanilla tokens"
assert_eq "$(cents 200k vanillaCostUsd)" "59506" "200k arm vanilla cost"
assert_eq "$(cents 1m vanillaCostUsd)" "85006" "1m arm vanilla cost"
assert_eq "$(cents uncapped vanillaCostUsd)" "86806" "uncapped arm vanilla cost"
assert_eq "$(cents 1m shiploopCostUsd)" "59386" "the shiploop arm is the same measured cost in every arm"
assert_eq "$(cents 200k shiploopCostUsd)" "59386" "the shiploop arm does not move with the arm"

# The window is what separates the arms: 200k leaves almost no room for carry, 1m leaves room for
# all but the largest ticket, uncapped is unbounded and is labelled unphysical.
assert_eq "$(printf '%s' "$all" | jq -r '.arms["200k"].contextWindow')" "200000" "200k arm names its window"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].contextWindow')" "1000000" "1m arm names its window"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["uncapped"].contextWindow')" "null" "uncapped arm has no window"
assert_contains "$(run_replay --arm uncapped)" "unphysical" "the uncapped arm is labelled unphysical"

# Ordering: the arms must be monotone. A wider window carries more, so it can never save less.
assert_eq "$(printf '%s' "$all" | jq -r '
  (.arms["200k"].tokenReductionPct < .arms["1m"].tokenReductionPct) and
  (.arms["1m"].tokenReductionPct < .arms["uncapped"].tokenReductionPct)')" "true" \
  "a wider modeled window never saves less"

# ── the per-ticket-position curve ────────────────────────────────────────────
# Ticket 1 has nothing carried into it, so it saves exactly nothing. That is the honest shape of
# the claim and it is asserted, not just displayed.
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].positionCurve["1"].medianTokenReductionPct')" "0" \
  "ticket 1 saves exactly 0%"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].positionCurve["2"].n')" "1" "position 2 has one sample"
assert_eq "$(printf '%s' "$all" | jq -r '(.arms["1m"].positionCurve["2"].medianTokenReductionPct * 100 | round)')" \
  "6591" "position 2: 1 - 1080000/3168000"
assert_eq "$(printf '%s' "$all" | jq -r '(.arms["1m"].positionCurve["3"].medianTokenReductionPct * 100 | round)')" \
  "7951" "position 3: 1 - 770000/3758000"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].positionCurve["5"].medianTokenReductionPct')" "null" \
  "a position with no tickets reports no median rather than a zero"
assert_contains "$(run_replay --arm 1m)" "#1 0.0%" "the report prints the position curve"
assert_contains "$(run_replay --arm 1m)" "#5 n/a" "and prints n/a for positions the corpus never reached"

# ── scope selects what is counted, never what happened ───────────────────────
# Ticket 103 is 'failed'. Under --scope resolved it drops out of the totals, but it still grew the
# modeled session's context for ticket 104, so the run is not silently shortened.
res="$(run_replay --arm 1m --scope resolved --json)"
assert_eq "$(printf '%s' "$res" | jq -r '.arms["1m"].tickets')" "3" "resolved scope counts three tickets"
assert_eq "$(printf '%s' "$res" | jq -r '.arms["1m"].ticketsInModeledRuns')" "4" \
  "and still replays all four, so a failed ticket keeps contributing carry"
assert_eq "$(printf '%s' "$res" | jq -r '.arms["1m"].shiploopTokens')" "4445000" \
  "resolved scope drops ticket 103's 770,000 tokens from the totals"
assert_eq "$(printf '%s' "$res" | jq -r '.scope')" "resolved" "the scope is reported"

# ── graceful on a fleet with no logs ─────────────────────────────────────────
empty="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-empty-fleet" --arm 1m 2>&1)"
rc=$?
assert_eq "$rc" "1" "a fleet with no transcripts exits non-zero rather than reporting a saving"
assert_contains "$empty" "No sessions with a result event were found" "and says exactly what is missing"
assert_contains "$empty" "MODELED COUNTERFACTUAL" "the provenance banner prints even with no data"

missing="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/no-such-fleet-here" --arm 1m 2>&1)"
assert_eq "$?" "1" "a fleet path that does not exist exits non-zero"
assert_contains "$missing" "Nothing to replay" "and does not crash"

# ── tier resolution: the init event is a real model name and must be used ────
# fixtures/replay-init-model-fleet holds one session whose result event omits modelUsage and whose
# only assistant message is a synthetic notice with no model. The model exists in exactly one
# place: the system/init event. Priced correctly (haiku) the session costs $0.029. A tool that
# ignores the init event falls back to the most expensive tier and charges $0.145, a 5x error, and
# then reports a "tier unrecognized" line that reads like a data problem rather than a parser bug.
iflt="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-init-model-fleet" --arm 1m --json 2>&1)"
assert_eq "$?" "0" "the init-model fleet replays"
assert_eq "$(printf '%s' "$iflt" | jq -r '(.arms["1m"].shiploopCostUsd * 1000 | round)')" "29" \
  "a session that names its model only on the init event is priced at that model's tier"
assert_eq "$(printf '%s' "$iflt" | jq -r '.tierFallback.sessions')" "0" \
  "and does not count as a tier fallback"
assert_eq "$(printf '%s' "$iflt" | jq -r '.reconciliation.medianComputedOverReported')" "1" \
  "which is what makes its reported cost reconcile"

# ── the tier-fallback audit is reported, not hidden ──────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.tierFallback | keys | join(",")')" \
  "measuredSessions,measuredTokens,sessions,tokens" "the tier-fallback audit has a fixed shape"
assert_eq "$(printf '%s' "$j" | jq -r '.tierFallback.measuredSessions')" "0" \
  "no measured fixture session falls back to a guessed tier"
assert_contains "$(run_replay --arm 1m)" "tier fallback: none" \
  "and the report says so in words rather than printing the word unknown"

# ── recovering the sessions that were killed before a result event ───────────
# Ticket 105 was killed mid-session. Its OUTPUT is unrecoverable, but its input side is exact:
# 10,000 input + 12,000 cache write + 28,000 cache read = 50,000 tokens. Dropping it makes OUR arm
# look cheaper than it was, so the tool computes and prints what adding it back would do.
assert_eq "$(printf '%s' "$j" | jq -r '.partialRecovery.sessions')" "1" "the killed session is counted"
assert_eq "$(printf '%s' "$j" | jq -r '.partialRecovery.recoverableInputSideTokens')" "50000" \
  "and its exactly recoverable input side is reported"
assert_eq "$(printf '%s' "$j" | jq -r '.partialRecovery.outputRecoverable')" "false" \
  "output is never recovered: summing per-message output is the settled trap"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].shiploopTokens')" "5215000" \
  "the DEFAULT arm stays purely measured: the recovered session is not folded into it"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].sensitivityWithRecoveredPartials.shiploopTokens')" "5265000" \
  "the sensitivity arm adds exactly the 50,000 recovered tokens"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].sensitivityWithRecoveredPartials.vanillaTokens')" "12767000" \
  "and charges the vanilla arm its carry: 950,000 capped by a 1M window, less the 12,000 re-prime"
assert_eq "$(printf '%s' "$j" | jq -r '(.arms["1m"].sensitivityWithRecoveredPartials.tokenReductionPct * 100 | round)')" \
  "5876" "the sensitivity reduction is reported, not just the flattering one"
# The delta is signed and can go either way. On the 200k arm the recovered session costs more than
# the carry it earns, so the cost reduction goes NEGATIVE. That must be reported, not floored.
assert_eq "$(printf '%s' "$j" | jq -r '.arms["200k"].sensitivityWithRecoveredPartials.costReductionPct < 0')" "true" \
  "a recovery that makes our arm look worse is reported as worse"
assert_contains "$(run_replay --arm 1m)" "added back to OUR arm" \
  "the sensitivity is a line in the default human report, not a JSON-only field"

# ── argument validation ──────────────────────────────────────────────────────
bad="$(node "$HUB/bench/replay.mjs" --arm 500k 2>&1)"
assert_eq "$?" "2" "an unknown arm is a usage error"
assert_contains "$bad" "unknown arm" "and names the bad flag"
badscope="$(node "$HUB/bench/replay.mjs" --scope shipped 2>&1)"
assert_eq "$?" "2" "an unknown scope is a usage error"
assert_contains "$badscope" "unknown scope" "and names the bad flag"

assert_done
