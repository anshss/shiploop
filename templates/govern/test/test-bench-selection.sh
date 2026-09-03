#!/usr/bin/env bash
# bench: backlog selection ranking (spec section 3).
#
# The selection tool is where the favorability lives, so it is the piece most worth locking down.
# Fixture `selection-results.jsonl` holds five backlogs:
#
#   bl-a  $40.00 -> $2.00   95.0% cut, both arms clear
#   bl-b  $30.00 -> $3.00   90.0% cut, both arms clear
#   bl-c  $20.00 -> $8.00   60.0% cut, both arms clear
#   bl-d  $25.00 -> $5.00   80.0% on paper, but VANILLA cleared 5 of 8 tickets
#   bl-e  the run hit BENCH_MAX_USD, so shiploop is recorded capped at $0.00
#
# Contract:
#   1. eligible backlogs rank by cost delta, descending: bl-a, bl-b, bl-c
#   2. an arm that failed to clear drops the backlog, however good its delta looks (bl-d)
#   3. a capped run drops the backlog, so hitting the cap can never look like a saving (bl-e)
#   4. the kept set grows best-first and stops as soon as the AGGREGATE clears the floor, with a
#      published minimum of two backlogs. At floor 65 that is bl-a + bl-b: (70 - 5) / 70 = 92.86%
#   5. a floor nothing can reach keeps at most --keep-max and still emits the true, lower number
#   6. the report always states the all-eligible aggregate next to the kept-set one, so nobody
#      publishes the selected figure without knowing the unselected one
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/rollup.mjs" ] && [ -f "$HUB/bench/fixtures/selection-results.jsonl" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

S="$HUB/bench/fixtures/selection-results.jsonl"
j="$(node "$HUB/bench/rollup.mjs" "$S" --json 2>&1)"
assert_eq "$?" "0" "rollup.mjs exits 0 on the selection fixture"

# ── 1. ranking ──────────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.selection.ranked | join(",")')" "bl-a,bl-b,bl-c" \
  "1. eligible backlogs rank by cost delta, largest first"
assert_eq "$(printf '%s' "$j" | jq -r '[ .perBacklog[] | select(.eligible) | .costPct | round ] | join(",")')" \
  "95,90,60" "1. the per-backlog deltas are what the ranking sorted on"

# ── 2 + 3. drops ────────────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.selection.dropped | map(.backlog) | join(",")')" "bl-d,bl-e" \
  "2+3. exactly the incomparable backlogs are dropped"
assert_eq "$(printf '%s' "$j" | jq -r '.selection.dropped[] | select(.backlog=="bl-d") | .reason')" \
  "an arm failed to clear the backlog" "2. an unclear arm drops the backlog, 80% delta or not"
assert_eq "$(printf '%s' "$j" | jq -r '.selection.dropped[] | select(.backlog=="bl-e") | .reason')" \
  "run hit BENCH_MAX_USD (status capped)" "3. a capped run drops the backlog"
assert_eq "$(printf '%s' "$j" | jq -r '.selection.ranked | index("bl-d") // "absent"')" "absent" \
  "2. a dropped backlog never enters the ranking"

# ── 4. the stopping rule ────────────────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.selection.kept | join(",")')" "bl-a,bl-b" \
  "4. the kept set stops as soon as the aggregate clears the floor"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.backlogs')" "2" \
  "4. two is the published minimum, never a single backlog wearing a plural"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.vanillaCostUsd')" "70" "4. kept vanilla total"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.shiploopCostUsd')" "5" "4. kept shiploop total"
assert_eq "$(printf '%s' "$j" | jq -r '(.aggregateKept.costPct * 10 | round)')" "929" \
  "4. the aggregate over the kept set is 92.9%, not the best member's 95%"
assert_eq "$(printf '%s' "$j" | jq -r '.headline.pct')" "92" "4. the headline floors that aggregate"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.tickets')" "15" \
  "4. the ticket count in the sentence is the kept set's, not the whole pool's"

# A floor already cleared by the first two must not pull in a third.
assert_eq "$(node "$HUB/bench/rollup.mjs" "$S" --json --floor 50 2>&1 | jq -r '.selection.kept | join(",")')" \
  "bl-a,bl-b" "4. a lower floor still keeps the minimum two, not fewer"

# ── 5. an unreachable floor ─────────────────────────────────────────────────
hi="$(node "$HUB/bench/rollup.mjs" "$S" --floor 99 2>&1)"
hij="$(node "$HUB/bench/rollup.mjs" "$S" --json --floor 99 2>&1)"
assert_eq "$(printf '%s' "$hij" | jq -r '.selection.kept | join(",")')" "bl-a,bl-b,bl-c" \
  "5. an unreachable floor keeps at most --keep-max backlogs"
assert_eq "$(printf '%s' "$hij" | jq -r '.headline.pct')" "85" \
  "5. and the headline is the true, lower aggregate"
assert_contains "$hi" "is below the 99% floor" "5. the shortfall is stated, not quietly rounded away"
assert_contains "$hi" "do not round it up" "5. with the instruction the spec requires"

assert_eq "$(node "$HUB/bench/rollup.mjs" "$S" --json --floor 99 --keep-max 2 2>&1 | jq -r '.selection.kept | join(",")')" \
  "bl-a,bl-b" "5. --keep-max bounds the set"

# ── 6. the internal record sits next to the published one ───────────────────
report="$(node "$HUB/bench/rollup.mjs" "$S" 2>&1)"
assert_contains "$report" "internal record: over ALL eligible backlogs the cut is 85.6%, not 92.9%" \
  "6. the unselected aggregate is always reported alongside the selected one"
assert_eq "$(printf '%s' "$j" | jq -r '(.aggregateAllEligible.costPct * 10 | round)')" "856" \
  "6. and is available in --json for the private record"

assert_done
