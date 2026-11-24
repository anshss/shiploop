#!/usr/bin/env bash
# The background-task wait: bg-task-ledger.sh records a child's background launches at PostToolUse,
# govern::pending_bg_tasks_for reads them back, and agent-progress-guard.sh, when that child stops,
# holds the stop until each task's output file shows Claude Code's exit line, then blocks with the
# task's id, status and last output lines. A task with no recognizable exit line by the deadline, or
# no output file at all, gets the wait-in-your-turn remedy instead.
# Fixture shapes are the ones verified live: tool_response.backgroundTaskId (Bash, plus
# timedOutAfterMs when auto-backgrounded), tool_response.taskId (Monitor), and the
# `[exited with code N]` / `[killed]` line Claude Code appends to the output file.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
LEDGER_HOOK="$GOVERN_HOOKS_DIR/bg-task-ledger.sh"
GUARD="$GOVERN_HOOKS_DIR/agent-progress-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"
set +e   # common.sh re-armed -e
mkdir -p "$T/state"
LEDGER="$T/governor/.bg-ledger"

# A fake Claude Code temp root: <root>/claude-<uid>/<slug>/<session>/tasks/<id>.output
CC_TMP="$T/cctmp"
TASKS="$CC_TMP/claude-$(id -u)/-proj-slug/sess-1/tasks"
mkdir -p "$TASKS"

post() { # <agent_id|""> <tool> <response-json>
  local aid=""
  [ -n "$1" ] && aid="\"agent_id\":\"$1\",\"agent_type\":\"worker\","
  printf '{%s"session_id":"sess-1","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{},"tool_response":%s}' \
    "$aid" "$2" "$3" \
  | env GOVERN_BG_LEDGER=1 CLAUDE_CODE_TMPDIR="$CC_TMP" bash "$LEDGER_HOOK" </dev/stdin >/dev/null 2>&1
}

# ── ledger hook ──────────────────────────────────────────────────────────────────────────────
printf 'x\n' > "$TASKS/bk1.output"
post a1 Bash '{"stdout":"","backgroundTaskId":"bk1"}'
post a1 Bash '{"stdout":"","backgroundTaskId":"bk2","timedOutAfterMs":120000}'
post a1 Monitor '{"taskId":"mk3","timeoutMs":30000,"persistent":false}'
post a1 Bash '{"stdout":"done","stderr":""}'
post "" Bash '{"stdout":"","backgroundTaskId":"bdriver"}'
assert_eq "$(cut -f2,3 "$LEDGER/a1.tsv" | tr '\t\n' ': ')" "bk1:bash bk2:bash mk3:monitor " \
  "ledger: bg Bash, auto-backgrounded Bash and Monitor each get one line; a foreground Bash none"
assert_eq "$(awk -F'\t' '$2=="bk1"{print $4}' "$LEDGER/a1.tsv")" "$TASKS/bk1.output" \
  "ledger: the output file is found under the temp root by session and task id"
assert_eq "$(awk -F'\t' '$2=="bk2"{print $4}' "$LEDGER/a1.tsv")" "" \
  "ledger: no such output file -> the line is still written, with an empty path"
assert_eq "$(ls "$LEDGER" | tr '\n' ' ')" "a1.tsv " "ledger: the driver's own call (no agent_id) is never recorded"
post a9 Bash '{"backgroundTaskId":"bz9"}'
env GOVERN_BG_LEDGER=0 bash "$LEDGER_HOOK" <<< '{"agent_id":"a8","tool_name":"Bash","session_id":"sess-1","tool_response":{"backgroundTaskId":"bz8"}}'
assert_eq "$(ls "$LEDGER/a8.tsv" 2>/dev/null)" "" "ledger: GOVERN_BG_LEDGER=0 writes nothing (negative control)"

# ── govern::pending_bg_tasks_for ─────────────────────────────────────────────────────────────
notice() { printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\\n<task-id>%s</task-id>\\n<status>completed</status>\\n</task-notification>"}}\n' "$1"; }
mon_event() { printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\\n<task-id>%s</task-id>\\n<event>m1</event>\\n</task-notification>"}}\n' "$1"; }
stopped() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"TaskStop","input":{"task_id":"%s"}}]}}\n' "$1"; }
denied()  { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t6","content":"[AGENT WATCHDOG] wall-clock: stop now"}]}}\n'; }
: > "$T/empty.jsonl"
assert_eq "$(govern::pending_bg_tasks_for a1 "$T/empty.jsonl")" "bk1 bk2 mk3" \
  "pending: a same-turn launch the transcript does not show yet is pending from the ledger"
{ notice bk1; mon_event mk3; stopped bk2; } > "$T/closed.jsonl"
assert_eq "$(govern::pending_bg_tasks_for a1 "$T/closed.jsonl")" "mk3" \
  "pending: a completion notice and a TaskStop close a task; a Monitor's per-event notice does not"
printf 'bk1\n' > "$LEDGER/a1.delivered"
assert_eq "$(govern::pending_bg_tasks_for a1 "$T/empty.jsonl")" "bk2 mk3" "pending: a delivered result is not pending"
rm -f "$LEDGER/a1.delivered"
assert_eq "$(govern::pending_bg_tasks_for nobody "$T/empty.jsonl")" "" "pending: no ledger for the agent is no evidence"

# ── the guard ────────────────────────────────────────────────────────────────────────────────
# ledger_line <agent> <task> <file>
ledger_line() { mkdir -p "$LEDGER"; printf '%s\t%s\tbash\t%s\n' "$(date +%s)" "$2" "$3" >> "$LEDGER/$1.tsv"; }
outfile() { # <task> <trailer|""> -> a 25-line output file, optionally ended by Claude Code's exit line
  local f="$TASKS/$1.output" i
  : > "$f"
  for i in $(seq 1 25); do printf 'out line %s\n' "$i" >> "$f"; done
  [ -n "$2" ] && printf '\n%s\n' "$2" >> "$f"
  printf '%s' "$f"
}
guard() { # <agent> <transcript> [stop_hook_active] [event] -- env from the caller
  printf '{"hook_event_name":"%s","agent_id":"%s","agent_type":"worker","agent_transcript_path":"%s","transcript_path":"%s/PARENT.jsonl","cwd":"%s","stop_hook_active":%s}' \
    "${4:-SubagentStop}" "$1" "$2" "$T" "$T" "${3:-false}" \
  | env TMPDIR="$T/state" GOVERN_BG_WAIT_GUARD="${KNOB:-1}" GOVERN_BG_WAIT_MAX_S="${MAXS:-3}" \
        GOVERN_BG_WAIT_HOLD="${HOLD:-1}" bash "$GUARD" 2>"$T/stderr"
}
reason_of() { printf '%s' "$1" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null; }

n=0
for trailer in "[exited with code 0]" "[exited with code 1]" "[killed]"; do
  n=$((n+1)); ag="ag-done-$n"
  ledger_line "$ag" "bd$n" "$(outfile "bd$n" "$trailer")"
  out="$(guard "$ag" "$T/empty.jsonl")"
  r="$(reason_of "$out")"
  st="${trailer#[}"; st="${st%]}"
  assert_contains "$r" "Task bd$n finished ($st)" "wait: '$trailer' delivers the task id and its status"
  assert_contains "$r" "out line 25" "wait: '$trailer' delivers the last output line"
  assert_contains "$r" "out line 6" "wait: '$trailer' delivers 20 lines (line 6 of 25 is the first)"
  case "$r" in *"out line 5"$'\n'*) echo "FAIL - wait: more than 20 lines delivered"; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) echo "ok   - wait: exactly the last 20 lines, never line 5" ;; esac
  case "$r" in *"[exited with code"*|*"[killed]"*) echo "FAIL - wait: the exit line leaked into the output lines"; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) echo "ok   - wait: the exit line itself is not repeated as output" ;; esac
done

# The .delivered record: a second stop of the same child does not get the same result again.
out="$(guard ag-done-1 "$T/empty.jsonl" true)"
assert_eq "$out" "" "wait: a result already handed over is not handed over again (.delivered)"
assert_eq "$(sed -n '1p' "$LEDGER/ag-done-1.delivered")" "bd1" "wait: the delivered id is recorded"

# Missing output file and no exit line: both fall to the re-block reason within the budget.
ledger_line ag-miss bm1 "$TASKS/never-created.output"
s0=$(date +%s); out="$(MAXS=2 guard ag-miss "$T/empty.jsonl")"; el=$(( $(date +%s) - s0 ))
r="$(reason_of "$out")"
assert_contains "$r" "still running: bm1" "missing output file: re-block names the task"
assert_contains "$r" "timeout: 3600000" "missing output file: re-block names the foreground re-run"
[ "$el" -le 1 ] && echo "ok   - missing output file: no wait at all (${el}s)" \
  || { echo "FAIL - missing output file waited ${el}s"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
ledger_line ag-run br1 "$(outfile br1 "")"
s0=$(date +%s); out="$(MAXS=2 guard ag-run "$T/empty.jsonl")"; el=$(( $(date +%s) - s0 ))
r="$(reason_of "$out")"
assert_contains "$r" "still running: br1" "no exit line by the deadline: re-block names the task"
assert_contains "$r" "until grep -Eq" "no exit line: the reason carries the until-loop poll on the task's file"
[ "$el" -ge 2 ] && [ "$el" -le 5 ] && echo "ok   - no exit line: held for the budget, then answered (${el}s)" \
  || { echo "FAIL - no exit line: held ${el}s against a 2s budget"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(govern::pending_bg_tasks_for ag-run "$T/empty.jsonl")" "br1" "a re-blocked task is still pending (never marked delivered)"

# The re-block fires even under stop_hook_active.
out="$(MAXS=0 guard ag-run "$T/empty.jsonl" true)"
assert_contains "$(reason_of "$out")" "still running: br1" "re-block: fires under stop_hook_active too"

# GOVERN_BG_WAIT_HOLD=0 still blocks, never holds.
s0=$(date +%s); out="$(HOLD=0 MAXS=30 guard ag-run "$T/empty.jsonl")"; el=$(( $(date +%s) - s0 ))
assert_contains "$(reason_of "$out")" "still running: br1" "HOLD=0: the stop is still blocked"
[ "$el" -le 2 ] && echo "ok   - HOLD=0: answered without holding (${el}s against a 30s budget)" \
  || { echo "FAIL - HOLD=0 held ${el}s"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# A real hold: the exit line lands 2s after the stop; the guard waits for it and delivers.
f="$(outfile bw1 "")"
ledger_line ag-wait bw1 "$f"
( sleep 2; printf 'last real line\n\n[exited with code 0]\n' >> "$f" ) &
wpid=$!
bg_reap "$wpid"
out="$(MAXS=20 guard ag-wait "$T/empty.jsonl")"
wait "$wpid" 2>/dev/null
assert_contains "$(reason_of "$out")" "last real line" "hold: a task that finishes during the hold is delivered with its output"

# Silent cases: a completion entry, a TaskStop, a watchdog denial, the knob off.
ledger_line ag-q bq1 "$(outfile bq1 "")"
notice bq1 > "$T/q1.jsonl"
assert_eq "$(MAXS=0 guard ag-q "$T/q1.jsonl")" "" "silent: the transcript already shows the completion"
stopped bq1 > "$T/q2.jsonl"
assert_eq "$(MAXS=0 guard ag-q "$T/q2.jsonl")" "" "silent: the child stopped the task"
denied > "$T/q3.jsonl"
s0=$(date +%s); out="$(MAXS=20 guard ag-q "$T/q3.jsonl")"; el=$(( $(date +%s) - s0 ))
assert_eq "$out" "" "silent: a watchdog-denied child is not blocked"
[ "$el" -le 1 ] && echo "ok   - watchdog denial: stands down before any wait (${el}s)" \
  || { echo "FAIL - watchdog denial still held ${el}s"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(KNOB=0 MAXS=0 guard ag-q "$T/empty.jsonl")" "" "silent: GOVERN_BG_WAIT_GUARD=0 turns the whole check off"
assert_contains "$(MAXS=0 guard ag-q "$T/empty.jsonl")" '"decision":"block"' "negative control: the same child with no closing entry IS blocked"

# TeammateIdle: the same reason, on stderr, exit 2.
MAXS=0 guard ag-q "$T/empty.jsonl" false TeammateIdle >/dev/null; rc=$?
assert_eq "$rc" "2" "TeammateIdle: a pending task exits 2"
assert_contains "$(cat "$T/stderr")" "still running: bq1" "TeammateIdle: the reason goes to stderr"
MAXS=0 guard ag-q "$T/q1.jsonl" false TeammateIdle >/dev/null; rc=$?
assert_eq "$rc" "0" "TeammateIdle: nothing pending exits 0 (negative control)"

assert_done
