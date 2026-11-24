#!/usr/bin/env bash
# The STALL signal stands down for a child that has finished: its final message (the payload's
# last_assistant_message, or the transcript's last assistant text) is a contract report with status
# resolved, parked or failed, or a govern:ship call in its transcript succeeded. A child named `ro-...`
# is exempt from STALL outright. Every case pairs with a negative control on the same stalled
# transcript, so the stand-down is the only thing that changes the verdict.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
GUARD="$GOVERN_HOOKS_DIR/agent-progress-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/state" "$T/tree"
git -C "$T/tree" init -q . && git -C "$T/tree" config user.email t@t && git -C "$T/tree" config user.name t
printf 'seed\n' > "$T/tree/seed.txt"; git -C "$T/tree" add -A; git -C "$T/tree" commit -qm init

gen_stall() {
  for i in $(seq 1 40); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
said() { jq -cn --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
ship() { # <is_error>
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ship1","name":"Bash","input":{"command":"npm run govern:ship -- --add shiploop/x 207"}}]}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"ship1","is_error":%s,"content":"PR opened"}]}}\n' "$1"
}
REPORT='{"status":"resolved","pr":{"repo":"shiploop","number":1,"url":"u"}}'

guard() { # <transcript> <agent_id> [last_assistant_message] [agent_type]
  jq -cn --arg tp "$1" --arg id "$2" --arg lam "${3:-}" --arg ty "${4:-worker}" --arg cwd "$T/tree" \
    '{hook_event_name:"SubagentStop", agent_id:$id, agent_type:$ty, agent_transcript_path:$tp,
      transcript_path:"/parent.jsonl", cwd:$cwd, stop_hook_active:false}
     + (if $lam == "" then {} else {last_assistant_message:$lam} end)' \
  | env TMPDIR="$T/state" bash "$GUARD" 2>/dev/null
}
blocked() { case "$1" in *'"decision":"block"'*STALL*) return 0 ;; esac; return 1; }

gen_stall > "$T/stall.jsonl"
blocked "$(guard "$T/stall.jsonl" a-ctl)" && echo "ok   - control: the stalled transcript is STALL-blocked" \
  || { echo "FAIL - control: the stalled transcript is not blocked"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

out="$(guard "$T/stall.jsonl" a-rep1 "$REPORT")"
assert_eq "$out" "" "a resolved report in last_assistant_message: no STALL block"
out="$(guard "$T/stall.jsonl" a-rep2 '{"status":"parked","escalation":{"reason":"r"}}')"
assert_eq "$out" "" "a parked report: no STALL block"
out="$(guard "$T/stall.jsonl" a-prose "I think I am done, will report later.")"
blocked "$out" && echo "ok   - negative control: prose in last_assistant_message is still blocked" \
  || { echo "FAIL - prose stood the stall down: '$out'"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
out="$(guard "$T/stall.jsonl" a-odd '{"status":"in-progress"}')"
blocked "$out" && echo "ok   - negative control: a status outside resolved|parked|failed is still blocked" \
  || { echo "FAIL - a non-terminal status stood the stall down"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

{ gen_stall; said "$REPORT"; } > "$T/stall-report.jsonl"
out="$(guard "$T/stall-report.jsonl" a-rep3)"
assert_eq "$out" "" "no last_assistant_message: the transcript's last assistant report stands it down"

{ ship false; gen_stall; } > "$T/shipped.jsonl"
out="$(guard "$T/shipped.jsonl" a-ship)"
assert_eq "$out" "" "a govern:ship call that succeeded: no STALL block"
{ ship true; gen_stall; } > "$T/ship-failed.jsonl"
out="$(guard "$T/ship-failed.jsonl" a-shipfail)"
blocked "$out" && echo "ok   - negative control: a govern:ship call that errored is still blocked" \
  || { echo "FAIL - a failed ship stood the stall down"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ro- names: by meta file (a teammate's Agent name) and by payload type.
cp "$T/stall.jsonl" "$T/agent-aro1.jsonl"
printf '{"name":"ro-scan","customAgentType":"general-purpose"}' > "$T/agent-aro1.meta.json"
out="$(guard "$T/agent-aro1.jsonl" aro1 "" general-purpose)"
assert_eq "$out" "" "a child named ro-... (meta name) is exempt from STALL"
out="$(guard "$T/stall.jsonl" aro2 "" ro-scan)"
assert_eq "$out" "" "a child whose payload type is ro-... is exempt from STALL"
cp "$T/stall.jsonl" "$T/agent-arw1.jsonl"
printf '{"name":"rw-scan"}' > "$T/agent-arw1.meta.json"
blocked "$(guard "$T/agent-arw1.jsonl" arw1 "" general-purpose)" \
  && echo "ok   - negative control: another name is still blocked" \
  || { echo "FAIL - a non-ro name was exempted"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

assert_done
