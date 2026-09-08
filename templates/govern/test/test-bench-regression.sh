#!/usr/bin/env bash
# bench: the published numbers do not move.
#
# The multi-lever build (#108) changed what the DEFAULT arm reports. It must not change what the
# published corpus reports. Two independent locks:
#
#   1. bench/published-rows/replay-2026-09-05.jsonl, the frozen anonymized evidence behind the
#      published headline, re-aggregated by the tool itself. 70.2/57.3 (1m), 30.1/18.2 (200k),
#      85.5/77.4 (uncapped). This needs no fleet workspace and no private transcript.
#   2. bench/fixtures/replay-fleet, where the pre-#108 carry-only model's figures are pinned in
#      `coreModel` regardless of which baseline or partials mode is selected. If a refactor moves
#      those, it moved the legacy code path, which is a defect and not acceptable drift.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -f "$HUB/bench/published-rows/replay-2026-09-05.jsonl" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

ROWS="$HUB/bench/published-rows/replay-2026-09-05.jsonl"

# ── 1. the frozen corpus, through the tool ───────────────────────────────────
j="$(node "$HUB/bench/replay.mjs" --rows-file "$ROWS" --json 2>&1)"
assert_eq "$?" "0" "--rows-file aggregates the frozen published rows"
one() { printf '%s' "$j" | jq -r "(.arms[\"$1\"].$2 * 10 | round)"; }

assert_eq "$(one 1m tokenReductionPct)" "702" "1m arm reproduces the published 70.2% token reduction"
assert_eq "$(one 1m costReductionPct)" "573" "1m arm reproduces the published 57.3% cost reduction"
assert_eq "$(one 200k tokenReductionPct)" "301" "200k arm reproduces the published 30.1% token reduction"
assert_eq "$(one 200k costReductionPct)" "182" "200k arm reproduces the published 18.2% cost reduction"
assert_eq "$(one uncapped tokenReductionPct)" "855" "uncapped arm reproduces the published 85.5%"
assert_eq "$(one uncapped costReductionPct)" "774" "uncapped arm reproduces the published 77.4%"
assert_eq "$(printf '%s' "$j" | jq -r '.rows')" "1821" "over all 1,821 committed rows"
assert_eq "$(printf '%s' "$j" | jq -r '.malformedRows')" "0" "none of which is malformed"
assert_eq "$(printf '%s' "$j" | jq -r '.rowsWithoutVersion')" "1821" \
  "rows published before version stamping carry no version, and are COUNTED as unknown rather than dropped"

# The same arithmetic, independently, in jq: a reader must never have to trust the tool's own
# aggregation to check the tool's own headline. This is the recipe printed in METHODOLOGY.md.
jq_1m="$(jq -s '
  [.[] | select(.arm == "1m")] |
  ((([.[] | .vanillaTokens] | add) - ([.[] | .shipTokens] | add)) / ([.[] | .vanillaTokens] | add) * 1000 | round)
' "$ROWS")"
assert_eq "$jq_1m" "702" "the METHODOLOGY jq recipe lands on the same 70.2% the tool prints"

# ── 2. the legacy code path, on the hand-derivable fixture ───────────────────
# coreModel is the pre-#108 model: same-mix pricing, carry only, partials dropped, no harness
# overhead charged. It must be invariant to the flags, because it is a frozen reference and not a
# view of the selected arm.
core() { # baseline partials arm field
  node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fleet" --arm "$3" \
    --baseline "$1" --partials "$2" --json 2>&1 | jq -r "(.arms[\"$3\"].coreModel.$4 * 10000 | round)"
}
for bl in same-mix driver-tier; do
  for p in drop price; do
    assert_eq "$(core "$bl" "$p" 1m vanillaCostUsd)" "85006" \
      "the legacy 1m vanilla cost is invariant to --baseline/--partials ($bl/$p)"
    assert_eq "$(core "$bl" "$p" 1m vanillaTokens)" "117790000000" \
      "and so is the legacy 1m vanilla token total ($bl/$p)"
    assert_eq "$(core "$bl" "$p" 200k vanillaCostUsd)" "59506" \
      "and the 200k arm's ($bl/$p)"
  done
done
assert_eq "$(core driver-tier price 1m costReductionPct)" "301390" \
  "the legacy 1m cost reduction on the fixture stays 30.139%"
assert_eq "$(core driver-tier price 200k costReductionPct)" "2017" \
  "and the 200k arm's stays 0.2017%"

assert_done
