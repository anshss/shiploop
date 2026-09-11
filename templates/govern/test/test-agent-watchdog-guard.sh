#!/usr/bin/env bash
# agent-watchdog-guard.sh — the PreToolUse hook porting the headless launcher's remaining two
# watchdogs (wall-clock, token budget) to the interactive lane. D10 of
# .specs/2026-09-11-advisor-worker-design.md, closing blocker 4 of G12's launcher-retirement list
# alongside agent-progress-guard.sh (early-abort + D8's idle supervision).
#
# Covered here:
#   1. DRIVER call (no agent_id) → silent no-op, never touched — the hard constraint: an
#      advisor/driver session's OWN tool calls must never be denied by this hook.
#   2. Subagent, FRESH wall-clock (first call, no prior state) → not blocked.
#   3. Subagent, STALE wall-clock (state file pre-seeded past the cap) → blocked, reason names
#      both the elapsed time and the knob to raise.
#   4. Wall-clock kill switch (GOVERN_AGENT_WALLCLOCK=0) on the SAME stale state → not blocked.
#   5. Token budget exceeded (child's own derived transcript over the cap) → blocked.
#   6. Token budget kill switch (GOVERN_AGENT_TOKEN_BUDGET=0) on the SAME transcript → not blocked.
#   7. Under both caps → not blocked (a healthy child is never touched).
#   8. Missing transcript_path/session_id (token check has nothing to derive a path from) →
#      silent no-op, no crash — absence of data is never evidence of doom.
#   9. The child's own derived transcript file does not exist yet (too early in its life for the
#      platform to have flushed a turn) → silent no-op, no crash.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Two layouts (#255): scripts/agent-watchdog-guard.sh in a scaffolded workspace,
# templates/hooks/agent-watchdog-guard.sh in the hub repo.
GUARD="$GOVERN_HOOKS_DIR/agent-watchdog-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: agent-watchdog-guard.sh not found under $GOVERN_HOOKS_DIR"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"   # isolate the wall-clock state files from the real /tmp
mk_ws_stub "$TMP/ws"   # exports GOVERN_WS_ROOT so the guard's common.sh source resolves hermetically

# payload <agent_id|""> <transcript_path> <session_id>
payload() {
  local agent_id="$1" transcript="$2" session_id="$3"
  if [ -n "$agent_id" ]; then
    printf '{"session_id":"%s","transcript_path":"%s","agent_id":"%s","agent_type":"worker","hook_event_name":"PreToolUse","tool_name":"Bash"}' \
      "$session_id" "$transcript" "$agent_id"
  else
    printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"PreToolUse","tool_name":"Bash"}' \
      "$session_id" "$transcript"
  fi
}

# mk_child_transcript <session_dir> <session_id> <agent_id> <total_tokens>
# Writes ONE assistant event carrying $total_tokens as input_tokens, at the exact path this hook
# derives: <dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.jsonl — confirmed
# live against a real spawned subagent (see the hook's own header for the verification).
mk_child_transcript() {
  local proj="$1" session_id="$2" agent_id="$3" tokens="$4"
  local dir="$proj/$session_id/subagents"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"output_tokens":0}}}\n' "$tokens" \
    > "$dir/agent-${agent_id}.jsonl"
}

PROJ="$TMP/proj"; mkdir -p "$PROJ"

# ── 1. DRIVER call — no agent_id at all ─────────────────────────────────────────────────────────
out1="$(payload "" "$PROJ/s1.jsonl" s1 | env bash "$GUARD")"
assert_eq "$out1" "" "no agent_id (the driver's own call) → never touched, no output"

# ── 2. Subagent, fresh wall-clock — first call ever seen for this agent_id ─────────────────────
out2="$(payload wc-fresh "$PROJ/s2.jsonl" s2 | env GOVERN_AGENT_TOKEN_BUDGET=0 bash "$GUARD")"
assert_eq "$out2" "" "a subagent's FIRST tool call is never past the wall-clock cap"

# ── 3. Subagent, stale wall-clock — state file pre-seeded 4000s in the past (cap 3600s) ─────────
echo $(( $(date +%s) - 4000 )) > "$TMPDIR/metarepo-agent-watchdog-wallclock-wc-stale"
out3="$(payload wc-stale "$PROJ/s3.jsonl" s3 | env GOVERN_AGENT_TOKEN_BUDGET=0 bash "$GUARD")"
assert_contains "$out3" '"permissionDecision":"deny"' "past the wall-clock cap → the next tool call is denied"
assert_contains "$out3" "GOVERN_AGENT_WALLCLOCK" "the deny reason names the knob to raise"
assert_contains "$out3" "wc-stale" "the deny reason identifies WHICH child tripped it"

# ── 4. Same stale state, kill switch GOVERN_AGENT_WALLCLOCK=0 ──────────────────────────────────
out4="$(payload wc-stale "$PROJ/s3.jsonl" s3 | env GOVERN_AGENT_WALLCLOCK=0 GOVERN_AGENT_TOKEN_BUDGET=0 bash "$GUARD")"
assert_eq "$out4" "" "GOVERN_AGENT_WALLCLOCK=0 → not blocked even on the SAME stale state"

# ── 5. Token budget exceeded — child's derived transcript carries more than the cap ─────────────
mk_child_transcript "$PROJ" s5 tok-over 12000000
out5="$(payload tok-over "$PROJ/s5.jsonl" s5 | env GOVERN_AGENT_WALLCLOCK=0 GOVERN_AGENT_TOKEN_BUDGET=10000000 bash "$GUARD")"
assert_contains "$out5" '"permissionDecision":"deny"' "past the token cap → the next tool call is denied"
assert_contains "$out5" "GOVERN_AGENT_TOKEN_BUDGET" "the deny reason names the knob to raise"
assert_contains "$out5" "12000000" "the deny reason reports the measured token total"

# ── 6. Same transcript, kill switch GOVERN_AGENT_TOKEN_BUDGET=0 ─────────────────────────────────
out6="$(payload tok-over "$PROJ/s5.jsonl" s5 | env GOVERN_AGENT_WALLCLOCK=0 GOVERN_AGENT_TOKEN_BUDGET=0 bash "$GUARD")"
assert_eq "$out6" "" "GOVERN_AGENT_TOKEN_BUDGET=0 → not blocked even on the SAME over-budget transcript"

# ── 7. Under both caps — a healthy child is never touched ───────────────────────────────────────
mk_child_transcript "$PROJ" s7 tok-under 100
out7="$(payload tok-under "$PROJ/s7.jsonl" s7 | env GOVERN_AGENT_TOKEN_BUDGET=10000000 bash "$GUARD")"
assert_eq "$out7" "" "fresh wall-clock + under the token cap → no output"

# ── 8. Missing transcript_path/session_id → token check has nothing to derive a path from ──────
out8="$(printf '{"agent_id":"tok-nopath","agent_type":"worker","hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  | env GOVERN_AGENT_TOKEN_BUDGET=10000000 bash "$GUARD")"
assert_eq "$out8" "" "no transcript_path/session_id on stdin → silent no-op, never a crash"

# ── 9. Child's own derived transcript file does not exist yet ──────────────────────────────────
# No mk_child_transcript call for this agent_id: the platform hasn't flushed a turn to
# .../subagents/agent-tok-nofile.jsonl yet, so the `[ -f "$child_transcript" ]` guard should skip
# the check entirely rather than treating "no file" as "0 tokens, definitely under budget" (which
# would happen to read the same either way here, but the CODE PATH under test is the file-missing
# branch, not a coincidental zero).
out9="$(payload tok-nofile "$PROJ/s9.jsonl" s9 | env GOVERN_AGENT_TOKEN_BUDGET=10000000 bash "$GUARD")"
assert_eq "$out9" "" "no transcript file yet for this child → silent no-op, never a crash"

assert_done
