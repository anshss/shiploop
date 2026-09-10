#!/usr/bin/env bash
# agent-progress-guard.sh — the SubagentStop hook that reaches spawn-worker.sh's §4.4a doom
# signature (govern::early_abort_reason in lib/common.sh) to in-session `Agent` children, which
# have no pid and no worker.jsonl for that watchdog to see. Closes #116, rails 6-8 of
# .specs/2026-09-09-model-orchestration-design.md.
#
# Covered here:
#   1. STALL    — many read-only turns right before the child tries to stop → blocked, surfaced
#                 as a fleet event
#   2. LOOP     — the same Bash command repeated identically → blocked, quotes the command
#   3. HEALTHY  — edits throughout, same turn count → NOT blocked, no event
#   4. INERT    — GOVERN_AGENT_SUPERVISION unset (default 0), on the SAME doomed transcript →
#                 no block, no event: the mechanism ships OFF
#   5. RE-ENTRANCY — stop_hook_active:true on a doomed transcript → no block (never adds a THIRD
#                    loop turn on top of Claude Code's own stop-hook block cap)
#   6. MISSING agent_transcript_path → no block, no crash
#   7. SAME SIGNAL, both callers — the STALL reason text this hook emits for a transcript is
#      byte-identical to what spawn-worker.sh's watchdog emits for the SAME transcript shape,
#      because both call govern::early_abort_reason() rather than each having their own copy.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

# Two layouts (#255): scripts/agent-progress-guard.sh in a scaffolded workspace,
# templates/hooks/agent-progress-guard.sh in the hub repo. GOVERN_HOOKS_DIR (from assert.sh)
# resolves whichever one we're in.
GUARD="$GOVERN_HOOKS_DIR/agent-progress-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: agent-progress-guard.sh not found under $GOVERN_HOOKS_DIR"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # exports GOVERN_WS_ROOT so the guard's common.sh source resolves hermetically

# STALL transcript: 40 assistant turns, all Read, zero file mutations — same shape
# test-spawn-early-abort.sh uses for a headless worker.jsonl.
gen_stall() {
  for i in $(seq 1 40); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_stall > "$TMP/stall.jsonl"

# HEALTHY transcript: same turn count, edits interleaved throughout.
gen_healthy() {
  for i in $(seq 1 40); do
    if (( i % 3 == 0 )); then name=Edit; else name=Read; fi
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n' "$name"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_healthy > "$TMP/healthy.jsonl"

# LOOP transcript: 6 turns, the SAME Bash command every time, edits interleaved so STALL can
# never be what fires — isolates the loop detector, same idiom as test-spawn-early-abort.sh.
gen_loop() {
  for i in $(seq 1 6); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test -- --run flaky"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_loop > "$TMP/loop.jsonl"

# run_guard <transcript> <agent_id> <stop_hook_active> [extra env assignments...]
#
# Field is agent_transcript_path, NOT transcript_path: verified live (2026-09-10, claude 2.1.246)
# that on a real SubagentStop event, `transcript_path` is the PARENT session's own transcript —
# `agent_transcript_path` is the child's. This fixture mirrors the real payload shape exactly (it
# also carries a `transcript_path` pointing somewhere else, to catch a regression that reads the
# wrong field back).
run_guard() {
  local transcript="$1" agent_id="$2" active="$3"; shift 3
  printf '{"session_id":"s-%s","cwd":"%s","transcript_path":"%s/PARENT-not-the-childs.jsonl","agent_transcript_path":"%s","agent_id":"%s","agent_type":"general-purpose","stop_hook_active":%s}' \
      "$agent_id" "$TMP" "$TMP" "$transcript" "$agent_id" "$active" \
    | env "$@" bash "$GUARD"
}

# ── 1. STALL, supervision ON ───────────────────────────────────────────────────────────────────
events1="$TMP/events-1.jsonl"
out1="$(run_guard "$TMP/stall.jsonl" a1 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events1")"
assert_contains "$out1" '"decision":"block"' "STALL on a subagent about to stop → the stop is blocked"
assert_contains "$out1" "STALL" "the block reason carries the deterministic signature that fired"
assert_contains "$(cat "$events1" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "STALL is surfaced as a fleet event — an operator watching fleet-monitor.sh sees it without opening a transcript"
assert_contains "$(cat "$events1" 2>/dev/null || true)" '"agent_id":"a1"' \
  "the event identifies WHICH subagent instance alarmed"

# ── 2. LOOP, supervision ON ─────────────────────────────────────────────────────────────────────
out2="$(run_guard "$TMP/loop.jsonl" a2 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EARLY_ABORT_REPEATS=5)"
assert_contains "$out2" '"decision":"block"' "an identically-repeated command → blocked"
assert_contains "$out2" "LOOP" "the loop signature is the one reported, not the stall one"
assert_contains "$out2" "npm test" "the block reason quotes the repeated command"

# ── 3. HEALTHY, supervision ON — must NOT fire ─────────────────────────────────────────────────
events3="$TMP/events-3.jsonl"
out3="$(run_guard "$TMP/healthy.jsonl" a3 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events3")"
assert_eq "$out3" "" "a subagent editing files throughout is NOT blocked, at the same turn count"
[ -s "$events3" ] && has3=yes || has3=no
assert_eq "$has3" "no" "no fleet event for a healthy stop"

# ── 4. INERT BY DEFAULT — the SAME doomed transcript, GOVERN_AGENT_SUPERVISION unset ───────────
events4="$TMP/events-4.jsonl"
out4="$(run_guard "$TMP/stall.jsonl" a4 false GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events4")"
assert_eq "$out4" "" "GOVERN_AGENT_SUPERVISION unset (default 0) → the doomed subagent is NOT blocked"
[ -s "$events4" ] && has4=yes || has4=no
assert_eq "$has4" "no" "default-off emits no fleet event either — the mechanism ships fully inert"

# ── 5. RE-ENTRANCY — stop_hook_active:true on the same doomed transcript ───────────────────────
out5="$(run_guard "$TMP/stall.jsonl" a5 true GOVERN_AGENT_SUPERVISION=1)"
assert_eq "$out5" "" "stop_hook_active:true → never re-fires a block on top of Claude Code's own cap"

# ── 6. MISSING agent_transcript_path → no crash, no block ─────────────────────────────────────
out6="$(printf '{"session_id":"s6","cwd":"%s","agent_id":"a6","agent_type":"lookup","stop_hook_active":false}' "$TMP" \
  | env GOVERN_AGENT_SUPERVISION=1 bash "$GUARD")"
assert_eq "$out6" "" "no agent_transcript_path on stdin → silent no-op, never a crash"

# ── 7. ONE implementation, two callers — same doom signature, same wording ─────────────────────
# spawn-worker.sh's own watchdog reads govern::early_abort_reason() out of the SAME lib/common.sh
# this hook sources; drive it directly (bypassing the process-watchdog polling loop, which needs a
# live claude subprocess) and compare its verdict on the STALL transcript to the hook's.
SPAWN_DIR="$(dirname "$GUARD")"
common="$SPAWN_DIR/govern/lib/common.sh"; [ -f "$common" ] || common="$SPAWN_DIR/../govern/lib/common.sh"
if [ -f "$common" ]; then
  direct="$(GOVERN_WS_ROOT="$TMP" bash -c '. "'"$common"'" && govern::early_abort_reason "'"$TMP"'/stall.jsonl"')"
  assert_contains "$out1" "$direct" \
    "the hook's block reason is the SAME string spawn-worker.sh's watchdog would compute — one signature, not two that can drift"
fi

assert_done
