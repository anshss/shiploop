#!/usr/bin/env bash
# status.sh's "by source" summary: per-session tier attribution grouped by model_source.
#
# Why it exists: model_source was already logged (spawn-worker.sh's attempts.jsonl ledger) but
# nothing aggregated it anywhere a person would look. Diagnosing a real overcharge took a dedicated
# agent 38 tool calls to answer what this summary answers in one read. worker_spawned/worker_done
# now carry modelSource/precision/costUsd (spawn-worker.sh); this locks in that status.sh's fold
# turns those into a grouped summary.
#
# Contract:
#   1. Grouped by modelSource, not raw model: two sources that happen to pick the same tier stay
#      distinct rows.
#   2. Counts EVERY ticket ever dispatched in scope (done or still live), not just live ones.
#   3. Cost sums only PRICED rows; an unpriced (killed-before-result-event) row still counts toward
#      the dispatch total but is called out separately, never silently folded into a fake $0.
#   4. Scoped to the newest run by default; --all-runs widens it, same as every other section.
#   5. An old event log with no modelSource field at all reads as "(unrecorded)", not a crash.
#   6. --json emits a `bySource` array with the same data.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
EV="$T/governor/events.jsonl"
STATUS="$DIR/../status.sh"

run_status() { GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" bash "$STATUS" "$@" </dev/null 2>&1; }

ev() { printf '%s\n' "$1" >> "$EV"; }
TS="$(date +%s)"

# run-old: a resolved GOVERN_WORKER_MODEL dispatch. Must NOT count by default (scoped to run-new).
ev "{\"ts\":$((TS-600)),\"run_id\":\"run-old\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\"}"
ev "{\"ts\":$((TS-590)),\"run_id\":\"run-old\",\"type\":\"worker_spawned\",\"ticket\":21,\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"pid\":0}"
ev "{\"ts\":$((TS-580)),\"run_id\":\"run-old\",\"type\":\"worker_done\",\"ticket\":21,\"status\":\"resolved\",\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"costUsd\":\"9.99\"}"

# run-new: two GOVERN_WORKER_MODEL dispatches (one resolved+priced, one timed-out+unpriced) and one
# execute-only (haiku) dispatch, plus one still-LIVE dispatch (no done event yet).
ev "{\"ts\":$((TS-300)),\"run_id\":\"run-new\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\"}"
ev "{\"ts\":$((TS-290)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"ticket\":11,\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"pid\":0}"
ev "{\"ts\":$((TS-280)),\"run_id\":\"run-new\",\"type\":\"worker_done\",\"ticket\":11,\"status\":\"resolved\",\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"costUsd\":\"2.94\"}"
ev "{\"ts\":$((TS-270)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"ticket\":12,\"model\":\"haiku\",\"modelSource\":\"execute-only (parent stated the change)\",\"precision\":\"stated\",\"pid\":0}"
ev "{\"ts\":$((TS-260)),\"run_id\":\"run-new\",\"type\":\"worker_done\",\"ticket\":12,\"status\":\"resolved\",\"model\":\"haiku\",\"modelSource\":\"execute-only (parent stated the change)\",\"precision\":\"stated\",\"costUsd\":\"0.12\"}"
ev "{\"ts\":$((TS-250)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"ticket\":13,\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"pid\":0}"
ev "{\"ts\":$((TS-240)),\"run_id\":\"run-new\",\"type\":\"worker_done\",\"ticket\":13,\"status\":\"timeout\",\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\"}"
sleep 60 & LIVE_PID=$!
ev "{\"ts\":$((TS-100)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"ticket\":14,\"model\":\"sonnet\",\"modelSource\":\"GOVERN_WORKER_MODEL\",\"precision\":\"scoped\",\"pid\":$LIVE_PID}"

# ── text ────────────────────────────────────────────────────────────────────────────────────────
out="$(run_status --no-reap)"
assert_contains "$out" "by source:" "status: prints a by-source section when U rows exist"
assert_contains "$out" "GOVERN_WORKER_MODEL" "status: names the full model_source string, not just the tier"
assert_contains "$out" "execute-only (parent stated the change)" "status: a distinct source is its own row"
assert_not_contains "$(printf '%s' "$out" | grep 'GOVERN_WORKER_MODEL')" "9.99" \
  "status: run-old's cost is NOT folded into run-new's scoped total"

gwm_line="$(printf '%s\n' "$out" | grep 'GOVERN_WORKER_MODEL')"
assert_contains "$gwm_line" "3 dispatch" \
  "status: GOVERN_WORKER_MODEL counts all THREE run-new dispatches (resolved + timeout + still-live)"
assert_contains "$gwm_line" "resolved:1" "status: the per-status breakdown names the resolved one"
assert_contains "$gwm_line" "timeout:1"  "status: and the timed-out one"
assert_contains "$gwm_line" "live:1"     "status: and the still-live one, separately from done outcomes"
assert_contains "$gwm_line" "2.94"       "status: sums only the PRICED row's cost"
assert_contains "$gwm_line" "1/3 priced" "status: names how many of the group's dispatches carry a price"

haiku_line="$(printf '%s\n' "$out" | grep 'execute-only')"
assert_contains "$haiku_line" "1 dispatch" "status: the execute-only source has its own count"
assert_contains "$haiku_line" "0.12"       "status: and its own cost"

# ── --json ──────────────────────────────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  js="$(run_status --json --no-reap)"
  printf '%s' "$js" | jq empty >/dev/null 2>&1
  assert_eq "$?" "0" "status --json: emits valid JSON with bySource present"
  assert_eq "$(printf '%s' "$js" | jq -r '[.bySource[] | select(.modelSource=="GOVERN_WORKER_MODEL")][0].count')" "3" \
    "status --json: bySource groups by the full modelSource string"
  assert_eq "$(printf '%s' "$js" | jq -r '[.bySource[] | select(.modelSource=="GOVERN_WORKER_MODEL")][0].costUsd')" "2.94" \
    "status --json: costUsd sums only the priced rows"
  assert_eq "$(printf '%s' "$js" | jq -r '[.bySource[] | select(.modelSource=="GOVERN_WORKER_MODEL")][0].pricedCount')" "1" \
    "status --json: pricedCount names how many rows contributed to that sum"
  assert_eq "$(printf '%s' "$js" | jq -r '[.bySource[] | select(.modelSource|test("execute-only"))][0].count')" "1" \
    "status --json: the execute-only source is a distinct row"
fi

# ── --all-runs widens the same fold ────────────────────────────────────────────────────────────
out_all="$(run_status --all-runs --no-reap)"
gwm_all="$(printf '%s\n' "$out_all" | grep 'GOVERN_WORKER_MODEL')"
assert_contains "$gwm_all" "4 dispatch" "status --all-runs: folds run-old's dispatch in too"
assert_contains "$gwm_all" "12.93" "status --all-runs: and its cost (run-new's 2.94 + run-old's 9.99)"

kill "$LIVE_PID" 2>/dev/null; wait 2>/dev/null
assert_done
