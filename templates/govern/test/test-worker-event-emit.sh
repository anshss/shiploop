#!/usr/bin/env bash
# worker-event-emit.sh: the SubagentStart/PreToolUse/SubagentStop hook that writes `worker_spawned`
# and `worker_done` into governor/events.jsonl, keyed on a subagent's own agent_id (not a ticket:
# a hook never sees one).
#
# Covered:
#   1. GOVERN_EVENTS=0 (the default) → no row, no output, regardless of event.
#   2. SubagentStart → exactly one worker_spawned row, carrying agent_id + agent_type.
#   3. A driver/advisor call (no agent_id at all) → never touched, no row.
#   4. PreToolUse, no prior SubagentStart seen for this agent_id → the fallback fires: one
#      worker_spawned row.
#   5. PreToolUse, SubagentStart already recorded this agent_id → the fallback is a no-op: no
#      second row (idempotent together).
#   6. A SECOND SubagentStart for the same agent_id → also a no-op (the marker file already exists).
#   7. SubagentStop → one worker_done row, status=stopped.
#   8. SubagentStop with stop_hook_active=true → no row (a blocked-stop retry, not a new completion).
#   9. No lib/common.sh reachable → every path still exits 0, nothing crashes, nothing is written.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

HOOK="$GOVERN_HOOKS_DIR/worker-event-emit.sh"
[ -f "$HOOK" ] || { echo "SKIP: worker-event-emit.sh not found under $GOVERN_HOOKS_DIR"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"   # isolate the spawn-marker state files from the real /tmp
mk_ws_stub "$TMP/ws"   # exports GOVERN_WS_ROOT so the hook's common.sh source resolves hermetically

EV="$TMP/events.jsonl"

# payload <event_name> <agent_id|""> <agent_type> [extra_json_fragment]
payload() {
  local ev="$1" aid="$2" atype="$3" extra="${4:-}"
  if [ -n "$aid" ]; then
    printf '{"hook_event_name":"%s","agent_id":"%s","agent_type":"%s","session_id":"s1"%s}' \
      "$ev" "$aid" "$atype" "$extra"
  else
    printf '{"hook_event_name":"%s","session_id":"s1"%s}' "$ev" "$extra"
  fi
}

run() { GOVERN_EVENTS_FILE="$EV" GOVERN_WS_ROOT="$TMP/ws" bash "$HOOK"; }

# == 1. GOVERN_EVENTS=0 (the default): nothing written, ever ===================================
rm -f "$EV"
out1="$(payload SubagentStart wc-off worker | GOVERN_EVENTS= run)"
assert_eq "$out1" "" "1. GOVERN_EVENTS unset → no output"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" "1. GOVERN_EVENTS unset → no log file at all"

# == 2. SubagentStart writes exactly one worker_spawned row ====================================
rm -f "$EV"
out2="$(payload SubagentStart wc-start worker | GOVERN_EVENTS=1 run)"
assert_eq "$out2" "" "2. the emitter never prints anything (it only appends to the log)"
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "1" "2. SubagentStart appends exactly one line"
assert_contains "$(cat "$EV")" '"type":"worker_spawned"' "2. the row is a worker_spawned event"
assert_contains "$(cat "$EV")" '"agent_id":"wc-start"' "2. the row carries the agent_id"
assert_contains "$(cat "$EV")" '"agent_type":"worker"' "2. the row carries the agent_type"
assert_not_contains "$(cat "$EV")" '"pid"' "2. no pid field, a subagent has none of its own"
assert_not_contains "$(cat "$EV")" '"ticket"' "2. no ticket field, a hook never sees one"

# == 3. a driver/advisor call (no agent_id) is never touched ===================================
rm -f "$EV"
out3="$(payload SubagentStart "" "" | GOVERN_EVENTS=1 run)"
assert_eq "$out3" "" "3. no agent_id → no output"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" "3. no agent_id → nothing written"

# == 4. PreToolUse fallback fires when SubagentStart was never seen ============================
rm -f "$EV"
out4="$(payload PreToolUse wc-fallback lookup | GOVERN_EVENTS=1 run)"
assert_eq "$out4" "" "4. the fallback never prints anything either"
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "1" "4. PreToolUse with no prior spawn marker writes one row"
assert_contains "$(cat "$EV")" '"type":"worker_spawned"' "4. the fallback row is a worker_spawned event"
assert_contains "$(cat "$EV")" '"agent_id":"wc-fallback"' "4. the fallback row carries the right agent_id"

# == 5. a SECOND PreToolUse for the SAME agent_id is a no-op ===================================
payload PreToolUse wc-fallback lookup | GOVERN_EVENTS=1 run > /dev/null
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "1" "5. a second PreToolUse call for the same agent_id appends nothing more"

# == 6. SubagentStart AFTER the fallback already recorded the spawn is ALSO a no-op =============
payload SubagentStart wc-fallback worker | GOVERN_EVENTS=1 run > /dev/null
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "1" \
  "6. SubagentStart for an agent_id the PreToolUse fallback already recorded appends nothing more"

# == 7. SubagentStop writes one worker_done row =================================================
rm -f "$EV"
out7="$(payload SubagentStop wc-stop worker | GOVERN_EVENTS=1 run)"
assert_eq "$out7" "" "7. SubagentStop never prints anything"
assert_eq "$(wc -l < "$EV" | tr -d ' ')" "1" "7. SubagentStop appends exactly one line"
assert_contains "$(cat "$EV")" '"type":"worker_done"' "7. the row is a worker_done event"
assert_contains "$(cat "$EV")" '"agent_id":"wc-stop"' "7. the row carries the agent_id"
assert_contains "$(cat "$EV")" '"status":"stopped"' "7. status is the hook's own honest word, not a guessed outcome"

# == 8. SubagentStop with stop_hook_active=true (a blocked-stop retry) writes nothing ===========
rm -f "$EV"
out8="$(payload SubagentStop wc-retry worker ',"stop_hook_active":true' | GOVERN_EVENTS=1 run)"
assert_eq "$out8" "" "8. no output on a blocked-stop retry"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" \
  "8. stop_hook_active=true → nothing written (this attempt did not really finish)"

# == 9. FAIL OPEN. No lib/common.sh reachable anywhere near the hook ===========================
ORPHAN="$TMP/orphan/hooks"; mkdir -p "$ORPHAN"
cp "$HOOK" "$ORPHAN/worker-event-emit.sh"
rm -f "$EV"
out9="$(payload SubagentStart wc-orphan worker | env GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$EV" \
  GOVERN_WS_ROOT="$TMP/ws" bash "$ORPHAN/worker-event-emit.sh")"
assert_eq "$out9" "" "9. no common.sh reachable → still no crash, no output"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" "9. and nothing is written, rather than half a row"

assert_done
