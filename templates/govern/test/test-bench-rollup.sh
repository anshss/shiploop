#!/usr/bin/env bash
# bench: the golden rollup, single-pair edge cases (n=1: no CI, and a zero-delta metric).
#
# Locks the arithmetic against the checked-in golden results.jsonl (see bench/fixtures/README.md
# for the per-ticket token/cost derivation). One backlog, one rep, so this exercises the n=1 edge
# of the paired stats: a single pair still yields a median (itself) and a Wilcoxon p (always 1.0 at
# n=1, hand-verified in test-bench-pairing.sh's own header), but never a bootstrap CI — one point
# cannot support one. test-bench-pairing.sh covers the n>=2 machinery (real CI, exclusion, quality,
# dose response, the headline shape); this file's job is the golden numbers and the n=1 edges.
#
#   vanilla (modeled)  1 session, $8.5006, tokens 40000 in + 115000 out + 11522000 cache read
#                      + 102000 cache creation = 11779000, turns 22
#   shiploop (measured) 4 sessions, $2.3915 + $1.6715 + $1.2240 + $0.6516 = $5.9386,
#                      tokens 1840000 + 1080000 + 770000 + 1525000 = 5215000, turns 22
#
#   cost      delta (5.9386 - 8.5006) / 8.5006       = -30.139...%
#   all-in    delta (5215000 - 11779000) / 11779000  = -55.726...%
#   billable  delta (293000 - 257000) / 257000       = +14.007...%, a real POSITIVE: fresh
#             sessions re-prime, so they WRITE more cache than one long session
#   output    delta (115000 - 115000) / 115000       = 0.0% exactly — a tied pair
#   turns     delta (22 - 22) / 22                   = 0.0% exactly — also tied
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/rollup.mjs" ] && [ -f "$HUB/bench/fixtures/golden-results.jsonl" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

G="$HUB/bench/fixtures/golden-results.jsonl"
report="$(node "$HUB/bench/rollup.mjs" "$G" 2>&1)"
rc=$?
assert_eq "$rc" "0" "rollup.mjs exits 0 on the golden file"
j="$(node "$HUB/bench/rollup.mjs" "$G" --json 2>&1)"

# ── every metric in the spec's list is reported ─────────────────────────────
for m in "cost (USD)" "all-in tokens" "billable tokens" "output tokens" "cache-read tokens" \
         "fresh input (input + cache creation)" "turns"; do
  assert_contains "$report" "$m" "metric reported: $m"
done

# ── the golden arithmetic, cost cut ─────────────────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].n')" "1" "one pair (one backlog, one rep)"
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].medianDeltaPct * 10 | round)')" "-301" \
  "cost delta is -30.1%, exactly (5.9386 - 8.5006) / 8.5006"
assert_contains "$report" "median delta   -30.1%" "and the report prints it"
assert_contains "$report" "pooled totals  \$8.50 -> \$5.94, ratio 0.699x" "pooled totals line"

# ── token cuts, both readings, neither hidden ───────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[] | select(.key=="tokensAllIn") | (.medianDeltaPct * 10 | round)')" \
  "-557" "all-in tokens: -55.7%"
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[] | select(.key=="tokensBillable") | (.medianDeltaPct * 10 | round)')" \
  "140" "billable tokens go the OTHER way: +14.0%, a real positive, never dressed as a saving"
assert_contains "$report" "median delta   +14.0%" "and the report prints the + sign, not a bare number"

# ── n=1 edges: no CI (one point can't support one), Wilcoxon still computes ─
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].ci95Pct')" "null" \
  "a single pair yields no CI in --json, never a fabricated single-point interval"
assert_contains "$report" "95% CI         n/a (n<2)" "and the report says exactly why"
# n=1, one nonzero difference: the exact test's only two subset sums are {0, rank1}, and the
# observed sum is always the larger one, so p = 2 * min(1, 0.5) = 1.0 — hand-verified in
# test-bench-pairing.sh's own case 4 comment, same reasoning at n=1 instead of n=2.
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].wilcoxonP')" "1" "Wilcoxon p is exactly 1.0 at n=1"
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].wilcoxonMethod')" "exact" "n<=25 uses the exact method"

# A metric whose single pair is EXACTLY tied (output tokens, turns: vanilla and shiploop agree to
# the token/turn) drops to zero real differences, so Wilcoxon has nothing to rank and reports null
# rather than a fabricated p — never silently printed as 1.0 or 0, which both look like real answers.
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[] | select(.key=="tokensOutput") | .wilcoxonP')" "null" \
  "a tied pair (output tokens, 115000 == 115000) has no p-value at all"
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[] | select(.key=="tokensOutput") | .medianDeltaPct')" "0" \
  "but the median delta is still a real, computable zero"
assert_contains "$report" "n/a (every pair tied at zero delta)" "and the report says why there is no p"

# ── the headline sentence, in the new paired shape ──────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.headline')" \
  "Median paired cost change: -30.1% (95% CI n/a (n<2), Wilcoxon p=1.000, n=1 backlogs, reps per backlog 1; vanilla models modeled, shiploop models mixed)." \
  "headline is one sentence, cost only, in the paired shape"
assert_not_contains "$report" "Up to" "no more up-to phrasing"
assert_not_contains "$report" "Selection" "no more selection section"

# ── --json is the same numbers, machine-readable ────────────────────────────
assert_eq "$(printf '%s' "$j" | jq -r '.metrics[0].vanillaTotal')" "8.5006" "--json cost vanilla total"
# Summed IEEE doubles land at 5.938600000000001; compare in cents.
assert_eq "$(printf '%s' "$j" | jq -r '(.metrics[0].shiploopTotal * 100 | round)')" "594" \
  "--json cost shiploop total (in cents, the raw sum is not pre-rounded)"

# ── a file with no rollup rows is an error, not an empty success ────────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep '"kind":"session"' "$G" > "$T/sessions-only.jsonl"
out="$(node "$HUB/bench/rollup.mjs" "$T/sessions-only.jsonl" 2>&1)"
assert_eq "$?" "1" "a results file with no rollup rows exits non-zero"
assert_contains "$out" 'contains no kind:"rollup" rows' "and says exactly what is wrong"

assert_done
