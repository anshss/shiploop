#!/usr/bin/env bash
# bench: the BENCH_MAX_USD rail.
#
# Contract:
#   1. the cap is checked BEFORE a cell is dispatched, so the first cell always runs
#   2. once recorded spend reaches the cap, every remaining cell records status "capped" with zero
#      sessions and a null cost, and nothing is spawned for it
#   3. a capped cell still produces a rollup row, so results.jsonl is a complete record of the run
#   4. the rollup DROPS a capped backlog instead of counting a truncated run as a saving (this is
#      the one that matters: without it, hitting the cap would make the headline look better)
#   5. a generous cap changes nothing
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/run.sh" ] && [ -f "$HUB/bench/rollup.mjs" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The vanilla fixture alone bills $24, so a $1 cap can only bite AFTER the first cell: the cap
# gates dispatch, and a session that already ran cannot be un-spent.
out="$(BENCH_OUT_ROOT="$T/r" BENCH_MAX_USD=1 bash "$HUB/bench/run.sh" --dry-run --run-id cap \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "0" "1. a run that hits the cap still exits 0"
R="$T/r/cap-dry/results.jsonl"

assert_contains "$out" "BENCH_MAX_USD=\$1 reached" "2. the skip is logged, not silent"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="vanilla") ] | length' "$R")" "1" \
  "1. the first cell dispatched before the cap could bite"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="shiploop") ] | length' "$R")" "0" \
  "2. no shiploop session was spawned past the cap"

assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .status' "$R")" "capped" \
  "2. the skipped cell records status capped"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .sessions' "$R")" "0" \
  "3. a capped rollup reports zero sessions"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .costUsdTotal' "$R")" "null" \
  "3. a capped rollup reports a null cost, never 0"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .resolved' "$R")" "false" \
  "3. a capped cell is never marked resolved"
assert_eq "$(jq -sr '[ .[] | select(.kind=="rollup") ] | length' "$R")" "2" \
  "3. both cells have a rollup row"

# 4. The rollup must not turn a truncated run into a 100% saving.
report="$(node "$HUB/bench/rollup.mjs" "$R" 2>&1)"
assert_contains "$report" "dropped fixture-backlog: run hit BENCH_MAX_USD" \
  "4. rollup drops a capped backlog and says why"
assert_contains "$report" "n/a: no backlog had both arms clear with a readable cost" \
  "4. with nothing eligible there is no cost cut to report"
assert_contains "$report" "n/a: nothing eligible to compute a headline from" \
  "4. and no headline is emitted"
assert_not_contains "$report" "Up to 100%" "4. a capped run never produces a 100% claim"

# 5. A generous cap is a no-op.
out="$(BENCH_OUT_ROOT="$T/r2" BENCH_MAX_USD=1000 bash "$HUB/bench/run.sh" --dry-run --run-id ok \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
R2="$T/r2/ok-dry/results.jsonl"
assert_eq "$(jq -sr '[ .[] | select(.kind=="rollup" and .status=="capped") ] | length' "$R2")" "0" \
  "5. no cell is capped under a generous cap"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session") ] | length' "$R2")" "8" \
  "5. every session is recorded under a generous cap"

assert_done
