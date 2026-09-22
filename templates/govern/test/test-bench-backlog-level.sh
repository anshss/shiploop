#!/usr/bin/env bash
# bench: the statistical unit is the BACKLOG, not the (backlog, rep) pair.
#
# Fixture `backlog-level-results.jsonl` is a static, hand-derived results.jsonl (schema: a raw
# kind:"rollup" row per (backlog, arm, rep) cell), THREE backlogs, TWO reps each, no exclusions —
# the shape test-bench-pairing.sh's fixture never exercises because every one of its backlogs has
# exactly one usable rep. Costs, by backlog and rep:
#
#   bl-a  rep1 vanilla $10  shiploop $6     rep2 vanilla $12  shiploop $8
#   bl-b  rep1 vanilla $8   shiploop $9     rep2 vanilla $10  shiploop $11
#   bl-c  rep1 vanilla $20  shiploop $15    rep2 vanilla $22  shiploop $17
#
# A backlog's own delta is (mean_shiploop - mean_vanilla) / mean_vanilla, over ITS OWN two reps —
# never a delta per rep folded in as if it were a second, independent observation:
#
#   bl-a  mean vanilla 11, mean shiploop 7   ->  (7  - 11) / 11 = -36.363636...%
#   bl-b  mean vanilla 9,  mean shiploop 10  ->  (10 -  9) /  9 = +11.111111...%
#   bl-c  mean vanilla 21, mean shiploop 16  ->  (16 - 21) / 21 = -23.809523...%
#
# n=3 (backlogs), never n=6 (pairs) — the whole point of this fixture. Median of the three backlog
# deltas is bl-c's own value, -23.809523...%, since it is the middle of the three when sorted.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/rollup.mjs" ] && [ -f "$HUB/bench/fixtures/backlog-level-results.jsonl" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

B="$HUB/bench/fixtures/backlog-level-results.jsonl"
report="$(node "$HUB/bench/rollup.mjs" "$B" 2>&1)"
assert_eq "$?" "0" "rollup.mjs exits 0 on the backlog-level fixture"
j="$(node "$HUB/bench/rollup.mjs" "$B" --json 2>&1)"
assert_eq "$?" "0" "rollup.mjs --json exits 0 on the backlog-level fixture"

# ── 1. all 6 (backlog, rep) pairs are included, nothing excluded ────────────
assert_eq "$(printf '%s' "$j" | jq -r '.pairs | length')" "6" "1. all 3 backlogs x 2 reps included"
assert_eq "$(printf '%s' "$j" | jq -r '.excluded | length')" "0" "1. nothing excluded"

# ── 2. n counts BACKLOGS, not pairs: 3, never 6 ──────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].n')" "3" \
  "2. n=3 backlogs, not n=6 (backlog, rep) pairs"

# ── 3. the delta is the mean-of-reps arithmetic, not a per-rep delta ────────
# If the code wrongly treated each (backlog, rep) as its own independent observation, n would be
# 6 and the individual per-rep deltas (-40%, -33.3%, +12.5%, +10%, -25%, -22.7%) would appear
# directly; instead each backlog folds to exactly ONE delta, its own reps' means.
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].medianDeltaPct * 1000000 | round)')" "-23809524" \
  "3. median is bl-c's own backlog delta (16-21)/21, the middle of the three when sorted"
assert_contains "$report" "median delta   -23.8%" "3. and the report prints it"
# bl-a's delta, hand-verified: mean vanilla (10+12)/2=11, mean shiploop (6+8)/2=7, delta -36.36%.
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].ci95Pct[0] * 100 | round) / 100')" "-36.36" \
  "3. CI lower bound lands on bl-a's own delta (the bootstrap's minimum with n=3, resample size 3)"
# bl-b's delta, hand-verified: mean vanilla (8+10)/2=9, mean shiploop (9+11)/2=10, delta +11.11%.
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].ci95Pct[1] * 100 | round) / 100')" "11.11" \
  "3. CI upper bound lands on bl-b's own delta (the bootstrap's maximum with n=3, resample size 3)"

# ── 4. models: extracted from real modelUsage-derived rows, both arms, never a run label ───────
assert_contains "$report" "vanilla models claude-opus-4-8" "4. vanilla models, real names"
assert_contains "$report" "shiploop models claude-sonnet-5" "4. shiploop models, real names"

# ── 5. dose response is also backlog-level: one point per backlog, bucketed by MEAN spawns ─────
# bl-a mean shiploop spawns (2+4)/2=3, bl-b mean (1+1)/2=1, bl-c mean (5+5)/2=5: three buckets,
# each n=1 (one backlog), each median exactly that backlog's own delta.
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns | length')" "3" \
  "5. one bucket per distinct rounded mean-spawn count, one per backlog"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns[] | select(.bucket==3) | .n')" "1" \
  "5. the spawns=3 bucket is bl-a alone"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns[] | select(.bucket==3) | (.medianDeltaPct*100|round)/100')" \
  "-36.36" "5. and its median is bl-a's own delta"
# All three backlogs carry 2 tickets each, so ticket-count dose response collapses to ONE bucket
# holding all three backlog deltas — its median is the same -23.8% as the headline.
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byTicketCount | length')" "1" \
  "5. one ticket-count bucket (every backlog here has 2 tickets)"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byTicketCount[0].n')" "3" \
  "5. holding all three backlogs"

# ── 6. quality: majority vote WITHIN a backlog's reps, before the better/worse/same count ──────
# bl-a a1: vanilla 2/2, shiploop 2/2 -> same.  a2: vanilla 0/2, shiploop 1/2 (TIE, not a strict
#   majority) -> not cleared either arm -> same.
# bl-b b1: vanilla 0/2, shiploop 2/2 -> shiploop-only clears it -> better.
#   b2: vanilla 2/2, shiploop 2/2 -> same.
# bl-c c1: vanilla 2/2, shiploop 0/2 -> vanilla-only clears it -> worse.
#   c2: vanilla 2/2, shiploop 2/2 -> same.
# 6 tickets compared total (2 per backlog x 3 backlogs); one better, one worse, four same — proof
# that a 1-of-2 split is NOT counted as a majority clear (a2 would otherwise wrongly read "better").
assert_eq "$(printf '%s' "$j" | jq -r '.quality.ticketsCompared')" "6" "6. 2 tickets x 3 backlogs"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.better')" "1" "6. one ticket only shiploop's majority clears (b1)"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.worse')" "1" "6. one ticket only vanilla's majority clears (c1)"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.same')" "4" \
  "6. the rest agree, INCLUDING a2's 1-of-2 tie counting as not-cleared on both sides"

assert_done
