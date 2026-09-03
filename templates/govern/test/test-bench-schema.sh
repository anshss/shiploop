#!/usr/bin/env bash
# bench: results.jsonl schema conformance.
#
# Contract:
#   1. `bench/run.sh --dry-run` exits 0, zero spawns, and writes a results.jsonl
#   2. every line is valid JSON
#   3. every kind:"session" row carries the full ticket-history field set (spec section 5), so
#      govern-health.sh --bench can fold results.jsonl and ticket-history.jsonl with one program
#   4. every kind:"rollup" row adds sessions, ticketsCleared, costUsdTotal, tokensTotal
#   5. tokens is the 5-key breakdown govern::stream_usage produces, and total is the sum of the
#      four parts (a rollup that loses a component is how a cost claim quietly drifts)
#   6. a rollup's costUsdTotal equals the sum of its cell's session costs
#   7. a session hard-killed before emitting a result recovers TOKENS but never a fabricated cost
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/run.sh" ] && [ -f "$HUB/scaffold.sh" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

out="$(BENCH_OUT_ROOT="$T/results" bash "$HUB/bench/run.sh" --dry-run --run-id schema \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
rc=$?
assert_eq "$rc" "0" "1. run.sh --dry-run exits 0"
R="$T/results/schema-dry/results.jsonl"
[ -s "$R" ] && printf 'ok   - 1. results.jsonl written\n' || \
  { printf 'FAIL - 1. no results.jsonl\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# A dry run must never touch the network or a real CLI. The fixtures are the only source of
# result events, so a stream that is not byte-identical to one means something really spawned.
assert_eq "$(cmp -s "$T/results/schema-dry/sessions/fixture-backlog-vanilla-1/01-fixture-backlog.jsonl" \
  "$HUB/bench/fixtures/vanilla-session.jsonl" && echo same || echo differs)" "same" \
  "1. dry-run vanilla stream is the checked-in fixture, not a spawn"

bad="$(jq -e . "$R" >/dev/null 2>&1 && echo "" || echo "invalid")"
assert_eq "$bad" "" "2. every line is valid JSON"

# ── 3. session rows carry every ticket-history field ────────────────────────
missing="$(for k in run backlog task arm rep model cli_version status resolved turns \
                tokens costUsd usageSource wallMs verifyExit startedAt; do
    n="$(jq -r --arg k "$k" 'select(.kind=="session") | select(has($k)|not) | .task' "$R" | head -1)"
    [ -n "$n" ] && echo "$k"
  done)"
assert_eq "$missing" "" "3. no session row is missing a ticket-history field"

assert_eq "$(jq -sr '[ .[] | select(.kind=="session") ] | length' "$R")" "8" \
  "3. dry run recorded 8 sessions (1 vanilla + 1 shiploop driver + 6 shiploop workers)"

# ── 4. rollup rows add the four fold fields ─────────────────────────────────
missing="$(for k in sessions ticketsCleared costUsdTotal tokensTotal; do
    n="$(jq -r --arg k "$k" 'select(.kind=="rollup") | select(has($k)|not) | .backlog' "$R" | head -1)"
    [ -n "$n" ] && echo "$k"
  done)"
assert_eq "$missing" "" "4. every rollup row has sessions/ticketsCleared/costUsdTotal/tokensTotal"
assert_eq "$(jq -sr '[ .[] | select(.kind=="rollup") ] | length' "$R")" "2" \
  "4. one rollup row per (backlog, arm, rep)"

# ── 5. tokens breakdown is internally consistent ────────────────────────────
assert_eq "$(jq -sr '[ .[] | select(.tokens != null)
  | select(.tokens.total != (.tokens.input + .tokens.output + .tokens.cacheRead + .tokens.cacheCreation)) ]
  | length' "$R")" "0" "5. tokens.total equals the sum of its four components on every row"

# ── 6. the fold is the sum of what it folded ────────────────────────────────
assert_eq "$(jq -sr '
  ([ .[] | select(.kind=="session" and .arm=="shiploop") | .costUsd ] | add | . * 100 | round) as $s
  | ([ .[] | select(.kind=="rollup" and .arm=="shiploop") | .costUsdTotal ] | add | . * 100 | round) as $r
  | if $s == $r then "equal" else "\($s) vs \($r)" end' "$R")" "equal" \
  "6. shiploop rollup costUsdTotal equals the sum of its session costs"

# ── 7. a killed session recovers tokens but not a cost ──────────────────────
# govern::stream_usage is the authoritative parser and this is its contract: tokens come back from
# the per-turn assistant events, costUsd stays null because the stream carries no price and
# inventing one would fabricate data. record.sh must not paper over that with a zero.
mkdir -p "$T/partial"
cp "$HUB/bench/fixtures/partial-no-result.jsonl" "$T/partial/01-killed.jsonl"
row="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::session_row "'"$T"'/partial/01-killed.jsonl" run bl t1 vanilla 1 m cli failed false 0 1 0
' 2>/dev/null)"
assert_eq "$(printf '%s' "$row" | jq -r '.costUsd')" "null" \
  "7. a stream with no result event records costUsd null, never 0"
assert_eq "$(printf '%s' "$row" | jq -r '.usageSource')" "assistant-partial" \
  "7. its tokens are recovered from the per-turn assistant events"
assert_eq "$(printf '%s' "$row" | jq -r '.tokens.total')" "53200" \
  "7. recovered token total is the sum of every assistant event"

# The fixture backlog is for the suite only. A real run must refuse it rather than failing halfway
# through a clone, and it must never be counted toward a published backlog total.
out="$(BENCH_OUT_ROOT="$T/live" bash "$HUB/bench/run.sh" --run-id live \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "1" "8. a non-dry run on the fixture backlog exits non-zero"
assert_contains "$out" "is a TEST FIXTURE" "8. and says why, before spending anything"

assert_done
