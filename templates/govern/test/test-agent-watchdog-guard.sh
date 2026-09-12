#!/usr/bin/env bash
# agent-watchdog-guard.sh: the PreToolUse hook porting the headless launcher's wall-clock watchdog
# to the interactive lane, alongside agent-progress-guard.sh (early-abort + idle supervision).
# There is deliberately no per-agent token-volume cap; the hook's own header says why.
#
# Covered here (the numbering has gaps where the token-cap cases were deleted with that rail):
#   1. DRIVER call (no agent_id) → silent no-op, never touched. The hard constraint: an
#      advisor/driver session's OWN tool calls must never be denied by this hook.
#   2. Subagent, FRESH wall-clock (first call, no prior state) → not blocked.
#   3. Subagent, STALE wall-clock (state file pre-seeded past the cap) → blocked, reason names
#      both the elapsed time and the knob to raise.
#   4. Wall-clock kill switch (GOVERN_AGENT_WALLCLOCK=0) on the SAME stale state → not blocked.
#   7. Under the cap → not blocked (a healthy child is never touched).
#   8. Missing transcript_path/session_id → silent no-op, no crash. Absence of data is never
#      evidence of doom.
#   10. A wall-clock deny emits the `watchdog-kill` lever event, with the headless lane's own event
#       name, reason string and field names.
#   12. GOVERN_LEVER_EVENTS=0 suppresses the event without suppressing the deny.
#   13. No lib/common.sh reachable → the deny still fires, nothing is emitted, nothing crashes.
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
out2="$(payload wc-fresh "$PROJ/s2.jsonl" s2 | env bash "$GUARD")"
assert_eq "$out2" "" "a subagent's FIRST tool call is never past the wall-clock cap"

# ── 3. Subagent, stale wall-clock — state file pre-seeded 4000s in the past (cap 3600s) ─────────
echo $(( $(date +%s) - 4000 )) > "$TMPDIR/metarepo-agent-watchdog-wallclock-wc-stale"
out3="$(payload wc-stale "$PROJ/s3.jsonl" s3 | env bash "$GUARD")"
assert_contains "$out3" '"permissionDecision":"deny"' "past the wall-clock cap → the next tool call is denied"
assert_contains "$out3" "GOVERN_AGENT_WALLCLOCK" "the deny reason names the knob to raise"
assert_contains "$out3" "wc-stale" "the deny reason identifies WHICH child tripped it"

# ── 4. Same stale state, kill switch GOVERN_AGENT_WALLCLOCK=0 ──────────────────────────────────
out4="$(payload wc-stale "$PROJ/s3.jsonl" s3 | env GOVERN_AGENT_WALLCLOCK=0 bash "$GUARD")"
assert_eq "$out4" "" "GOVERN_AGENT_WALLCLOCK=0 → not blocked even on the SAME stale state"

# ── 7. Under the cap — a healthy child is never touched ───────────────────────────────────────
mk_child_transcript "$PROJ" s7 wc-under 100
out7="$(payload wc-under "$PROJ/s7.jsonl" s7 | env bash "$GUARD")"
assert_eq "$out7" "" "fresh wall-clock → no output"

# ── 8. Minimal payload carrying no transcript_path/session_id ─────────────────────────────────
out8="$(printf '{"agent_id":"wc-nopath","agent_type":"worker","hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  | env bash "$GUARD")"
assert_eq "$out8" "" "no transcript_path/session_id on stdin → silent no-op, never a crash"

# ── 10, 12, 13. the `watchdog-kill` LEVER EVENT ───────────────────────────────────────────────
# The headless launcher emits this on every watchdog kill; this lane did not, so bench credited
# only half the fleet's kills and read the interactive half as "never fired" rather than
# "unmeasured". These exercise the hook's REAL code path (a payload in, the emitted file out), not
# a fixture of its output. GOVERN_LEVER_EVENTS is pinned 0 in assert.sh, so each case turns it on
# explicitly, which is also what makes case 12 a real kill-switch test rather than a tautology.
# ctxTokens/turns are read off the child's own transcript for the event's FIELDS only: this hook
# has no token ceiling, and the reading is never compared against one.
EV="$TMP/lever-events.jsonl"

# 10. wall-clock. Same event name and same reason string the headless lane uses for the same cap,
#     so the two lanes produce ONE stream a reader can group, not two dialects.
echo $(( $(date +%s) - 4000 )) > "$TMPDIR/metarepo-agent-watchdog-wallclock-wc-lever"
mk_child_transcript "$PROJ" s10 wc-lever 12000000
rm -f "$EV"
out10="$(payload wc-lever "$PROJ/s10.jsonl" s10 | env \
  GOVERN_LEVER_EVENTS=1 GOVERN_LEVER_EVENTS_FILE="$EV" bash "$GUARD")"
assert_contains "$out10" '"permissionDecision":"deny"' "the wall-clock deny still fires with events on"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "yes" "a wall-clock deny emits a lever event"
assert_contains "$(cat "$EV")" '"event":"watchdog-kill"' "under the SAME event name the headless watchdog uses"
assert_contains "$(cat "$EV")" '"reason":"wall-clock-timeout"' "and the same reason string for the same cap"
assert_contains "$(cat "$EV")" '"session":"worker"' "session names the transcript role, per the wire contract"
assert_contains "$(cat "$EV")" '"ticket":null' "ticket is an honest null: a hook sees an agent_id, never a ticket number"
assert_contains "$(cat "$EV")" '"lane":"interactive"' "and the lane is labelled so the two streams stay tellable apart"
assert_contains "$(cat "$EV")" '"ctxTokens":12000000' "ctxTokens is the measured total, as a JSON number"
assert_contains "$(cat "$EV")" '"turns":1' "and turns is counted off the child's own transcript"

# 12. the gate. GOVERN_LEVER_EVENTS=0 is honoured exactly as the headless path honours it.
rm -f "$EV"
out12="$(payload wc-lever "$PROJ/s10.jsonl" s10 | env \
  GOVERN_LEVER_EVENTS=0 GOVERN_LEVER_EVENTS_FILE="$EV" bash "$GUARD")"
assert_contains "$out12" '"permissionDecision":"deny"' "the deny is NOT gated on the emitter: supervision still works"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" "GOVERN_LEVER_EVENTS=0 → nothing is written at all"

# 13. FAIL OPEN. A hook runs in contexts where lib/common.sh is simply not there; a PreToolUse hook
#     that dies denies every later tool call in the session that installed it. Run a copy with no
#     library anywhere near it: the deny must still be produced, with no event and no crash.
ORPHAN="$TMP/orphan/hooks"; mkdir -p "$ORPHAN"
cp "$GUARD" "$ORPHAN/agent-watchdog-guard.sh"
echo $(( $(date +%s) - 4000 )) > "$TMPDIR/metarepo-agent-watchdog-wallclock-wc-orphan"
rm -f "$EV"
out13="$(payload wc-orphan "$PROJ/s13.jsonl" s13 | env \
  GOVERN_LEVER_EVENTS=1 GOVERN_LEVER_EVENTS_FILE="$EV" bash "$ORPHAN/agent-watchdog-guard.sh")"
assert_contains "$out13" '"permissionDecision":"deny"' "no common.sh reachable → the hook still denies, never breaks"
assert_eq "$([ -f "$EV" ] && echo yes || echo no)" "no" "and emits nothing, rather than half a row or an error"

assert_done
