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
# The LEGACY arm, pinned explicitly. The current defaults changed (baseline driver-tier, partials
# priced), so every assertion below that locks the legacy arithmetic names the old pair by hand.
# The new defaults get their own test: test-bench-levers.sh.
run_replay() { node "$HUB/bench/replay.mjs" --fleet "$FLEET" --baseline same-mix --partials drop "$@" 2>&1; }

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
# Cost: the legacy figures live in coreModel, which is frozen carry-only same-mix pricing with
# partials dropped and no harness overhead. It anchors the legacy model on this fixture so a
# refactor cannot silently change the legacy arithmetic. Nothing is published; these are fixture
# values, and they must not move for any reason short of a rate-table change.
assert_eq "$(cents 200k coreModel.vanillaCostUsd)" "59506" "200k arm vanilla cost (legacy carry-only model)"
assert_eq "$(cents 1m coreModel.vanillaCostUsd)" "85006" "1m arm vanilla cost (legacy carry-only model)"
assert_eq "$(cents uncapped coreModel.vanillaCostUsd)" "86806" "uncapped arm vanilla cost (legacy carry-only model)"
assert_eq "$(printf '%s' "$all" | jq -r '.arms["1m"].coreModel.vanillaTokens')" "11779000" \
  "and coreModel carries the legacy token figure too"
assert_eq "$(printf '%s' "$all" | jq -r '(.arms["1m"].coreModel.costReductionPct * 10 | round)')" "301" \
  "the 1m arm's legacy cost reduction is 30.1% on this fixture and does not drift"
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
iflt="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-init-model-fleet" --arm 1m \
  --baseline same-mix --partials drop --json 2>&1)"
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

# ── an unrecognized model name is priced conservatively AND named, not silently opus'd ───────────
# fixtures/replay-unknown-model-fleet holds one session whose modelUsage mixes a real tier
# (claude-sonnet-5) with a model name no tier substring matches (claude-ghostwriter-1). The
# session-level tierFallback audit alone would miss this: the session also names a real model, so
# it is "named" and never falls into that bucket. The per-row unknownModels audit must catch the
# unrecognized part anyway. Cost: sonnet part 1,000 in x $2 + 500 out x $10 = $0.007; ghostwriter
# part priced at the Opus fallback ($5/$25): 2,000 x $5 + 1,000 x $25 = $0.035. Total $0.042, which
# the fixture's total_cost_usd is set to exactly, so it reconciles too.
run_unknown() { node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-unknown-model-fleet" \
  --arm 1m --baseline same-mix --partials drop "$@" 2>&1; }
uflt="$(run_unknown --json)"
assert_eq "$?" "0" "the unknown-model fleet replays rather than crashing on the unrecognized name"
assert_eq "$(printf '%s' "$uflt" | jq -r '.tierFallback.sessions')" "0" \
  "the session names a real model too, so it is not a tier-fallback session"
assert_eq "$(printf '%s' "$uflt" | jq -cr '.unknownModels')" '{"claude-ghostwriter-1":1}' \
  "the unrecognized model is named and counted exactly once, not once per arm x baseline recompute"
assert_eq "$(printf '%s' "$uflt" | jq -r '(.arms["1m"].shiploopCostUsd * 1000 | round)')" "42" \
  "the unrecognized part is priced at the conservative Opus fallback rather than crashing or inflating"
assert_eq "$(printf '%s' "$uflt" | jq -r '.reconciliation.medianComputedOverReported')" "1" \
  "which reconciles against the fixture's reported cost"
assert_contains "$(run_unknown)" "claude-ghostwriter-1 x1" \
  "the human report names the unrecognized model by string, not just a count"
assert_contains "$(run_unknown)" "FALLBACK ESTIMATE" \
  "and says plainly that the figure is a fallback estimate, not a priced rate"

# ── Mythos prices at Fable's rate, not the Opus fallback ─────────────────────
# fixtures/replay-fable-family-fleet ticket 604 uses model claude-mythos-5, with no cache activity
# so its own turn (usage all zero) is dropped as a synthetic non-billed message and it never
# touches the carry/overhead chain -- an isolated check of modelUsage pricing alone. Cost:
# 1,000 in x $10 + 1,000 out x $50 = $0.06, which the fixture's total_cost_usd is set to exactly.
fam="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fable-family-fleet" \
  --arm 1m --baseline same-mix --partials drop --json 2>&1)"
assert_eq "$?" "0" "the fable/mythos family fleet replays"
assert_eq "$(printf '%s' "$fam" | jq -cr '.unknownModels')" "{}" \
  "mythos and Fable 5.1 both resolve, so nothing lands in unknownModels"
assert_eq "$(printf '%s' "$fam" | jq -r '.tierFallback.sessions')" "0" \
  "and nothing falls back to the Opus tier either"
assert_eq "$(printf '%s' "$fam" | jq -r '.reconciliation.medianComputedOverReported')" "1" \
  "the mythos ticket's cost reconciles against its own reported total_cost_usd"

# ── Fable 5.1 / Mythos 5.1 read cache at 0.025x, plain Fable/Mythos still read at 0.1x ────────────
# Same fleet, tickets 601-603: 601 (claude-haiku-4-5, 2 turns, context grows 10,000 -> 100,000)
# builds carry of 80,000 tokens and pays no overhead itself (nothing carried into ticket 1). 602
# (claude-fable-5-1) and 603 (claude-fable-5) each re-read that SAME 80,000-token carry in a single
# turn -- 602's own turn contributes 0 further carry growth (one turn, ctx unchanged), so 603 faces
# the identical 80,000 figure, isolating the rate as the only variable between them.
#   602 overhead: 80,000 x ($10 x 0.025) / 1e6 = $0.02   -> vanillaCostUsd = shipCost($0.175) + $0.02 = $0.195
#   603 overhead: 80,000 x ($10 x 0.1)   / 1e6 = $0.08   -> vanillaCostUsd = shipCost($0.175) + $0.08 = $0.255
# shipCost is identical ($0.175, both 15,000 in x $10 + 500 out x $50) because base rates do not
# change between Fable 5 and Fable 5.1 -- only the cache-read multiplier does, so the full $0.06
# spread between the two rows is exactly the multiplier difference, a clean 4x on that one term.
rows="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fable-family-fleet" \
  --arm 1m --baseline same-mix --partials drop --rows 2>&1 | jq -s .)"
row_at() { printf '%s' "$rows" | jq -r ".[] | select(.position == $1) | $2"; }
assert_eq "$(row_at 2 .shipCostUsd)" "0.175" "602 (Fable 5.1): shipCost is unaffected by the cache-read rate"
assert_eq "$(row_at 3 .shipCostUsd)" "0.175" "603 (Fable 5): shipCost is identical to 602's"
assert_eq "$(printf '%s' "$rows" | jq -r '(.[] | select(.position == 2) | .vanillaCostUsd * 10000 | round)')" "1950" \
  "602 (Fable 5.1): the 80,000-token carry re-read at 0.025x input adds exactly \$0.02 of overhead"
assert_eq "$(printf '%s' "$rows" | jq -r '(.[] | select(.position == 3) | .vanillaCostUsd * 10000 | round)')" "2550" \
  "603 (Fable 5): the SAME 80,000-token carry re-read at 0.1x input adds \$0.08, 4x 602's overhead"
assert_eq "$(row_at 2 .vanillaTokens)" "$(row_at 3 .vanillaTokens)" \
  "602 and 603 carry the identical TOKEN count (95,500) -- this is purely a dollar-rate difference"

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
  "--partials drop keeps the arm purely measured: the recovered session is not folded into it"
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
