#!/usr/bin/env bash
# bench: paired-comparison rollup (median, bootstrap CI, Wilcoxon, sign test, dose response).
#
# Fixture `pairing-results.jsonl` is a static, hand-derived results.jsonl (schema: a raw
# kind:"rollup" row per (backlog, arm, rep) cell, same shape bench::record_rollup writes). Two
# backlogs, two reps each, plus a third backlog excluded for an infra-class error:
#
#   bl-x rep 1   vanilla $10.00 -> shiploop $6.00    cost delta -40%, workerSpawns=2, 3 tickets
#   bl-x rep 2   shiploop status void-no-activation (workerSpawns=0)               -- EXCLUDED
#   bl-y rep 1   vanilla $8.00  -> shiploop $9.60     cost delta +20%, workerSpawns=3, 4 tickets
#   bl-y rep 2   shiploop status capped                                           -- EXCLUDED
#   bl-z rep 1   shiploop status error (a session/usage limit, API error, or auth outage)  -- EXCLUDED
#
# so exactly 2 pairs are included (n=2), one cheaper and one more expensive — a losing backlog is
# INCLUDED, never dropped, which is the whole point of retiring the old best-first selection. Every
# number below is arithmetic on those two rows (bl-z never enters the included set, so it changes
# nothing downstream of pairing); the CI bounds are a locked snapshot of the fixed-seed bootstrap
# (deterministic: the same file always reproduces the same bounds, forever).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/rollup.mjs" ] && [ -f "$HUB/bench/fixtures/pairing-results.jsonl" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

P="$HUB/bench/fixtures/pairing-results.jsonl"
report="$(node "$HUB/bench/rollup.mjs" "$P" 2>&1)"
assert_eq "$?" "0" "rollup.mjs exits 0 on the pairing fixture"
j="$(node "$HUB/bench/rollup.mjs" "$P" --json 2>&1)"
assert_eq "$?" "0" "rollup.mjs --json exits 0 on the pairing fixture"

# ── 1. every backlog is analysed, nothing ranked, nothing selected ──────────
assert_not_contains "$report" "Selection" "1. there is no selection section left at all"
assert_not_contains "$(cat "$HUB/bench/rollup.mjs")" "keepMax" "1. --keep-max is gone"
assert_not_contains "$(cat "$HUB/bench/rollup.mjs")" "opts.floor" "1. the headline floor option is gone"

# ── 2. pairing: the unit is (backlog, rep), symmetric exclusion, reasons listed ──
assert_eq "$(printf '%s' "$j" | jq -r '.pairs | length')" "2" "2. exactly 2 (backlog, rep) pairs included"
assert_eq "$(printf '%s' "$j" | jq -r '[.pairs[] | .backlog] | sort | join(",")')" "bl-x,bl-y" \
  "2. one pair from each backlog — a losing backlog (bl-y) is included, never dropped"
assert_eq "$(printf '%s' "$j" | jq -r '.excluded | length')" "3" "2. exactly 3 pairs excluded"
assert_eq "$(printf '%s' "$j" | jq -r '.excluded[] | select(.backlog=="bl-x") | .reason')" \
  "void-no-activation" "2. the zero-worker-spawn shiploop cell excludes its pair, reason named"
assert_eq "$(printf '%s' "$j" | jq -r '.excluded[] | select(.backlog=="bl-y") | .reason')" \
  "capped" "2. a capped cell excludes its pair, reason named"
assert_eq "$(printf '%s' "$j" | jq -r '.excluded[] | select(.backlog=="bl-z") | .reason')" \
  "error" "2. an infra-class error excludes its pair, reason named, never void-no-activation or capped"
assert_contains "$report" "excluded bl-x rep 2: void-no-activation" "2. the report lists the exclusion, not just the count"
assert_contains "$report" "excluded bl-y rep 2: capped" "2. and the other one"
assert_contains "$report" "excluded bl-z rep 1: error" "2. and the infra-class-error exclusion"

# ── 3. every metric in the spec's list is reported, cost first and marked primary ──
for m in "cost (USD)" "all-in tokens" "billable tokens" "output tokens" "cache-read tokens" \
         "fresh input (input + cache creation)" "turns"; do
  assert_contains "$report" "$m" "3. metric reported: $m"
done
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].key')" "cost" "3. cost is the first metric"
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].primary')" "true" "3. and the only one marked primary"
assert_eq "$(printf '%s' "$j" | jq -r '[.metrics[1:][] | .primary] | any')" "false" \
  "3. no other metric is marked primary"

# ── 4. the arithmetic: median, CI, Wilcoxon, pooled ratio, all on the cost cut ──
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].n')" "2" "4. cost metric sees both included pairs"
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].medianDeltaPct * 10 | round)')" "-100" \
  "4. median cost delta is exactly the average of -40% and +20%: -10.0%"
assert_contains "$report" "median delta   -10.0%" "4. and the report prints it"
# CI bounds are a deterministic bootstrap snapshot (fixed seed) over the two source deltas
# (-0.4, +0.2): every resample is one of {-0.4,-0.4}, {-0.4,+0.2}, {+0.2,+0.2}, so the 95% interval
# collapses onto the two source values themselves. Re-running never changes this number.
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].ci95Pct[0] * 10 | round)')" "-400" "4. CI lower bound"
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].ci95Pct[1] * 10 | round)')" "200" "4. CI upper bound"
# n=2 can never reach significance under an exact Wilcoxon test — the minimum achievable two-sided
# p at n=2 with one value each sign is 1.0, hand-verified: doubled ranks {2,4}, 4 equally likely
# subset sums {0,2,4,6}, observed sum 2 has P(<=2)=0.5 and P(>=2)=0.75, so p = 2*min(...) = 1.0.
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].wilcoxonP')" "1" "4. Wilcoxon p is exactly 1.0 at n=2"
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].wilcoxonMethod')" "exact" "4. n<=25 uses the exact method"
assert_contains "$report" "Wilcoxon p     1.000 (exact)" "4. and the report names the method"
# Pooled totals ratio is the secondary line: (6 + 9.6) / (10 + 8) = 15.6 / 18 = 0.8666...
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].pooledRatio * 1000 | round)')" "867" \
  "4. pooled totals ratio is the sum of the parts, not an average of the per-pair ratios"
assert_contains "$report" "pooled totals  \$18.00 -> \$15.60, ratio 0.867x" "4. and it prints in the report"

# ── 5. a metric where both pairs move the SAME direction hits the p=0.5 floor ──
# fresh input = input + cache creation: bl-x +20.0%, bl-y +26.67% — both positive, so the exact
# test cannot reach below 0.5 no matter the magnitude (hand-verified the same way as case 4).
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[] | select(.key=="freshInput") | .wilcoxonP')" "0.5" \
  "5. same-direction pairs floor the exact p-value at 0.5, never lower, at n=2"

# ── 6. quality: per-ticket, within included pairs only, sign test over discordant tickets ──
# bl-x: t1,t2 same (both cleared), t3 better (shiploop only). bl-y: u1,u3,u4 same, u2 better.
assert_eq "$(printf '%s' "$j" | jq -r '.quality.ticketsCompared')" "7" "6. 3 + 4 tickets compared"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.better')" "2" "6. two tickets only shiploop cleared"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.worse')" "0" "6. none only vanilla cleared"
assert_eq "$(printf '%s' "$j" | jq -r '.quality.same')" "5" "6. the rest agree"
# vanilla cleared t1,t2,u1 = 3/7; shiploop cleared t1,t2,t3,u1,u2 = 5/7.
assert_eq "$(printf '%s' "$j" | jq -r '(.quality.vanillaClearRatePct * 10 | round)')" "429" \
  "6. vanilla clear rate 42.9%"
assert_eq "$(printf '%s' "$j" | jq -r '(.quality.shiploopClearRatePct * 10 | round)')" "714" \
  "6. shiploop clear rate 71.4%"
# Exact two-sided sign test, n=2 discordant, k=0: p = 2 * C(2,0) * 0.5^2 = 2 * 0.25 = 0.5.
assert_eq "$(printf '%s' "$j" | jq -r '(.quality.signTestP * 1000 | round)')" "500" \
  "6. sign test p over the discordant tickets"
assert_contains "$report" "sign test p        0.500" "6. and the report prints it"

# ── 7. activation: the excluded void-no-activation pair is named, not just counted ──
assert_contains "$report" "1 pair(s) excluded for void-no-activation: bl-x rep 2" \
  "7. the activation section names which pair was voided"

# ── 8. dose response is descriptive only: two buckets each way, medians of a single value ──
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns | length')" "2" \
  "8. one bucket per distinct shiploop worker-spawn count"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns[] | select(.bucket==2) | .medianDeltaPct | round')" \
  "-40" "8. the 2-spawn bucket is bl-x alone, -40%"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byWorkerSpawns[] | select(.bucket==3) | .medianDeltaPct | round')" \
  "20" "8. the 3-spawn bucket is bl-y alone, +20%"
assert_eq "$(printf '%s' "$j" | jq -r '.doseResponse.byTicketCount | length')" "2" \
  "8. one bucket per distinct backlog ticket count"
assert_eq "$(printf '%s' "$report" | grep -A2 'by shiploop worker-spawn count' | grep -c 'median cost delta')" "2" \
  "8. the dose tables carry no significance test, only n and a median"

# ── 9. the headline: exactly one sentence, always cost, direction-neutral ──────
assert_eq "$(printf '%s' "$j" | jq -r '.headline')" \
  "Median paired cost change: -10.0% (95% CI -40.0%..+20.0%, Wilcoxon p=1.000, n=2 backlogs, reps per backlog 1; vanilla models claude-opus-4-8, shiploop models claude-opus-4-8+claude-sonnet-5)." \
  "9. the headline sentence is in the spec's exact shape"
assert_not_contains "$report" "Up to" "9. no more up-to phrasing"
assert_not_contains "$(cat "$HUB/bench/rollup.mjs")" '"Up to "' "9. and the string is gone from the source"

# ── 10. a positive delta reads as MORE expensive, never dressed as a saving ────
# bl-y alone would headline at +20%; the pairing above (both backlogs) already covers the sign
# convention in case 9, but assert it directly on a single-pair file so the "MORE expensive"
# framing has its own regression, independent of the median blending it with bl-x.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
jq -c 'select(.backlog=="bl-y" and .rep==1)' "$P" > "$T/one-pair.jsonl"
onej="$(node "$HUB/bench/rollup.mjs" "$T/one-pair.jsonl" --json 2>&1)"
assert_eq "$(printf '%s' "$onej" | jq -r '.headline')" \
  "Median paired cost change: +20.0% (95% CI n/a (n<2), Wilcoxon p=1.000, n=1 backlogs, reps per backlog 1; vanilla models claude-opus-4-8, shiploop models claude-opus-4-8)." \
  "10. a positive median prints with a leading +, and n=1 correctly reports no CI (one point can't support one)"
assert_eq "$(printf '%s' "$onej" | jq -r '.metrics[0].ci95Pct')" "null" \
  "10. --json carries a genuine null for the CI, never a fabricated single-point interval"

# ── 11. a file with no rollup rows is an error, not an empty success ───────────
out="$(node "$HUB/bench/rollup.mjs" /dev/null 2>&1)"
assert_eq "$?" "1" "11. an empty results file exits non-zero"
assert_contains "$out" 'contains no kind:"rollup" rows' "11. and says exactly what is wrong"

assert_done
