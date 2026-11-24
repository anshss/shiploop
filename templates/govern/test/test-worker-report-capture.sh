#!/usr/bin/env bash
# worker-report-capture.sh (SubagentStop): a worker's report lands in governor/reports/<N>.json from
# each of its three sources (a SubagentHandback call, last_assistant_message, the transcript's last
# assistant text), N taken from the spawn prompt (a named dispatch packet's `## Ticket #N` headings
# first, else the prompt's first line). Prose writes nothing; a non-worker child writes nothing.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
HOOK="$GOVERN_HOOKS_DIR/worker-report-capture.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
R="$T/governor/reports"

prompt() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
said() { jq -cn --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
handback() { jq -cn --arg m "$1" '{type:"assistant",message:{content:[{type:"tool_use",id:"h1",name:"SubagentHandback",input:{message:$m}}]}}'; }
cap() { # <transcript> [last_assistant_message] [agent_type]
  jq -cn --arg tp "$1" --arg lam "${2:-}" --arg ty "${3:-worker}" \
    '{hook_event_name:"SubagentStop", agent_id:"a1", agent_type:$ty, agent_transcript_path:$tp, stop_hook_active:false}
     + (if $lam == "" then {} else {last_assistant_message:$lam} end)' \
  | env GOVERN_REPORT_CAPTURE=1 bash "$HOOK" >/dev/null 2>&1
}
status_of() { jq -r '.status' "$R/$1.json" 2>/dev/null; }

# 1. SubagentHandback wins over last_assistant_message.
{ prompt "Resolve #301. Do the thing."; handback '{"status":"resolved","pr":null,"src":"handback"}'; said "bye"; } > "$T/t1.jsonl"
cap "$T/t1.jsonl" '{"status":"failed","src":"lam"}'
assert_eq "$(jq -r '.src' "$R/301.json" 2>/dev/null)" "handback" "source 1: a SubagentHandback message is captured first"

# 2. last_assistant_message.
{ prompt "Resolve #302."; said "working"; } > "$T/t2.jsonl"
cap "$T/t2.jsonl" '{"status":"parked","escalation":{"reason":"r"}}'
assert_eq "$(status_of 302)" "parked" "source 2: last_assistant_message is captured"

# 3. the transcript's last assistant text.
{ prompt "Resolve #303."; said '{"status":"resolved","pr":{"repo":"x","number":2,"url":"u"}}'; } > "$T/t3.jsonl"
cap "$T/t3.jsonl"
assert_eq "$(status_of 303)" "resolved" "source 3: the transcript's last assistant text is captured"

# 4. prose: nothing written (negative control for all three).
{ prompt "Resolve #304."; said "All done, the PR is open."; } > "$T/t4.jsonl"
cap "$T/t4.jsonl" "All done, the PR is open."
assert_eq "$(ls "$R/304.json" 2>/dev/null)" "" "prose: no report file is written"
{ prompt "Resolve #305."; said '{"status":"in-progress"}'; } > "$T/t5.jsonl"
cap "$T/t5.jsonl"
assert_eq "$(ls "$R/305.json" 2>/dev/null)" "" "a status outside resolved|parked|failed: nothing written"

# 5. a dispatch packet named in the prompt lists a group: one file per member.
printf '# Dispatch packet for #401, #402\n\n## Ticket #401\n\nx\n\n## Ticket #402\n\ny\n' > "$T/.dispatch-packet.md"
{ prompt "Resolve #401,#402 and see also #999. Read your packet at $T/.dispatch-packet.md first."; } > "$T/t6.jsonl"
cap "$T/t6.jsonl" '{"status":"resolved","tickets":[{"ticket":401,"status":"resolved"},{"ticket":402,"status":"resolved"}]}'
assert_eq "$(status_of 401):$(status_of 402)" "resolved:resolved" "group: the packet's tickets each get the report"
assert_eq "$(ls "$R/999.json" 2>/dev/null)" "" "group: a number the packet does not list is not written"

# 6. a non-worker child is ignored; a teammate whose meta says worker is not.
{ prompt "Resolve #501."; } > "$T/agent-x1.jsonl"
cap "$T/agent-x1.jsonl" '{"status":"resolved"}' general-purpose
assert_eq "$(ls "$R/501.json" 2>/dev/null)" "" "a general-purpose child writes nothing (negative control)"
printf '{"name":"worker-501","agentType":"worker-501","customAgentType":"worker"}' > "$T/agent-x1.meta.json"
cap "$T/agent-x1.jsonl" '{"status":"resolved"}' worker-501
assert_eq "$(status_of 501)" "resolved" "a teammate whose meta file says customAgentType worker is captured"

# 7. a PR number on the first line is not a ticket number.
{ prompt "Follow up on PR #77 for ticket #601."; } > "$T/t7.jsonl"
cap "$T/t7.jsonl" '{"status":"resolved"}'
assert_eq "$(ls "$R" | grep -c '^77\.json$')" "0" "PR #77 on the first line is not taken as a ticket"
assert_eq "$(status_of 601)" "resolved" "the ticket number beside it is"

# 8. kill switch.
{ prompt "Resolve #701."; } > "$T/t8.jsonl"
jq -cn --arg tp "$T/t8.jsonl" '{agent_type:"worker",agent_transcript_path:$tp,last_assistant_message:"{\"status\":\"resolved\"}"}' \
  | env GOVERN_REPORT_CAPTURE=0 bash "$HOOK" >/dev/null 2>&1
assert_eq "$(ls "$R/701.json" 2>/dev/null)" "" "GOVERN_REPORT_CAPTURE=0 writes nothing"

assert_done
