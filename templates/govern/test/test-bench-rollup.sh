#!/usr/bin/env bash
# bench: the golden rollup.
#
# Locks the arithmetic of all three metric cuts (spec section 4) and the exact shape of the one
# published sentence against a checked-in golden results.jsonl. The golden numbers are chosen to
# be hand-checkable:
#
#   vanilla   1 session, $24.00, tokens 120000 in + 40000 out + 8000000 cache read
#             + 600000 cache creation = 8760000
#   shiploop  7 sessions, $0.40 driver + 6 x $0.55 worker = $3.70,
#             tokens 55900 + 6 x 302500 = 1870900
#
#   cut 1 cost      (24.00 - 3.70) / 24.00      = 84.583...%
#   cut 2 billable  (760000 - 330900) / 760000  = 56.46...%
#         all-in    (8760000 - 1870900) / 8760000 = 78.64...%
#   cut 3 per ticket $4.00 vs $0.6166..., ratio 6.486...x
#   headline        floor(84.58) = 84, on the LARGEST cut, which here is cost
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

# ── the three cuts are all present and named ────────────────────────────────
assert_contains "$report" "Cut 1: cost to clear the same backlog" "cut 1 is reported"
assert_contains "$report" "Cut 2: tokens to clear the same backlog" "cut 2 is reported"
assert_contains "$report" "Cut 3: tickets shipped per 5-hour window" "cut 3 is reported"

# ── cut 1 ───────────────────────────────────────────────────────────────────
assert_contains "$report" "vanilla   \$24.00" "cut 1: vanilla cost"
assert_contains "$report" "shiploop  \$3.70" "cut 1: shiploop cost, driver included"
assert_contains "$report" "lower by  84.6%" "cut 1: cost delta"

# ── cut 2, both readings, neither hidden ────────────────────────────────────
assert_contains "$report" "56.5% fewer" "cut 2: billable tokens (cache reads charged at nothing)"
assert_contains "$report" "78.6% fewer" "cut 2: all-in tokens"

# ── cut 3, and the reason the ratio is the honest form ──────────────────────
assert_contains "$report" "vanilla   \$4.00 per ticket" "cut 3: vanilla cost per ticket"
assert_contains "$report" "shiploop  \$0.62 per ticket" "cut 3: shiploop cost per ticket"
assert_contains "$report" "6.49x more tickets per window" "cut 3: the window-independent ratio"
assert_contains "$report" "absolute per-window counts: n/a, pass --window-usd" \
  "cut 3: absolute counts need a MEASURED window budget and are never guessed"

# With a measured budget the absolute counts appear. $100 / $4.00 = 25, $100 / $0.6166 = 162.2.
withwin="$(node "$HUB/bench/rollup.mjs" "$G" --window-usd 100 2>&1)"
assert_contains "$withwin" "vanilla 25.0 tickets, shiploop 162.2 tickets" \
  "cut 3: a supplied window budget yields absolute counts"

# ── the headline sentence, in the exact published shape ─────────────────────
assert_contains "$report" "metric: lower cost" \
  "headline names which cut produced its number, so a token cut is never shipped as a cost claim"
assert_contains "$report" \
  "Up to 84% lower cost to ship the same backlog vs a stock Claude Code session (1 real upstream backlogs, 6 tickets, model dry-run, CLI dry-run)." \
  "headline is one sentence in the spec's exact shape"

# The percentage is floored, never rounded up: 84.58 must publish as 84.
assert_not_contains "$report" "Up to 85%" "headline floors the percentage rather than rounding up"

# ── --json is the same numbers, machine-readable ────────────────────────────
j="$(node "$HUB/bench/rollup.mjs" "$G" --json 2>&1)"
assert_eq "$(printf '%s' "$j" | jq -r '.headline.pct')" "84" "--json carries the same headline pct"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.vanillaCostUsd')" "24" "--json cut 1 vanilla"
# Summed IEEE doubles: 0.40 + 6 x 0.55 lands at 3.6999999999999993. The report formats to two
# decimals; --json deliberately hands back the raw sum rather than a pre-rounded one, so compare
# in cents.
assert_eq "$(printf '%s' "$j" | jq -r '(.aggregateKept.shiploopCostUsd * 100 | round)')" "370" \
  "--json cut 1 shiploop (in cents, the raw sum is not pre-rounded)"
assert_eq "$(printf '%s' "$j" | jq -r '.aggregateKept.tickets')" "6" "--json ticket count"

# ── a file with no rollup rows is an error, not an empty success ────────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
grep '"kind":"session"' "$G" > "$T/sessions-only.jsonl"
out="$(node "$HUB/bench/rollup.mjs" "$T/sessions-only.jsonl" 2>&1)"
assert_eq "$?" "1" "a results file with no rollup rows exits non-zero"
assert_contains "$out" 'contains no kind:"rollup" rows' "and says exactly what is wrong"

assert_done
