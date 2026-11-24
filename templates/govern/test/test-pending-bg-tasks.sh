#!/usr/bin/env bash
# govern::pending_bg_tasks, the transcript-only background-task detector:
# a delegate that stops "until the notification arrives" is never woken when its background task
# finishes, so the result (and the rest of its task) is silently lost. The detector reads the
# child's OWN transcript: started (auto-moved Bash, run_in_background, Monitor) minus
# completion-notified minus TaskStopped. govern:status falls back to it where the ledger is absent.
# Wire shapes are the ones real transcripts carry: the completion entry is an attachment
# (`queued_command`) carrying <task-id>ID</task-id>, so a child merely QUOTING an id is not a
# completion.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
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

# The stop guard itself reads the ledger (govern::pending_bg_tasks_for), not this detector: its
# cases live in test-bg-wait-guard.sh.

assert_done
