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
#   9. verify runs `verify_cmd` against the arm's tree with a plain `eval`, nothing else, and
#      records one ledger line per ticket: no patch, no golden test, no apply-failure sentinel
#  10. every rollup row carries a checksum over its own numeric fields, so a hand-edited row is
#      detectable; a row's subagent activity is asserted off its OWN result event, never the exit
#      code; and the lever-events reader uses an explicit allow-list, counting a malformed line and
#      an unrecognized event name rather than silently dropping either
#  11. every rollup row also carries workerSpawns/models/hubSha; workerSpawns is a direct count of
#      Agent/Task tool_use invocations in the stream, never subagent_stats alone, and a shiploop
#      cell with zero forces status void-no-activation (capped still wins)
#  12. the smoke gate: a dry run never needs one regardless of size; a live run bigger than one
#      (backlog x rep) cell refuses to start with no BENCH_SMOKE_RUN; BENCH_SKIP_SMOKE_GATE=1 is
#      logged into the run's own kind:"meta" row; a BENCH_SMOKE_RUN at the current hub sha with
#      every cell resolved/failed and the shiploop cell activated lets the run past the gate
#  13. a session whose final result event is an infra-class error (is_error:true, not one of the
#      error_max_* ceiling subtypes) records status "error", never "failed" or "void-no-activation";
#      capped still wins over it; and a live dispatch loop stops starting NEW cells after the first
#      one, recording every later cell "error" too, with zero sessions and a null cost
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

assert_eq "$(jq -sr '[ .[] | select(.kind=="session") ] | length' "$R")" "2" \
  "3. dry run recorded 2 sessions (1 vanilla + 1 shiploop — each arm is one whole-backlog session)"

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
assert_eq "$(printf '%s' "$row" | jq -r '.tokens.output')" "6" \
  "7. the recovered OUTPUT is the truncated snapshot sum — a known undercount, disclosed, not silently trusted as a real total"

# The fixture backlog is for the suite only. A real run must refuse it rather than failing halfway
# through a clone, and it must never be counted toward a published backlog total.
out="$(BENCH_OUT_ROOT="$T/live" bash "$HUB/bench/run.sh" --run-id live \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "1" "8. a non-dry run on the fixture backlog exits non-zero"
assert_contains "$out" "is a TEST FIXTURE" "8. and says why, before spending anything"

# ── 9. verify_cmd runs against the arm's tree with a plain eval, nothing else ───
# The dry run's checkout is a bare repo with just a README, and the fixture's verify_cmd names a
# test file nothing in this path ever creates any more, so every ticket fails deterministically.
# The exact nonzero code a missing-script `sh` invocation returns is a shell-implementation detail
# (bash-as-/bin/sh vs dash give different numbers), so this asserts the portable invariant only:
# verify_cmd genuinely ran against the tree and failed, not a specific errno. That is the honest
# behavior with no golden patch in the picture: the ledger shape is what this locks down, not a
# clear result.
L="$T/results/schema-dry/verify/fixture-backlog-vanilla-1.jsonl"
assert_eq "$(jq -sr 'length' "$L")" "6" "9. one verify ledger line per ticket"
assert_eq "$(jq -sr '[ .[] | keys_unsorted ] | unique | length' "$L")" "1" \
  "9. every ledger line has the same key set"
assert_eq "$(jq -sr '.[0] | keys_unsorted | sort | join(",")' "$L")" "cleared,ticket,verifyExit" \
  "9. the ledger carries ticket/verifyExit/cleared only, no patchApplied"
assert_eq "$(jq -sr '[ .[] | select(.verifyExit != 0) ] | length' "$L")" "6" \
  "9. verify_cmd ran directly against the arm's tree and failed for every ticket"
# The ledger must NOT sit beside the session streams: record_sessions globs *.jsonl there, so a
# ledger written into that dir would be folded in as an extra zero-cost session.
assert_eq "$(ls "$T/results/schema-dry/sessions/fixture-backlog-vanilla-1"/*.jsonl | wc -l | tr -d ' ')" "1" \
  "9. the ledger is not counted as a session stream"
# The verify path never shells out to `git apply` any more: there is no golden patch left to apply.
assert_eq "$(grep -c -e 'git apply' "$HUB/bench/run.sh")" "0" \
  "9. the verify path applies no patch at all"

# ── 10. rollup checksum, subagent activity, and the lever-events reader ─────
assert_eq "$(jq -sr '[ .[] | select(.kind=="rollup") | select(has("checksum")|not) ] | length' "$R")" "0" \
  "10. every rollup row carries a checksum"
recheck="$(jq -sr '[ .[] | select(.kind=="rollup") ][0]' "$R")"
recomputed="$(RECHECK="$recheck" BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::row_checksum "$RECHECK"
' 2>/dev/null)"
assert_eq "$(printf '%s' "$recheck" | jq -r '.checksum')" "$recomputed" \
  "10. the checksum is exactly bench::row_checksum's own function applied to the row"

got="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  set +e
  bench::stream_had_subagent_activity "'"$HUB"'/bench/fixtures/shiploop-session.jsonl"
  echo "rc=$?"
' 2>&1)"
assert_contains "$got" "rc=0" "10. the shiploop fixture's own result event shows completed subagent activity"

mkdir -p "$T/levers"
{
  printf '{"event":"output-suppression","ts":1,"ticket":1,"session":"worker","tier":null,"withheldBytes":10,"withheldLines":1,"outcome":"pass"}\n'
  printf '{"event":"watchdog-kill","ts":2,"ticket":1,"session":"worker","tier":"sonnet","ctxTokens":1,"turns":1,"reason":"x"}\n'
  printf 'not json at all\n'
  printf '{"event":"some-future-event","ts":3,"ticket":1,"session":"worker","tier":null}\n'
} > "$T/levers/lever-events.jsonl"
lv="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::read_lever_events "'"$T"'/levers/lever-events.jsonl"
' 2>/dev/null)"
assert_eq "$(printf '%s' "$lv" | jq -r '.instrumented')" "true" "10. a present lever-events.jsonl is instrumented"
assert_eq "$(printf '%s' "$lv" | jq -r '.events."output-suppression"')" "1" \
  "10. the allow-listed output-suppression event is counted by name"
assert_eq "$(printf '%s' "$lv" | jq -r '.events."watchdog-kill"')" "1" \
  "10. and so is watchdog-kill"
assert_eq "$(printf '%s' "$lv" | jq -r '.malformed')" "1" \
  "10. the non-JSON line is counted as malformed, never silently dropped"
assert_eq "$(printf '%s' "$lv" | jq -r '.unrecognized')" "1" \
  "10. an event name outside the three-name allow-list is counted as unrecognized, never silently dropped"
absent="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::read_lever_events "'"$T"'/levers/does-not-exist.jsonl"
' 2>/dev/null)"
assert_eq "$(printf '%s' "$absent" | jq -r '.instrumented')" "false" \
  "10. a run with no lever-events.jsonl is uninstrumented, never zero-saving"

# ── 11. workerSpawns / models / hubSha, and the activation gate ─────────────
assert_eq "$(jq -sr '[ .[] | select(.kind=="rollup") | select(has("workerSpawns") and has("models") and has("hubSha") | not) ] | length' "$R")" \
  "0" "11. every rollup row carries workerSpawns/models/hubSha"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .workerSpawns' "$R")" "2" \
  "11. the shiploop dry-run cell's workerSpawns is the fixture's own two Task tool_use invocations"
spawns="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::stream_worker_spawn_count "'"$HUB"'/bench/fixtures/shiploop-session.jsonl"
  bench::stream_worker_spawn_count "'"$HUB"'/bench/fixtures/vanilla-session.jsonl"
' 2>/dev/null)"
assert_eq "$(printf '%s' "$spawns" | sed -n 1p)" "2" \
  "11. the shiploop fixture shows exactly two Agent/Task tool_use invocations"
assert_eq "$(printf '%s' "$spawns" | sed -n 2p)" "0" \
  "11. the vanilla fixture, which never delegates, shows zero"
act="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::activation_status resolved shiploop 0
  bench::activation_status resolved shiploop 2
  bench::activation_status capped shiploop 0
  bench::activation_status resolved vanilla 0
' 2>/dev/null)"
assert_eq "$(printf '%s' "$act" | sed -n 1p)" "void-no-activation" \
  "11. a shiploop cell with zero spawns is forced to void-no-activation"
assert_eq "$(printf '%s' "$act" | sed -n 2p)" "resolved" \
  "11. a shiploop cell WITH spawns keeps its real status"
assert_eq "$(printf '%s' "$act" | sed -n 3p)" "capped" \
  "11. capped wins over the activation check — a session cut off before it could delegate is a rail artifact"
assert_eq "$(printf '%s' "$act" | sed -n 4p)" "resolved" \
  "11. the activation gate only ever applies to the shiploop arm"

# ── 12. the smoke gate ───────────────────────────────────────────────────────
# The dry run above already used --backlog fixture-backlog (1 backlog, REPS default 1): reuse it as
# a valid BENCH_SMOKE_RUN candidate, since its shiploop cell activated (11, above) and both cells
# completed (status "failed" — the bare dry-run checkout clears nothing, which is still a completed
# comparison, never capped). A dry run itself never needs a gate no matter its own size.
out="$(BENCH_OUT_ROOT="$T/results2" bash "$HUB/bench/run.sh" --dry-run --run-id schema-multi \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog --reps 2 2>&1)"
assert_eq "$?" "0" "12. a dry run bigger than one cell needs no smoke gate at all"
assert_not_contains "$out" "smoke gate" "12. and never even mentions one"

out="$(BENCH_OUT_ROOT="$T/results3" bash "$HUB/bench/run.sh" --run-id schema-live \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog --reps 2 2>&1)"
assert_eq "$?" "1" "12. a live run bigger than one cell, with no BENCH_SMOKE_RUN, refuses to start"
assert_contains "$out" "smoke gate:" "12. and says so"
assert_not_contains "$out" "TEST FIXTURE" \
  "12. it dies at the gate, before ever reaching the per-backlog fixture check"

out="$(BENCH_OUT_ROOT="$T/results4" BENCH_SKIP_SMOKE_GATE=1 bash "$HUB/bench/run.sh" --run-id schema-skip \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog --reps 2 2>&1)"
assert_contains "$out" "BENCH_SKIP_SMOKE_GATE=1" "12. the override is logged when used"
assert_contains "$out" "TEST FIXTURE" \
  "12. and the run gets PAST the gate — it now dies at the ordinary fixture-backlog check instead"
assert_eq "$(jq -sr '[ .[] | select(.kind=="meta") | .smokeGateSkipped ] | first' "$T/results4/schema-skip/results.jsonl")" \
  "true" "12. the skip is recorded in the run's own kind:\"meta\" row, not just logged"

# BENCH_SMOKE_RUN names a run-id under the SAME --out root as this run, so reuse "$T/results"
# (where the very first dry run above, run-id "schema", already recorded a completed, activated
# cell) rather than a fresh root.
out="$(BENCH_OUT_ROOT="$T/results" BENCH_SMOKE_RUN=schema-dry bash "$HUB/bench/run.sh" --run-id schema-gated \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog --reps 2 2>&1)"
assert_contains "$out" "smoke gate: satisfied by BENCH_SMOKE_RUN=schema-dry" \
  "12. a genuine BENCH_SMOKE_RUN at the current hub sha, fully completed and activated, passes the gate"
assert_contains "$out" "TEST FIXTURE" \
  "12. and the run proceeds to the ordinary fixture-backlog check, exactly like the skip case"

# ── 13. infra-class error: status, precedence, and the dispatch halt ───────────
errchk="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  set +e
  bench::stream_hit_error "'"$HUB"'/bench/fixtures/error-session.jsonl"; echo "err=$?"
  bench::stream_hit_error "'"$HUB"'/bench/fixtures/vanilla-session.jsonl"; echo "clean=$?"
' 2>&1)"
assert_contains "$errchk" "err=0" "13. the error fixture's result event is detected as an infra-class error"
assert_contains "$errchk" "clean=1" "13. an ordinary successful result is never mistaken for one"

act13="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  bench::activation_status error shiploop 0
  bench::activation_status capped shiploop 0
' 2>/dev/null)"
assert_eq "$(printf '%s' "$act13" | sed -n 1p)" "error" \
  "13. an error status is never overridden to void-no-activation, same as capped"
assert_eq "$(printf '%s' "$act13" | sed -n 2p)" "capped" \
  "13. capped still wins when both would otherwise apply"

# End-to-end: BENCH_DRY_ERROR_REP is a test-only seam (bench/run.sh, bench::dry_arm) that swaps the
# named arm's rep onto fixtures/error-session.jsonl, so the REAL dispatch loop derives status "error"
# and the halt from a live stream the same way it would for a genuine outage — no live spend.
out="$(BENCH_OUT_ROOT="$T/results13" BENCH_DRY_ERROR_REP=1 bash "$HUB/bench/run.sh" --dry-run \
        --run-id err13 --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog \
        --arm shiploop --reps 2 2>&1)"
assert_eq "$?" "0" "13. a run carrying an infra-class error still exits 0"
assert_contains "$out" "forcing status=error and halting further dispatch this run" \
  "13. the halt is logged when the first error-class cell is dispatched"
assert_contains "$out" "SKIPPED, an earlier cell hit an infra-class error this run" \
  "13. and the next cell is logged as skipped because of it"
R13="$T/results13/err13-dry/results.jsonl"
assert_eq "$(jq -sr '[.[] | select(.kind=="rollup")] | map(.status) | sort | join(",")' "$R13")" \
  "error,error" "13. both reps record status error: the one that ran, and the one skipped after it"
assert_eq "$(jq -sr '[.[] | select(.kind=="rollup" and .rep==2)][0] | .sessions' "$R13")" "0" \
  "13. the skipped (halted) rep never spawned a session"
assert_eq "$(jq -sr '[.[] | select(.kind=="rollup" and .rep==2)][0] | .costUsdTotal' "$R13")" "null" \
  "13. and reports a null cost, never a fabricated zero"

# The rollup excludes an error-status pair the same way it excludes a capped one — proven directly
# against fixtures/pairing-results.jsonl (bl-z rep 1), not re-derived here.

assert_done
