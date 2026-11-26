#!/usr/bin/env bash
# Token usage of a worker dispatched in-session. Such a worker is a sidechain of the advisor's own
# session: it has no worker.jsonl, so until this landed every ticket it resolved recorded
# tokens:null. The usage is in its own transcript, and three pieces now carry it into the ticket's
# history row:
#
#   govern::subagent_usage (lib/common.sh) sums one agent transcript.
#     1. one API response is several assistant lines sharing message.id, and only the last line
#        carries the usage: each field takes the response's largest figure, never their sum;
#     2. usage is also broken down per model (message.model), `model` is what answered the last
#        request (chronologically: by timestamp when the lines carry one, else by place in the file,
#        never by how the message ids happen to sort), costUsd is always null (a transcript carries
#        no price), and the usageSource is "subagent";
#     3. a missing, empty, non-JSON or usage-free transcript reads as usageSource "none";
#     4. a line with no message id is a response of its own.
#   govern::usage_merge joins several agents of one ticket (a first attempt and a retry): tokens
#     and the per-model breakdown add, `model` is the last record's.
#   worker-report-capture.sh records each stopped worker's agent id and transcript path at
#     governor/agents/<N>/<agent-id>.json, whether or not its report parsed.
#   resolve-ticket.sh puts the sum into the ticket-history row (tokens, model, usageByModel,
#     agentIds) when the worker has no stream of its own, and leaves a headless row as it was.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
HOOK="$GOVERN_HOOKS_DIR/worker-report-capture.sh"
[[ -f "$RT" && -f "$HOOK" ]] || { echo "SKIP: resolve-ticket.sh or worker-report-capture.sh not found"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"
set +e   # common.sh re-arms set -e; a test asserts on failing commands
U="$T/usage"; mkdir -p "$U"

# A transcript line. <file> <type> <message-id> <model> <input> <output> <cache-read> <cache-creation>
line() { # append one JSONL line
  printf '{"type":"%s","uuid":"u%s","agentId":"a1","message":{"id":"%s","role":"assistant","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$2" "$RANDOM$RANDOM" "$3" "$4" "$5" "$6" "$7" "$8" >> "$1"
}
usage_of() { govern::subagent_usage "$1"; }

# ── 1. one response, several lines: the largest figure per field, not the sum ─────────────────
# Response r1 arrives as three lines (thinking, tool_use, tool_use); only the last carries its full
# usage. The first carries a small nonzero figure on purpose: summing lines raw would overcount it.
{ line "$U/multi.jsonl" assistant r1 glm-5.3-flash 100 5 0 0
  line "$U/multi.jsonl" assistant r1 glm-5.3-flash 0 0 0 0
  line "$U/multi.jsonl" assistant r1 glm-5.3-flash 76437 122 0 0
  line "$U/multi.jsonl" user x glm-5.3-flash 999999 999999 0 0
  line "$U/multi.jsonl" attachment x glm-5.3-flash 999999 999999 0 0
  line "$U/multi.jsonl" assistant r2 glm-5.3-flash 29969 210 76416 0
} >/dev/null
u="$(usage_of "$U/multi.jsonl")"
assert_eq "$(jq -c '.tokens' <<<"$u")" '{"input":106406,"output":332,"cacheRead":76416,"cacheCreation":0,"total":183154}' \
  "1. tokens: two responses summed, each taken once at its largest figure (other line types ignored)"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "subagent" "1. usageSource is subagent"
assert_eq "$(jq -r '.costUsd' <<<"$u")" "null" "1. costUsd stays null: a transcript carries no price"
assert_eq "$(jq -r '.model' <<<"$u")" "glm-5.3-flash" "1. model is what answered the last request"
assert_eq "$(jq -c '.usageByModel' <<<"$u")" '{"glm-5.3-flash":{"input":106406,"output":332,"cacheRead":76416,"cacheCreation":0,"total":183154}}' \
  "1. usageByModel carries the same figures under the model"

# ── 2. two models in one transcript: a breakdown per model, the last request names `model` ─────
{ line "$U/two.jsonl" assistant r1 glm-5.4 10 1 0 0
  line "$U/two.jsonl" assistant r2 glm-5.3-flash 20 2 5 0
  line "$U/two.jsonl" assistant r3 glm-5.4 30 3 7 0
} >/dev/null
u="$(usage_of "$U/two.jsonl")"
assert_eq "$(jq -c '.tokens' <<<"$u")" '{"input":60,"output":6,"cacheRead":12,"cacheCreation":0,"total":78}' "2. tokens cover every request"
assert_eq "$(jq -r '.model' <<<"$u")" "glm-5.4" "2. model is the last request's model"
assert_eq "$(jq -c '.usageByModel' <<<"$u")" '{"glm-5.3-flash":{"input":20,"output":2,"cacheRead":5,"cacheCreation":0,"total":27},"glm-5.4":{"input":40,"output":4,"cacheRead":7,"cacheCreation":0,"total":51}}' \
  "2. usageByModel splits the tokens per model"

# ── 3. degenerate transcripts read as "none", never as a figure ───────────────────────────────
u="$(usage_of "$U/does-not-exist.jsonl")"
assert_eq "$(jq -c . <<<"$u")" '{"tokens":null,"costUsd":null,"model":null,"usageByModel":{},"usageSource":"none"}' "3. a missing transcript reads as none"
: > "$U/empty.jsonl"
assert_eq "$(jq -r '.usageSource' <<<"$(usage_of "$U/empty.jsonl")")" "none" "3. an empty transcript reads as none"
printf 'this line is not json\n{"type":"assistant","message":{"id":"x","model":"m"}}\n' > "$U/nonjson.jsonl"
assert_eq "$(jq -r '.usageSource' <<<"$(usage_of "$U/nonjson.jsonl")")" "none" "3. a non-JSON line and a line with no usage read as none"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$U/nousage.jsonl"
assert_eq "$(jq -r '.usageSource' <<<"$(usage_of "$U/nousage.jsonl")")" "none" "3. a transcript with no assistant line reads as none"
printf '\000\000\000{"type":"assistant","message":{"id":"r1","model":"m","usage":{"input_tokens":3,"output_tokens":1}}}\n' > "$U/holed.jsonl"
assert_eq "$(jq -r '.tokens.total' <<<"$(usage_of "$U/holed.jsonl")")" "4" "3. a NUL hole in front of the lines does not hide them"

# ── 4. a line with no message id is a response of its own ─────────────────────────────────────
{ printf '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":3,"output_tokens":1}}}\n'
  printf '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":2}}}\n'
} > "$U/noid.jsonl"
assert_eq "$(jq -r '.tokens.total' <<<"$(usage_of "$U/noid.jsonl")")" "11" "4. two id-less responses are two responses (3+1+5+2), not one"
assert_eq "$(jq -r '.model' <<<"$(usage_of "$U/noid.jsonl")")" "m" "4. an id-less line still reports its model"

# ── 5. the merge: several agents of one ticket ────────────────────────────────────────────────
a="$(usage_of "$U/two.jsonl")"
b="$(usage_of "$U/multi.jsonl")"
m="$(govern::usage_merge "$a" "$b")"
assert_eq "$(jq -c '.tokens' <<<"$m")" '{"input":106466,"output":338,"cacheRead":76428,"cacheCreation":0,"total":183232}' \
  "5. tokens add across the agents"
assert_eq "$(jq -r '.model' <<<"$m")" "glm-5.3-flash" "5. model is the LAST record's model"
assert_eq "$(jq -c '.usageByModel["glm-5.4"]' <<<"$m")" '{"input":40,"output":4,"cacheRead":7,"cacheCreation":0,"total":51}' "5. the breakdown keeps each model apart"
assert_eq "$(jq -c '.usageByModel["glm-5.3-flash"]' <<<"$m")" '{"input":106426,"output":334,"cacheRead":76421,"cacheCreation":0,"total":183181}' "5. the same model in two agents is summed under one key"
m="$(govern::usage_merge '{"tokens":null,"costUsd":null,"model":null,"usageByModel":{},"usageSource":"none"}' "$a")"
assert_eq "$(jq -r '.usageSource' <<<"$m")" "subagent" "5. one agent with usage among several without still reads as subagent"
assert_eq "$(jq -r '.tokens.total' <<<"$m")" "78" "5. an agent without usage adds nothing"
m="$(govern::usage_merge)"
assert_eq "$(jq -r '.usageSource' <<<"$m")" "none" "5. no records at all read as none"
assert_eq "$(jq -r '.tokens' <<<"$m")" "null" "5. no records at all carry no tokens"

# ── 6. worker-report-capture.sh records the agent per ticket, with or without a report ───────
R="$T/governor/reports"
export GOVERN_REPORT_CAPTURE=1   # assert.sh forces this off suite-wide; this is the test that opts back in
prompt() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
said() { jq -cn --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
cap() { # <transcript> [last_assistant_message] [agent_type] [agent_id]
  jq -cn --arg tp "$1" --arg lam "${2:-}" --arg ty "${3:-worker}" --arg aid "${4:-a1}" \
    '{hook_event_name:"SubagentStop", agent_id:$aid, agent_type:$ty, agent_transcript_path:$tp, stop_hook_active:false}
     + (if $lam == "" then {} else {last_assistant_message:$lam} end)' \
  | bash "$HOOK" >/dev/null 2>&1
}
A="$T/governor/agents"
{ prompt "Resolve #801. Do the thing."; } > "$U/agent-a1.jsonl"
cap "$U/agent-a1.jsonl" '{"status":"resolved"}' worker a1
assert_eq "$(jq -r '.agent_id + " " + .agent_type + " " + .transcript' "$A/801/a1.json" 2>/dev/null)" "a1 worker $U/agent-a1.jsonl" \
  "6. a stopped worker is recorded against its ticket with id, type and transcript path"
{ prompt "Resolve #802."; } > "$U/agent-a2.jsonl"
cap "$U/agent-a2.jsonl" "All done, prose only." worker-retry a2
assert_eq "$(ls "$R/802.json" 2>/dev/null)" "" "6. prose still writes no report (negative control for the record)"
assert_eq "$(jq -r '.agent_type' "$A/802/a2.json" 2>/dev/null)" "worker-retry" "6. ...but the agent IS recorded: a failed attempt is the row sizing needs most"
{ prompt "Resolve #803."; } > "$U/agent-x.jsonl"
cap "$U/agent-x.jsonl" '{"status":"resolved"}' general-purpose x1
assert_eq "$(ls "$A/803" 2>/dev/null)" "" "6. a non-worker child records nothing (negative control)"
cap "$U/agent-a1.jsonl" '{"status":"resolved"}' worker a1
assert_eq "$(ls "$A/801" | tr '\n' ' ')" "a1.json " "6. a second stop of the same agent overwrites its one record"
( export GOVERN_REPORT_CAPTURE=0; { prompt "Resolve #804."; } > "$U/agent-a4.jsonl"; cap "$U/agent-a4.jsonl" '{"status":"resolved"}' worker a4 )
assert_eq "$(ls "$A/804" 2>/dev/null)" "" "6. GOVERN_REPORT_CAPTURE=0 records nothing"

# ── 7. resolve-ticket.sh: the history row of an in-session worker ────────────────────────────
# Sandboxed like test-resolve-ticket-group.sh: stubbed land-resolution.sh / merge-pr.sh /
# await-ci.sh / gh, no network, no real push.
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"
[[ -f "$DIR/../lib/pregate.sh" ]] && cp "$DIR/../lib/pregate.sh" "$T/bin/lib/"
[[ -f "$DIR/../lib/landed.sh" ]] && cp "$DIR/../lib/landed.sh" "$T/bin/lib/"
if [[ -f "$DIR/../post-merge-check.sh" ]]; then cp "$DIR/../post-merge-check.sh" "$T/bin/"; fi
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$T/bin/land-resolution.sh"
printf '#!/usr/bin/env bash\nprintf "green\\n"\nexit 0\n' > "$T/bin/await-ci.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/merge-pr.sh"
printf '#!/usr/bin/env bash\ncase "$*" in *headRefName*) echo stub-branch ;; *) exit 1 ;; esac\n' > "$T/bin/gh"
chmod +x "$T/bin"/*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH" GOVERN_NO_PUSH=1
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #42: an ordinary ticket

**Severity:** Low

Done when: it lands.
TIX
( cd "$T" && git add -A && git commit -qm init )
HIST="$T/governor/ticket-history.jsonl"
: > "$HIST"
# Ticket 42 was run by two in-session agents: a first attempt on the floor, a retry on the top model.
line "$U/agent-7a.jsonl" assistant r1 glm-5.3-flash 1000 10 0 0
line "$U/agent-7b.jsonl" assistant r1 glm-5.4 2000 20 0 0
mkdir -p "$A/42"
jq -cn --arg tp "$U/agent-7a.jsonl" '{agent_id:"a7a", agent_type:"worker", transcript:$tp, ts:100}' > "$A/42/a7a.json"
jq -cn --arg tp "$U/agent-7b.jsonl" '{agent_id:"a7b", agent_type:"worker-retry", transcript:$tp, ts:200}' > "$A/42/a7b.json"
( cd "$T" && printf '%s' '{"status":"resolved","pr":{"repo":"alpha","number":7},"newTickets":[],"lessonPatch":null,"validation":null}' \
    | GOVERN_HISTORY_FILE="$HIST" bash "$T/bin/resolve-ticket.sh" 42 >/dev/null 2>&1 )
row="$(grep '"ticket":42' "$HIST" | tail -1)"
assert_eq "$(jq -c '.tokens' <<<"$row")" '{"input":3000,"output":30,"cacheRead":0,"cacheCreation":0,"total":3030}' \
  "7. the history row sums both agents' transcripts"
assert_eq "$(jq -r '.model' <<<"$row")" "glm-5.4" "7. model is the last agent's (the retry that resolved the ticket)"
assert_eq "$(jq -c '.usageByModel' <<<"$row")" '{"glm-5.3-flash":{"input":1000,"output":10,"cacheRead":0,"cacheCreation":0,"total":1010},"glm-5.4":{"input":2000,"output":20,"cacheRead":0,"cacheCreation":0,"total":2020}}' \
  "7. usageByModel keeps the attempt and the retry apart"
assert_eq "$(jq -r '.usageSource' <<<"$row")" "subagent" "7. usageSource is subagent"
assert_eq "$(jq -r '.costUsd' <<<"$row")" "null" "7. costUsd stays null"
assert_eq "$(jq -c '.agentIds' <<<"$row")" '["a7a","a7b"]' "7. agentIds name the transcripts the row was summed from"
assert_eq "$(jq -r '.status' <<<"$row")" "resolved" "7. the row's status and the rest of its shape are unchanged"

# ── 8. a ticket with no recorded agent reads exactly as before ───────────────────────────────
rm -rf "$A/42"; : > "$HIST"
( cd "$T" && printf '%s' '{"status":"resolved","pr":{"repo":"alpha","number":8},"newTickets":[],"lessonPatch":null,"validation":null}' \
    | GOVERN_HISTORY_FILE="$HIST" bash "$T/bin/resolve-ticket.sh" 42 >/dev/null 2>&1 )
row="$(grep '"ticket":42' "$HIST" | tail -1)"
assert_eq "$(jq -c '[.tokens, .costUsd, .model, .usageSource]' <<<"$row")" '[null,null,null,"none"]' \
  "8. no recorded agent and no stream: tokens, cost, model and usageSource as before"
assert_eq "$(jq -c '[.agentIds, .usageByModel]' <<<"$row")" '[[],{}]' "8. the two new keys are present and empty"

# ── 9. a headless worker's own stream still wins; the two sources are never added ────────────
: > "$HIST"
mkdir -p "$T/logs/govern/ticket-42"
printf '%s\n' '{"type":"result","usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.5}' \
  > "$T/logs/govern/ticket-42/worker.jsonl"
( cd "$T" && printf '%s' '{"status":"resolved","pr":{"repo":"alpha","number":9},"newTickets":[],"lessonPatch":null,"validation":null}' \
    | GOVERN_HISTORY_FILE="$HIST" GOVERN_LOG_ROOT="$T/logs/govern" bash "$T/bin/resolve-ticket.sh" 42 >/dev/null 2>&1 )
row="$(grep '"ticket":42' "$HIST" | tail -1)"
assert_eq "$(jq -c '[.tokens.total, .costUsd, .usageSource]' <<<"$row")" '[55,0.5,"result"]' \
  "9. with a stream of its own the worker's row comes from the stream alone"
rm -rf "$T/logs"

# ── 10. `model` is the chronologically last request's, however the message ids sort ───────────
# Responses are grouped by message id, and group_by orders the groups by that id. An id that sorts
# last is not the last response written: ids are opaque and need not be in file order at all.
# A transcript line with a timestamp. <file> <message-id> <model> <input> <timestamp-iso|-> <outputs...>
tline() { # append one JSONL line, stamped when the 5th argument is not "-"
  local ts=''
  [[ "$5" != "-" ]] && ts=",\"timestamp\":\"$5\""
  printf '{"type":"assistant"%s,"agentId":"a1","message":{"id":"%s","role":"assistant","model":"%s","usage":{"input_tokens":%s,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "$ts" "$2" "$3" "$4" >> "$1"
}
# The two-line repro: the id that sorts FIRST is the request written LAST. Without timestamps the
# file order is all there is, and it must decide.
{ tline "$U/order.jsonl" msg_z_early model-EARLY 100 -
  tline "$U/order.jsonl" msg_a_late  model-LATE  200 - ; } >/dev/null
u="$(usage_of "$U/order.jsonl")"
assert_eq "$(jq -r '.model' <<<"$u")" "model-LATE" "10. model is the last request in file order, not the id that sorts last"
assert_eq "$(jq -c '.tokens' <<<"$u")" '{"input":300,"output":2,"cacheRead":0,"cacheCreation":0,"total":302}' \
  "10. ...and the out-of-order ids still sum every response exactly once"
assert_eq "$(jq -c '.usageByModel' <<<"$u")" '{"model-EARLY":{"input":100,"output":1,"cacheRead":0,"cacheCreation":0,"total":101},"model-LATE":{"input":200,"output":1,"cacheRead":0,"cacheCreation":0,"total":201}}' \
  "10. ...with the breakdown per model intact"

# With timestamps the stamps decide, even against the file order: the later line was written first.
{ tline "$U/stamped.jsonl" msg_b model-LATE  200 2026-11-26T22:05:58.500Z
  tline "$U/stamped.jsonl" msg_z model-MID   300 2026-11-26T22:06:00Z
  tline "$U/stamped.jsonl" msg_a model-EARLY 100 2026-11-26T22:05:00Z ; } >/dev/null
u="$(usage_of "$U/stamped.jsonl")"
assert_eq "$(jq -r '.model' <<<"$u")" "model-MID" "10. with timestamps the latest stamp names model, over both file order and id order"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "603" "10. ...and every stamped response still counts"

# A partly stamped transcript: the stamps it has decide, and an unstamped line never wins by
# being last in the file.
{ tline "$U/part.jsonl" msg_a model-STAMPED 100 2026-11-26T22:05:00Z
  tline "$U/part.jsonl" msg_b model-UNSTAMPED 200 - ; } >/dev/null
u="$(usage_of "$U/part.jsonl")"
assert_eq "$(jq -r '.model' <<<"$u")" "model-STAMPED" "10. a stamped response beats an unstamped one written after it"

# A timestamp that does not parse is no timestamp: the line keeps its place in the file order.
{ tline "$U/badts.jsonl" msg_a model-FIRST 100 not-a-date
  tline "$U/badts.jsonl" msg_b model-LAST  200 - ; } >/dev/null
u="$(usage_of "$U/badts.jsonl")"
assert_eq "$(jq -r '.model' <<<"$u")" "model-LAST" "10. an unparseable timestamp falls back to file order"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "subagent" "10. ...and the transcript still reads as subagent, not none"

assert_done
