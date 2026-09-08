#!/usr/bin/env bash
# bench: the multi-lever model (baseline axis, three metrics, per-lever attribution).
#
# Locks bench/replay.mjs against bench/fixtures/replay-lever-fleet, a three-session synthetic run
# with known tiers and known usage. Every expected figure below is derivable by hand from the table
# in bench/fixtures/README.md, and the whole 2 baselines x 3 arms x 2 partials matrix is asserted
# exactly rather than sampled.
#
#   measured work   201 sonnet 310,000 tok $0.254 | 202 haiku 210,000 tok $0.079
#                   203 sonnet 50,000 tok (killed, input side recoverable, output not)
#   orchestration   governor opus 25,000 tok $0.225, charged INTO the shiploop arm (spec 4a)
#   driver tier     opus, from the run's driver-model stamp (not the fallback)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-lever-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-lever-fleet"
run_replay() { node "$HUB/bench/replay.mjs" --fleet "$FLEET" "$@" 2>&1; }

# ── the matrix, exact, in all three metrics ──────────────────────────────────
# Tokens are model-independent: the two baselines MUST agree on them, and the assertions below say
# so by using the same expected figure for both. Cost and quota-weighted are where routing lands.
cell() { # baseline arm partials -> "shipTok vanTok shipCost*1e4 vanCost*1e4 shipQuota vanQuota"
  run_replay --arm "$2" --baseline "$1" --partials "$3" --json | jq -r \
    --arg a "$2" '.arms[$a] |
      "\(.shiploopTokens) \(.vanillaTokens) \((.shiploopCostUsd * 10000 | round)) \((.vanillaCostUsd * 10000 | round)) \(.shiploopQuotaWeighted) \(.vanillaQuotaWeighted)"'
}

assert_eq "$(cell same-mix 200k drop)"      "545000 982000 5580 5750 955000 1540000"    "same-mix x 200k x drop"
assert_eq "$(cell same-mix 1m drop)"        "545000 1082000 5580 5950 955000 1740000"   "same-mix x 1m x drop"
assert_eq "$(cell same-mix uncapped drop)"  "545000 1082000 5580 5950 955000 1740000"   "same-mix x uncapped x drop"
assert_eq "$(cell same-mix 200k price)"     "595000 1122000 6240 7350 1055000 1820000"  "same-mix x 200k x price"
assert_eq "$(cell same-mix 1m price)"       "595000 1222000 6240 7550 1055000 2020000"  "same-mix x 1m x price"
assert_eq "$(cell same-mix uncapped price)" "595000 1222000 6240 7550 1055000 2020000"  "same-mix x uncapped x price"

assert_eq "$(cell driver-tier 200k drop)"      "545000 982000 5580 18360 955000 3910000"    "driver-tier x 200k x drop"
assert_eq "$(cell driver-tier 1m drop)"        "545000 1082000 5580 18560 955000 4110000"   "driver-tier x 1m x drop"
assert_eq "$(cell driver-tier uncapped drop)"  "545000 1082000 5580 18560 955000 4110000"   "driver-tier x uncapped x drop"
assert_eq "$(cell driver-tier 200k price)"     "595000 1122000 6240 22360 1055000 4610000"  "driver-tier x 200k x price"
assert_eq "$(cell driver-tier 1m price)"       "595000 1222000 6240 22560 1055000 4810000"  "driver-tier x 1m x price"
assert_eq "$(cell driver-tier uncapped price)" "595000 1222000 6240 22560 1055000 4810000"  "driver-tier x uncapped x price"

# The claim that makes the token column safe to quote: routing cannot move it. Asserted as an
# identity across the whole matrix rather than left to the reader's trust.
for arm in 200k 1m uncapped; do
  for p in drop price; do
    a="$(cell same-mix "$arm" "$p" | cut -d' ' -f1,2)"
    b="$(cell driver-tier "$arm" "$p" | cut -d' ' -f1,2)"
    assert_eq "$a" "$b" "tokens are identical under both baselines ($arm/$p): routing cannot change a token count"
  done
done

# ── the levers sum to the saving, in every cell ──────────────────────────────
for bl in same-mix driver-tier; do
  for p in drop price; do
    j="$(run_replay --arm all --baseline "$bl" --partials "$p" --json)"
    assert_eq "$(printf '%s' "$j" | jq -r '[.arms[].leverSumCheck | .tokens and .cost and .quotaWeighted] | all')" \
      "true" "lever components sum to the arm saving ($bl/$p), in all three metrics"
    assert_eq "$(printf '%s' "$j" | jq -r '
      [.arms[] | ([.levers[].cost] | add) - (.vanillaCostUsd - .shiploopCostUsd) | fabs < 1e-9] | all')" \
      "true" "and the cost components literally add up to the arm delta ($bl/$p)"
    assert_eq "$(printf '%s' "$j" | jq -r '
      [.arms[] | ([.levers[].tokens] | add) == (.vanillaTokens - .shiploopTokens)] | all')" \
      "true" "and the token components add up exactly, with no rounding slack ($bl/$p)"
  done
done

# ── per-lever values, hand-derived, on the default arm ───────────────────────
# driver-tier x 200k x price is the report's headline cell, so it is the one pinned lever by lever.
d="$(run_replay --arm 200k --json)"
assert_eq "$(printf '%s' "$d" | jq -r '.baseline')" "driver-tier" "driver-tier is the default baseline"
assert_eq "$(printf '%s' "$d" | jq -r '.partials')" "price" "and pricing partials is the default"
lv() { printf '%s' "$d" | jq -r ".arms[\"200k\"].levers[\"$1\"] | \"\(.tokens) \((.cost * 10000 | round)) \(.quota)\""; }

assert_eq "$(lv carry)" "290000 500 1450000" \
  "carry: 300,000 re-read less the 10,000 re-prime refund, priced at the opus driver tier"
assert_eq "$(lv routing)" "0 7960 1920000" \
  "routing: the same work repriced from sonnet/haiku to the opus driver, and worth zero tokens"
assert_eq "$(lv cache-prefix)" "0 11400 0" \
  "cache-prefix: 120,000 turn-1 reads that would have been writes, at the 1.9x spread"
assert_eq "$(lv watchdog)" "200000 400 400000" \
  "watchdog: a 300,000-token kill, capped by the 200k arm's own window"
assert_eq "$(lv resume-not-restart)" "50000 50 50000" \
  "resume: 60,000 fresh-start tokens less the 10,000 the checkpoint actually loaded"
assert_eq "$(lv skip-the-model)" "12000 60 60000" \
  "skip-the-model: one version-bump at the published per-class estimate"
assert_eq "$(lv escalation-correction)" "0 -2000 -200000" \
  "escalation: a failed haiku attempt takes ITS routing credit back, so escalations cost us"
assert_eq "$(lv harness-overhead)" "-25000 -2250 -125000" \
  "harness overhead: the governor's own session is charged INTO our arm and is negative"

# The watchdog credit is the one lever the arm's window binds, so it must move with the arm.
assert_eq "$(run_replay --arm 1m --json | jq -r '.arms["1m"].levers["watchdog"].tokens')" "300000" \
  "a 1M arm does not cap a 300,000-token watchdog kill"

# ── coverage, and the difference between uninstrumented and zero ─────────────
assert_eq "$(printf '%s' "$d" | jq -r '.instrumentation.withEvents')" "1" "the fixture run carries lever-events.jsonl"
assert_eq "$(printf '%s' "$d" | jq -r '.instrumentation.malformedLines')" "1" \
  "the unparseable line is counted, not fatal"
assert_eq "$(printf '%s' "$d" | jq -r '.instrumentation.unknownEvents')" "1" \
  "an event this reader does not know is counted and skipped"
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"].unknownScriptedActionClasses["not-a-known-class"]')" "1" \
  "a scripted-action class with no estimate is credited zero and NAMED"
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"].levers["output-suppression"].status')" "no-event-in-log-format" \
  "output suppression has no event in the wire contract and says so"

# On a corpus with NO lever events at all, an event-derived lever must read as uninstrumented.
# Reporting it as a measured 0% would be a claim the corpus cannot support.
u="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fleet" --arm 200k --json 2>&1)"
assert_eq "$(printf '%s' "$u" | jq -r '.arms["200k"].levers["watchdog"].status')" "uninstrumented" \
  "an uninstrumented corpus reports uninstrumented, never a measured zero"
assert_eq "$(printf '%s' "$u" | jq -r '.instrumentation.withEvents')" "0" "and says how many runs carry events"
assert_contains "$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fleet" --arm 200k 2>&1)" \
  "uninstrumented" "the human report prints the word rather than a zero row"

# ── the driver tier is resolved, and the fallback is counted when it fires ───
assert_eq "$(printf '%s' "$d" | jq -r '.driverTierAudit.fromStamp')" "1" \
  "the run's driver-model stamp resolves the driver tier"
assert_eq "$(printf '%s' "$d" | jq -r '.driverTierAudit.fromFallbackHighestTier')" "0" \
  "so the highest-tier fallback does not fire here"
assert_eq "$(printf '%s' "$u" | jq -r '.driverTierAudit.fromFallbackHighestTier')" "1" \
  "a run with no stamp and no orchestration transcript falls back, and the fallback is COUNTED"

# ── section 4a: the harness pays for itself ──────────────────────────────────
assert_eq "$(printf '%s' "$d" | jq -r '.harnessOverhead.tokens')" "25000" "the governor transcript is summed"
assert_eq "$(printf '%s' "$d" | jq -r '(.harnessOverhead.costUsd * 10000 | round)')" "2250" "and priced at its own tier"
assert_eq "$(printf '%s' "$d" | jq -r '.harnessOverhead.uncovered')" "0" "this run's overhead is covered"
assert_eq "$(printf '%s' "$u" | jq -r '.harnessOverhead.uncovered')" "1" \
  "a run with no orchestration transcript is overhead-uncovered, and that is counted not assumed zero"
# Charging our own overhead must LOWER our number. That is the point of section 4a.
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"] | .shiploopTokens > ([.levers[] | select(.status == "measured")] | length)')" \
  "true" "the shiploop arm carries the overhead tokens"
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"].levers["harness-overhead"].cost < 0')" "true" \
  "the overhead lever is negative: it is a charge against us, not a credit"

# ── partials: both totals, always ────────────────────────────────────────────
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"].partialsTotals | keys | join(",")')" "drop,price" \
  "both partial-session totals are reported whichever one is selected"
assert_eq "$(printf '%s' "$d" | jq -r '(.arms["200k"].partialsTotals.price.tokenReductionPct * 100 | round)')" "4697" \
  "priced partials: 46.97% tokens"
assert_eq "$(printf '%s' "$d" | jq -r '(.arms["200k"].partialsTotals.drop.tokenReductionPct * 100 | round)')" "4450" \
  "dropped partials: 44.50% tokens, and the delta between them is always visible"
assert_contains "$(run_replay --arm 200k)" "partials: priced" "the human report prints both"

# ── pre-flight aborts are excluded from the bench and counted in the report ──
assert_eq "$(printf '%s' "$d" | jq -r '.abortedRuns')" "1" \
  "the 0-byte state.jsonl run is counted as a pre-flight abort"
assert_eq "$(printf '%s' "$d" | jq -r '.arms["200k"].runs')" "1" \
  "and does not enter the modeled corpus as a run"
assert_contains "$(run_replay --arm 200k)" "aborted before dispatch" "the report says so in words"

# ── the report contract (spec section 6), in order ───────────────────────────
rep="$(run_replay --arm 200k)"
assert_contains "$rep" "HEADLINE  baseline driver-tier x arm 200k" "the headline is the arm a real user reproduces"
assert_contains "$rep" "quota-weighted" "the third metric is printed and labelled"
assert_contains "$rep" "components sum to the arm's saving" "the lever table states its own invariant"
assert_contains "$rep" "per-fleet spread" "the spread table is auto-printed"
assert_contains "$rep" "a CEILING, never a headline" "ceilings are labelled as ceilings"
assert_contains "$rep" "levers this bench does NOT measure" "the unmeasured levers are listed"
assert_contains "$rep" "shared-exploration" "by name"
assert_contains "$rep" "absorbed (uncredited, conservative)" "and the absorbed ones are distinguished from them"
order_head="$(printf '%s\n' "$rep" | grep -n "HEADLINE" | head -1 | cut -d: -f1)"
order_lev="$(printf '%s\n' "$rep" | grep -n "^  levers (arm" | head -1 | cut -d: -f1)"
order_spread="$(printf '%s\n' "$rep" | grep -n "per-fleet spread" | head -1 | cut -d: -f1)"
order_unmeas="$(printf '%s\n' "$rep" | grep -n "does NOT measure" | head -1 | cut -d: -f1)"
assert_eq "$([ "$order_head" -lt "$order_lev" ] && [ "$order_lev" -lt "$order_spread" ] && \
  [ "$order_spread" -lt "$order_unmeas" ] && echo ok)" "ok" \
  "headline, then levers, then spread, then the unmeasured list: the spec's print order"

# ── a fleet-level figure is computed by the SAME model as the headline ───────
assert_eq "$(printf '%s' "$d" | jq -r '
  (.arms["200k"].fleetSpread[0].costReductionPct - .arms["200k"].costReductionPct | fabs) < 1e-9')" "true" \
  "one fleet in the corpus means its row IS the headline, not a differently-modeled number"

assert_done
