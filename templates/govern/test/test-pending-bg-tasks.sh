#!/usr/bin/env bash
# govern::pending_bg_tasks + the agent-progress-guard background-wait block:
# a delegate that stops "until the notification arrives" is never woken when its background task
# finishes, so the result (and the rest of its task) is silently lost. The detector reads the
# child's OWN transcript: started (auto-moved Bash, run_in_background, Monitor) minus
# completion-notified minus TaskStopped. The guard block ships OFF (GOVERN_BG_WAIT_GUARD) because
# it BLOCKS a stop every existing install allows; the test proves both knob states.
# Wire shapes are the ones real transcripts carry: the completion entry is an attachment
# (`queued_command`) carrying <task-id>ID</task-id>, so a child merely QUOTING an id is not a
# completion.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# GOVERN_HOOKS_DIR (assert.sh) resolves BOTH layouts: templates/hooks in the hub repo, <root>/scripts
# in a scaffolded workspace (hooks install flat there, so the hub-relative ../../hooks path misses).
GUARD="$GOVERN_HOOKS_DIR/agent-progress-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"
set +e   # common.sh re-armed -e

# --- wire-shaped transcript lines ---
moved()   { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Command did not complete within its 120s timeout and was moved to the background (ID: %s). Output is being written to /tmp/tasks/%s.output"}]}}\n' "$1" "$1"; }
bgstart() { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Command running in background with ID: %s. Output is being written to /tmp/tasks/%s.output"}]}}\n' "$1" "$1"; }
monitor() { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"Monitor started (task %s, expires in 5m unless the source ends first; you get one notification)"}]}}\n' "$1"; }
notice()  { printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\\n<task-id>%s</task-id>\\n<status>completed</status>\\n</task-notification>","commandMode":"task-notification"}}\n' "$1"; }
stopped() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"TaskStop","input":{"task_id":"%s"}}]}}\n' "$1"; }
said()    { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1"; }
denied()  { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t6","content":"[AGENT WATCHDOG] wall-clock: stop now"}]}}\n'; }

# detector: govern::pending_bg_tasks
{ moved bx1; said "Pausing here until that arrives."; } > "$T/a.jsonl"
assert_eq "$(govern::pending_bg_tasks "$T/a.jsonl")" "bx1" "an auto-moved task with no completion entry is pending"
{ moved bx1; notice bx1; said "done"; } > "$T/b.jsonl"
assert_eq "$(govern::pending_bg_tasks "$T/b.jsonl")" "" "a completion notification clears it (negative control)"
{ moved bx1; stopped bx1; said "done"; } > "$T/c.jsonl"
assert_eq "$(govern::pending_bg_tasks "$T/c.jsonl")" "" "a TaskStop clears it (negative control)"
{ monitor mx1; bgstart bg1; said "waiting"; } > "$T/d.jsonl"
assert_eq "$(govern::pending_bg_tasks "$T/d.jsonl")" "bg1 mx1" "a Monitor and a run_in_background task are pending too"
{ moved bx1; said "the notification will carry <task-id>bx1</task-id>"; } > "$T/e.jsonl"
assert_eq "$(govern::pending_bg_tasks "$T/e.jsonl")" "bx1" "the child QUOTING a task id is not a completion"
assert_eq "$(govern::pending_bg_tasks "$T/missing.jsonl")" "" "a missing transcript is no evidence"

# guard: the block fires only with the knob ON, on SubagentStop, once, naming the task.
child() { # <transcript> [stop_hook_active] [knob]
  printf '{"hook_event_name":"SubagentStop","agent_id":"atest-1","agent_type":"general-purpose","agent_transcript_path":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":%s}' \
    "$1" "$1" "$T" "${2:-false}" \
  | GOVERN_BG_WAIT_GUARD="${3:-1}" bash "$GUARD" 2>/dev/null
}
out="$(child "$T/a.jsonl")"
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | test("bx1"))' >/dev/null 2>&1; then
  echo "ok   - knob ON: a stop with a pending task is blocked as JSON naming the task"
else
  echo "FAIL - knob ON: no JSON block for a pending task: '$out'"; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
out="$(child "$T/a.jsonl" true)"
assert_eq "$out" "" "a second stop (stop_hook_active) passes"

# knob OFF (the shipping default): the same transcript is NOT blocked — the old behavior.
out="$(child "$T/a.jsonl" false 0)"
assert_eq "$out" "" "knob OFF (default): the pending-task stop is allowed, as every existing install does"
out="$(child "$T/b.jsonl" false 1)"
assert_eq "$out" "" "knob ON but the task was reported: no block (negative control)"
{ moved bx1; denied; said "capped"; } > "$T/f.jsonl"
out="$(child "$T/f.jsonl" false 1)"
assert_eq "$out" "" "knob ON but the child is wall-clock-capped: no block (it has no legal move)"

assert_done
