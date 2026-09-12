#!/usr/bin/env bash
# bench: the model is deterministic and its published evidence round-trips.
#
# There is no published corpus and no committed rows file (bench/published-rows/SCHEMA.md), so this
# asserts nothing about real performance. It asserts two things about the MECHANISM, both over
# synthetic fixture data:
#
#   1. Rows the tool emits aggregate back to the totals the run that emitted them reported, by the
#      tool and independently by the jq recipe in METHODOLOGY.md. That is the recomputability claim
#      any future publication will be held to, tested without needing a corpus to hold it against.
#   2. `coreModel`, the legacy carry-only same-mix model, is frozen on bench/fixtures/replay-fleet
#      and invariant to --baseline and --partials. If a refactor moves it, it moved the legacy code
#      path, which is a defect rather than acceptable drift.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

# ── 1. the rows round trip, on rows this test generates itself ──────────────
# There is no committed rows file to check against (bench/published-rows/SCHEMA.md: nothing is
# published until the harness is instrumented). What still has to hold is that a rows file the tool
# EMITS aggregates back to the arm totals it was emitted from. That is the whole recomputability
# claim, and it needs no real corpus to test: emit from the synthetic fixture, aggregate, compare.
FLEET="$HUB/bench/fixtures/replay-fleet"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm all --baseline same-mix --partials drop \
  --rows > "$T/rows.jsonl" 2>"$T/rows.err"
assert_eq "$?" "0" "--rows emits a rows file from the fixture fleet"
assert_eq "$(wc -l < "$T/rows.jsonl" | tr -d ' ')" "12" "one row per (arm, ticket position): 3 arms x 4 tickets"

j_rows="$(node "$HUB/bench/replay.mjs" --rows-file "$T/rows.jsonl" --json 2>&1)"
assert_eq "$?" "0" "--rows-file aggregates a rows file with no workspace in sight"
assert_eq "$(printf '%s' "$j_rows" | jq -r '.kind')" "replay-rows" "and names itself as a rows aggregation"
assert_eq "$(printf '%s' "$j_rows" | jq -r '.arms | keys | join(",")')" "1m,200k,uncapped" "over every arm in the file"
assert_eq "$(printf '%s' "$j_rows" | jq -r '.malformedRows')" "0" "with nothing unparseable"

# The round trip: aggregating the emitted rows must land on the same percentage the run that
# emitted them reported. A drift here means the published evidence would not reproduce the
# published number, which is the exact failure this guard exists to make impossible.
j_run="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm all --baseline same-mix --partials drop --json 2>&1)"
for arm in 200k 1m uncapped; do
  from_rows="$(printf '%s' "$j_rows" | jq -r --arg a "$arm" '(.arms[$a].tokenReductionPct * 10000 | round)')"
  from_run="$(printf '%s' "$j_run" | jq -r --arg a "$arm" '(.arms[$a].coreModel.tokenReductionPct * 10000 | round)')"
  assert_eq "$from_rows" "$from_run" "rows for $arm re-aggregate to the token reduction the run reported"
  c_rows="$(printf '%s' "$j_rows" | jq -r --arg a "$arm" '(.arms[$a].costReductionPct * 10000 | round)')"
  c_run="$(printf '%s' "$j_run" | jq -r --arg a "$arm" '(.arms[$a].coreModel.costReductionPct * 10000 | round)')"
  assert_eq "$c_rows" "$c_run" "and to the cost reduction for $arm"
done

# The same arithmetic in jq, so the tool's own aggregation is never the only witness to it. This is
# the recipe printed in METHODOLOGY.md, run against the rows just emitted.
jq_1m="$(jq -s '
  [.[] | select(.arm == "1m")] |
  ((([.[] | .vanillaTokens] | add) - ([.[] | .shipTokens] | add)) / ([.[] | .vanillaTokens] | add) * 100 * 10000 | round)
' "$T/rows.jsonl")"
assert_eq "$jq_1m" "$(printf '%s' "$j_rows" | jq -r '(.arms["1m"].tokenReductionPct * 10000 | round)')" \
  "the METHODOLOGY jq recipe lands on exactly what the tool prints"

# A row with no version stamp reads unknown and is COUNTED, never dropped. The fixture is unstamped,
# which is the same shape as any row published before version stamping existed.
assert_eq "$(printf '%s' "$j_rows" | jq -r '.rowsWithoutVersion')" "12" \
  "unstamped rows are counted as unknown rather than silently dropped"
assert_eq "$(printf '%s' "$j_rows" | jq -r '.versions | length')" "0" "and no version is invented for them"

# An empty or absent rows file must fail loudly rather than report a percentage over nothing.
: > "$T/empty.jsonl"
node "$HUB/bench/replay.mjs" --rows-file "$T/empty.jsonl" --json >/dev/null 2>&1
assert_eq "$?" "1" "an empty rows file exits non-zero rather than reporting a saving over no rows"
node "$HUB/bench/replay.mjs" --rows-file "$T/no-such-file.jsonl" >/dev/null 2>&1
assert_eq "$?" "2" "a missing rows file is a usage error, not a silent zero"

# ── 2. the legacy code path, on the hand-derivable fixture ───────────────────
# coreModel is the legacy model: same-mix pricing, carry only, partials dropped, no harness
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
