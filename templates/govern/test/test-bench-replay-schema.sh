#!/usr/bin/env bash
# bench: the shape of `replay.mjs --json`.
#
# The replay JSON is what anything downstream (a site build, a release note, a spreadsheet) reads,
# so its keys are a contract. This test locks the key set and the invariants that make a number
# safe to quote: provenance travels with the number, every arm carries its own n, and the
# reconciliation ratio is present whether or not anyone looks at it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-fleet"
j="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm all --json 2>&1)"
assert_eq "$?" "0" "--json exits 0 on the fixture fleet"

printf '%s' "$j" | jq -e . >/dev/null 2>&1
assert_eq "$?" "0" "--json emits parseable JSON and nothing else"

# ── top level ────────────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r 'keys | join(",")')" \
  "arms,fleets,kind,meta,partialRecovery,provenance,reconciliation,scope,sessionsExcludedNoResultEvent,tierFallback" \
  "the top-level key set is the contract"
assert_eq "$(printf '%s' "$j" | jq -r '.kind')" "replay" "kind names the tool that produced it"
assert_contains "$(printf '%s' "$j" | jq -r '.provenance')" "MODELED COUNTERFACTUAL" \
  "provenance travels inside the JSON, so a consumer cannot quote the number without it"
assert_contains "$(printf '%s' "$j" | jq -r '.provenance')" "No vanilla session was run" \
  "and states plainly that the vanilla arm was never executed"

# ── meta (ticket #104: version/model/date next to the headline, not buried in stdout) ─────────
assert_eq "$(printf '%s' "$j" | jq -r '.meta | keys | join(",")')" \
  "cliVersions,dateRange,models,runsSeenKept,runsSeenTotal,since" \
  "meta carries exactly the fields the headline prints"
assert_eq "$(printf '%s' "$j" | jq -r '.meta.since')" "null" "no --since given -> since is null"
assert_eq "$(printf '%s' "$j" | jq -r '.meta.runsSeenKept')" "$(printf '%s' "$j" | jq -r '.meta.runsSeenTotal')" \
  "no --since given -> nothing is filtered out"

# ── arms ─────────────────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.arms | keys | join(",")')" "1m,200k,uncapped" \
  "--arm all emits every arm"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | keys | join(",")')" \
  "arm,ceilingCostReductionPct,ceilingTokenReductionPct,contextWindow,costReductionPct,label,medianTicketsPerRun,positionCurve,runs,sensitivityWithRecoveredPartials,sharedOutputCostUsd,shiploopBreakdown,shiploopCostUsd,shiploopTokens,tickets,ticketsInModeledRuns,tokenReductionPct,vanillaBreakdown,vanillaCostUsd,vanillaTokens" \
  "each arm carries its own key set"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[] | select(.runs > 0 and .tickets > 0)] | length')" "3" \
  "every arm reports its own n runs and n tickets"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].arm')" "1m" "the arm names itself"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].medianTicketsPerRun')" "4" \
  "the arm reports how many tickets a run clears, which is what the saving is a function of"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].label')" "a 1M-context session" \
  "the arm carries the sentence a caller should print beside the number"

# The reduction percentages must be the ones implied by the token and cost totals. A consumer that
# recomputes them must land on the same figure.
assert_eq "$(printf '%s' "$j" | jq -r '
  [.arms[] | ((100 * (.vanillaTokens - .shiploopTokens) / .vanillaTokens) - .tokenReductionPct | fabs < 1e-9)]
  | all')" "true" "tokenReductionPct is exactly what the totals imply"
assert_eq "$(printf '%s' "$j" | jq -r '
  [.arms[] | ((100 * (.vanillaCostUsd - .shiploopCostUsd) / .vanillaCostUsd) - .costReductionPct | fabs < 1e-9)]
  | all')" "true" "costReductionPct is exactly what the totals imply"

# The breakdown is where the whole model lives: the two arms differ in exactly two components.
# Input and output are identical by construction (same work, same code written), the carry lands
# entirely in cache reads, and the refunded per-session re-prime lands entirely in cache writes.
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | .shiploopBreakdown.input == .vanillaBreakdown.input')" "true" \
  "input is identical in both arms"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | .shiploopBreakdown.output == .vanillaBreakdown.output')" "true" \
  "output is identical in both arms: it is the same work, and it is a shared fixed cost"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | .vanillaBreakdown.cacheRead > .shiploopBreakdown.cacheRead')" "true" \
  "the modeled carry lands in cache reads"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | .vanillaBreakdown.cacheCreation < .shiploopBreakdown.cacheCreation')" "true" \
  "and the re-prime that only fresh sessions pay is refunded out of cache writes"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | [.vanillaBreakdown[]] | add')" "11779000" \
  "the vanilla breakdown sums to the vanilla total"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"] | [.shiploopBreakdown[]] | add')" "5215000" \
  "the shiploop breakdown sums to the shiploop total"

# The ceiling is not decoration. Output is a cost no architecture removes, so no arm can ever
# report a reduction above it, and a model that did would be broken rather than impressive.
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[] | .tokenReductionPct < .ceilingTokenReductionPct] | all')" "true" \
  "no arm reports a token reduction above the ceiling"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[] | .costReductionPct < .ceilingCostReductionPct] | all')" "true" \
  "no arm reports a cost reduction above the ceiling"
# Fixture output: 115,000 tokens, 90,000 opus at $25/M ($2.25) + 25,000 sonnet at $10/M ($0.25).
assert_eq "$(printf '%s' "$j" | jq -r '(.arms["1m"].sharedOutputCostUsd * 10000 | round)')" "25000" \
  "the shared output cost is priced per model, not at one blended rate"

# ── position curve ───────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].positionCurve | keys | join(",")')" "1,2,3,5,8" \
  "the position curve reports positions 1, 2, 3, 5 and 8"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[].positionCurve["1"] | .medianTokenReductionPct] | unique | join(",")')" "0" \
  "ticket 1 saves 0% in every arm, because nothing has been carried yet"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].positionCurve["8"] | keys | join(",")')" \
  "medianTokenReductionPct,n" "each curve point carries its own sample count"

# ── reconciliation and exclusions ────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.reconciliation | keys | join(",")')" \
  "medianComputedOverReported,n,within2pct" "the reconciliation self-check has a fixed shape"
assert_eq "$(printf '%s' "$j" | jq -r '.sessionsExcludedNoResultEvent')" "1" \
  "exclusions are reported as a count, never dropped silently"
assert_eq "$(printf '%s' "$j" | jq -r '.tierFallback.sessions')" "0" \
  "no fixture session falls outside the rate table"
assert_eq "$(printf '%s' "$j" | jq -r '.partialRecovery | keys | join(",")')" \
  "outputRecoverable,recoverableInputSideTokens,sessions" "the recovery audit has a fixed shape"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[].sensitivityWithRecoveredPartials | keys | join(",")] | unique | join(" | ")')" \
  "costReductionDeltaPts,costReductionPct,shiploopCostUsd,shiploopTokens,tokenReductionDeltaPts,tokenReductionPct,vanillaCostUsd,vanillaTokens" \
  "every arm carries the same sensitivity shape"
# The delta must be the signed difference the two figures imply, so a consumer cannot read it
# backwards and turn a drag on the headline into a boost.
assert_eq "$(printf '%s' "$j" | jq -r '
  [.arms[] | ((.sensitivityWithRecoveredPartials.tokenReductionPct - .tokenReductionPct)
              - .sensitivityWithRecoveredPartials.tokenReductionDeltaPts | fabs < 1e-9)] | all')" "true" \
  "tokenReductionDeltaPts is the signed difference from the measured arm"

# ── fleets ───────────────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.fleets | length')" "1" "one fleet was read"
assert_eq "$(printf '%s' "$j" | jq -r '.fleets[0] | keys | join(",")')" "fleet,tickets,transcripts" \
  "each fleet row names itself and what was found in it"
assert_eq "$(printf '%s' "$j" | jq -r '.fleets[0].transcripts')" "5" \
  "state.jsonl is not counted as a transcript"

# ── a single arm emits only that arm ─────────────────────────────────────────
one="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 200k --json 2>&1)"
assert_eq "$(printf '%s' "$one" | jq -r '.arms | keys | join(",")')" "200k" "--arm 200k emits one arm"

# ── an empty fleet is still valid JSON with a zeroed arm, not a crash ────────
e="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-empty-fleet" --arm 1m --json 2>&1)"
rc=$?
assert_eq "$rc" "1" "an empty fleet exits non-zero"
assert_eq "$(printf '%s' "$e" | jq -r '.arms["1m"].tickets')" "0" "and reports zero tickets"
assert_eq "$(printf '%s' "$e" | jq -r '.arms["1m"].tokenReductionPct')" "null" \
  "and reports no reduction rather than a fabricated one"

# ── --rows: the anonymized recomputable evidence, ticket #104 ────────────────
rows="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --rows 2>&1)"
assert_eq "$(printf '%s\n' "$rows" | jq -sr 'map(select(true)) | length > 0')" "true" \
  "--rows emits at least one line"
assert_eq "$(printf '%s\n' "$rows" | jq -sr 'map(has("run") and has("position") and has("shipTokens") and has("shipCostUsd") and has("vanillaTokens") and has("vanillaCostUsd")) | all')" \
  "true" "every row carries run id, depth, and both arms' tokens/cost"
assert_eq "$(printf '%s\n' "$rows" | jq -sr 'map(has("fleet") or has("ticket")) | any')" "false" \
  "no row leaks the fleet path or the internal ticket id"
assert_eq "$(printf '%s\n' "$rows" | jq -r '.run' | head -1 | grep -Ec '^[0-9a-f]{16}$')" "1" \
  "the run id is an opaque hash, not the real run-<timestamp> directory name"

assert_done
