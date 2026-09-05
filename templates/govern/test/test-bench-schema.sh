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
#   8. the fixture backlog is refused by a non-dry run
#   9. verify applies the golden test_patch to the ARM'S tree and only then runs verify_cmd, and
#      records one ledger line per ticket
#  10. a test_patch that will not apply records the distinct sentinel and leaves the ticket
#      unresolved: no 3-way merge, no fuzz, no silent repair of the oracle
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
assert_eq "$(printf '%s' "$row" | jq -r '.tokens.total')" "397674" \
  "7. recovered token total is the sum of every assistant event"
# The INPUT side of that recovery is exact: summing the per-turn context reproduces a result
# event's own totals to the token. The OUTPUT side is not, because the per-message output_tokens
# is a truncated snapshot that undercounts real output by a median factor of 33 in the corpus.
# govern::stream_usage is a shared harness primitive, so this row's output is left as it is and
# the defect is recorded in bench/METHODOLOGY.md rather than patched from a bench change.
# bench/replay.mjs never uses this path: it recovers the input side only and sets output to 0.
assert_eq "$(printf '%s' "$row" | jq -r '.tokens.output')" "6" \
  "7. the recovered OUTPUT is the truncated snapshot sum, which is why replay.mjs never uses it"

# The fixture backlog is for the suite only. A real run must refuse it rather than failing halfway
# through a clone, and it must never be counted toward a published backlog total.
out="$(BENCH_OUT_ROOT="$T/live" bash "$HUB/bench/run.sh" --run-id live \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "1" "8. a non-dry run on the fixture backlog exits non-zero"
assert_contains "$out" "is a TEST FIXTURE" "8. and says why, before spending anything"

# ── 9. the golden test_patch is applied at verify time, on the arm's tree ───
# The dry run's checkout is a bare repo with a README. The fixture backlog's patches ADD their test
# files, so a clean apply is what makes verify_cmd runnable at all: if the patch step were skipped
# or ordered before the arm, nothing would clear.
L="$T/results/schema-dry/verify/fixture-backlog-vanilla-1.jsonl"
assert_eq "$(jq -sr 'length' "$L")" "6" "9. one verify ledger line per ticket"
assert_eq "$(jq -sr '[ .[] | select(.patchApplied) ] | length' "$L")" "6" \
  "9. every golden test_patch applied to the arm's tree"
assert_eq "$(jq -sr '[ .[] | select(.cleared) ] | length' "$L")" "6" \
  "9. and verify_cmd then passed for every ticket"
# The ledger must NOT sit beside the session streams: record_sessions globs *.jsonl there, so a
# ledger written into that dir would be folded in as an extra zero-cost session.
assert_eq "$(ls "$T/results/schema-dry/sessions/fixture-backlog-vanilla-1"/*.jsonl | wc -l | tr -d ' ')" "1" \
  "9. the ledger is not counted as a session stream"

# ── 10. an unappliable patch records the sentinel, never a repair ───────────
mkdir -p "$T/badpatch"
jq -c '.test_patch = "diff --git a/nope.txt b/nope.txt\n--- a/nope.txt\n+++ b/nope.txt\n@@ -1 +1 @@\n-was\n+now\n"' \
  "$HUB/bench/backlogs/fixture-backlog/backlog.jsonl" > "$T/badpatch/backlog.jsonl"
mkdir -p "$T/badwd" && ( cd "$T/badwd" && git init -q -b main && echo x > README.md \
  && git -c user.email=a@b -c user.name=a add -A \
  && git -c user.email=a@b -c user.name=a commit -qm init ) >/dev/null 2>&1
read -r bc bt bw < <(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  BENCH_VERIFY_PATCH_FAILED=90
  '"$(sed -n '/^bench::verify_backlog()/,/^}/p' "$HUB/bench/run.sh")"'
  bench::verify_backlog "'"$T"'/badpatch/backlog.jsonl" "'"$T"'/badwd" "'"$T"'/bad.jsonl"
' 2>/dev/null)
assert_eq "$bc" "0" "10. no ticket clears when the golden patch cannot apply"
assert_eq "$bw" "90" "10. the worst exit is the distinct patch-failure sentinel, not a test failure"
assert_eq "$(jq -sr '[ .[] | select(.patchApplied == false) ] | length' "$T/bad.jsonl")" "6" \
  "10. every ledger line records that the patch did not apply"
assert_eq "$(jq -sr '[ .[] | select(.verifyExit == 90) ] | length' "$T/bad.jsonl")" "6" \
  "10. and carries the sentinel rather than a plain non-zero"
# The oracle is never repaired to make a run look better. Inspect the INVOCATION lines only: the
# comments above them say the words "3-way" and "reject" on purpose, and a naive file-wide grep
# would match its own documentation and never fail on real code.
applies="$(grep -e 'git apply' "$HUB/bench/run.sh" | grep -v -e '^ *#')"
assert_contains "$applies" "git apply -" "10. the verify path does apply the golden patch"
assert_eq "$(printf '%s' "$applies" | grep -c -e '3way' -e 'apply -3' -e 'reject' -e 'unidiff-zero')" "0" \
  "10. and never 3-way merges, fuzzes, or partially applies it"

assert_done
