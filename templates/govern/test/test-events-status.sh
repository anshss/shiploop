#!/usr/bin/env bash
# govern:status (status.sh) — folding the fleet event log into live state.
#
# Contract:
#   1. No log → a clear "not enabled" note and exit 0 (a wrapper can call it unconditionally).
#   2. Folds LAST-EVENT-WINS per (run_id, agent_id): spawned→done is idle, spawned→done→spawned is
#      ACTIVE. A naive spawned-minus-done count gets the retry case wrong.
#   3. WORKER liveness is EVENT-DERIVED: a worker is an in-session subagent with no pid of its own,
#      so a spawn older than GOVERN_WORKER_STALE_S with no matching done is STALE, not `kill -0`.
#      DRIVER liveness is unchanged: a driver is a real forked `claude -p` process, so `kill -0`
#      still decides it.
#   4. Stale entries are REAPED — a synthetic worker_done is appended so the next read is clean.
#   5. --no-reap reads without writing.
#   6. Only the newest run is reported by default; --all-runs widens it.
#   7. --json emits valid JSON.
#   8. worker_escalated updates the reported tier.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
EV="$T/governor/events.jsonl"
STATUS="$DIR/../status.sh"

# GOVERN_WORKER_STALE_S pinned small so the fixtures below (offsets in plain seconds, no real
# background processes needed for WORKER liveness) can express "recent" vs "long past the bound"
# without waiting real wall-clock time.
run_status() { GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" GOVERN_WORKER_STALE_S=90 bash "$STATUS" "$@" </dev/null 2>&1; }

# ── 1. absent log ───────────────────────────────────────────────────────────────────────────────
out="$(run_status)"; rc=$?
assert_eq "$rc" "0" "status: exits 0 with no event log"
assert_contains "$out" "no event log" "status: says the log is absent rather than pretending an idle fleet"
assert_contains "$out" "GOVERN_EVENTS=1" "status: names the knob that turns the log on"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# Drivers are still real OS processes (a forked `claude -p`), so `kill -0` still applies to them:
# a live pid we control (a background sleep) and a dead one (the same, after it is reaped).
sleep 60 & LIVE_PID2=$!
sleep 0.1 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null

ev() { printf '%s\n' "$1" >> "$EV"; }
TS="$(date +%s)"
ev "{\"ts\":$((TS-600)),\"run_id\":\"run-old\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\",\"parallel\":2}"
ev "{\"ts\":$((TS-590)),\"run_id\":\"run-old\",\"type\":\"worker_spawned\",\"agent_id\":\"aid-11\",\"agent_type\":\"worker\",\"model\":\"sonnet\",\"effort\":\"medium\"}"
ev "{\"ts\":$((TS-500)),\"run_id\":\"run-old\",\"type\":\"worker_done\",\"agent_id\":\"aid-11\",\"status\":\"resolved\",\"model\":\"sonnet\",\"elapsed\":90}"
ev "{\"ts\":$((TS-490)),\"run_id\":\"run-old\",\"type\":\"run_done\",\"resolved\":1,\"parked\":0,\"failed\":0,\"timeout\":0,\"processed\":1}"
# newest run
ev "{\"ts\":$((TS-300)),\"run_id\":\"run-new\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\",\"parallel\":4}"
ev "{\"ts\":$((TS-290)),\"run_id\":\"run-new\",\"type\":\"driver_spawned\",\"label\":\"#94\",\"pid\":$LIVE_PID2,\"running\":1,\"cap\":4}"
# aid-94: spawned → done → spawned again, the second spawn recent. LAST event wins ⇒ ACTIVE.
ev "{\"ts\":$((TS-280)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"agent_id\":\"aid-94\",\"agent_type\":\"worker\",\"model\":\"sonnet\",\"effort\":\"medium\"}"
ev "{\"ts\":$((TS-250)),\"run_id\":\"run-new\",\"type\":\"worker_done\",\"agent_id\":\"aid-94\",\"status\":\"failed\",\"model\":\"sonnet\",\"elapsed\":30}"
ev "{\"ts\":$((TS-20)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"agent_id\":\"aid-94\",\"agent_type\":\"worker\",\"model\":\"sonnet\",\"effort\":\"medium\"}"
ev "{\"ts\":$((TS-19)),\"run_id\":\"run-new\",\"type\":\"worker_escalated\",\"agent_id\":\"aid-94\",\"from\":\"sonnet\",\"to\":\"opus\",\"reason\":\"budget\"}"
# aid-97: spawned, never done, older than the 90s stale bound ⇒ STALE, not active.
ev "{\"ts\":$((TS-180)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"agent_id\":\"aid-97\",\"agent_type\":\"lookup\",\"model\":\"haiku\",\"effort\":\"low\"}"
# aid-98: cleanly resolved.
ev "{\"ts\":$((TS-170)),\"run_id\":\"run-new\",\"type\":\"worker_spawned\",\"agent_id\":\"aid-98\",\"agent_type\":\"worker\",\"model\":\"sonnet\",\"effort\":\"medium\"}"
ev "{\"ts\":$((TS-100)),\"run_id\":\"run-new\",\"type\":\"worker_done\",\"agent_id\":\"aid-98\",\"status\":\"resolved\",\"model\":\"sonnet\",\"elapsed\":70}"
ev "{\"ts\":$((TS-90)),\"run_id\":\"run-new\",\"type\":\"ticket_parked\",\"ticket\":99,\"note\":\"needs a human\"}"

# ── 2/3/6/8. the default read ───────────────────────────────────────────────────────────────────
out="$(run_status --no-reap)"
assert_contains "$out" "run-new"  "status: reports the NEWEST run"
assert_contains "$out" "1 active" "status: exactly one worker is live (aid-94's second attempt)"
assert_contains "$out" "aid-94"   "status: names the live worker by agent id"
assert_contains "$out" "opus"     "status: worker_escalated updated the reported tier to opus"
assert_not_contains "$out" "aid-98" "status: a finished worker is not listed as active"
assert_contains "$out" "1 resolved" "status: counts only the newest run's outcomes (aid-98), not run-old's"
assert_contains "$out" "stale"    "status: flags the past-the-bound worker as stale"
assert_contains "$out" "aid-97"   "status: names the stale worker by agent id"
assert_contains "$out" "running"  "status: the newest run has no run_done, so it reads as running"
assert_contains "$out" "$LIVE_PID2" "status: reports the live driver pid, drivers are real OS processes"

# ── 5. --no-reap wrote nothing ──────────────────────────────────────────────────────────────────
before="$(wc -l < "$EV" | tr -d ' ')"
run_status --no-reap >/dev/null
after="$(wc -l < "$EV" | tr -d ' ')"
assert_eq "$after" "$before" "status: --no-reap does not append to the log"

# ── 7. --json ───────────────────────────────────────────────────────────────────────────────────
js="$(run_status --json --no-reap)"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$js" | jq empty >/dev/null 2>&1
  assert_eq "$?" "0" "status --json: emits valid JSON"
  assert_eq "$(printf '%s' "$js" | jq -r '.runId')" "run-new" "status --json: runId is the newest run"
  assert_eq "$(printf '%s' "$js" | jq -r '.active | length')" "1" "status --json: one active worker"
  assert_eq "$(printf '%s' "$js" | jq -r '.active[0].agentId')" "aid-94" "status --json: the active worker is aid-94"
  assert_eq "$(printf '%s' "$js" | jq -r '.active[0].model')" "opus" "status --json: the active tier reflects the escalation"
  assert_eq "$(printf '%s' "$js" | jq -r '.stale | length')" "1" "status --json: one stale worker"
  assert_eq "$(printf '%s' "$js" | jq -r '.stale[0].agentId')" "aid-97" "status --json: the stale worker is aid-97"
  assert_eq "$(printf '%s' "$js" | jq -r '.counts.resolved')" "1" "status --json: resolved count is scoped to the newest run"
  assert_eq "$(printf '%s' "$js" | jq -r '.runDone')" "false" "status --json: the newest run is not finished"
  assert_eq "$(printf '%s' "$js" | jq -r '.drivers | length')" "1" "status --json: one live driver"
fi

# ── 4. the reap ─────────────────────────────────────────────────────────────────────────────────
run_status >/dev/null
after="$(wc -l < "$EV" | tr -d ' ')"
assert_eq "$after" "$((before+1))" "status: a reaping read appends exactly one synthetic worker_done"
assert_contains "$(tail -1 "$EV")" '"status":"stale"' "status: the appended row marks the phantom stale"
assert_contains "$(tail -1 "$EV")" '"agent_id":"aid-97"' "status: the appended row names the phantom's agent id"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$EV" >/dev/null 2>&1
  assert_eq "$?" "0" "status: the reaped log is still valid JSONL"
fi
# Idempotent: the phantom is gone from the fold, so a second read appends nothing more.
out="$(run_status)"
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "$((before+1))" "status: the reap is idempotent — a second read appends nothing"
assert_not_contains "$out" "aid-97" "status: the reaped worker no longer appears"
assert_contains "$out" "1 active" "status: reaping did not disturb the genuinely live worker"

# ── 6. --all-runs ───────────────────────────────────────────────────────────────────────────────
out="$(run_status --all-runs --no-reap)"
assert_contains "$out" "2 resolved" "status --all-runs: folds run-old's outcome in as well"

kill "$LIVE_PID2" 2>/dev/null; wait 2>/dev/null
assert_done
