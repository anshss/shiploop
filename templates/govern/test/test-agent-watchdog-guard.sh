#!/usr/bin/env bash
# agent-watchdog-guard.sh: the PreToolUse hook porting the headless launcher's wall-clock
# watchdog to the interactive lane, alongside agent-progress-guard.sh (early-abort + idle
# supervision). There is no per-agent token-volume rail: the hook's own header says why.
#
# Covered here (numbering has gaps where the token-budget cases were deleted with that rail):
#   1. DRIVER call (no agent_id) → silent no-op, never touched. The hard constraint: an
#      advisor/driver session's OWN tool calls must never be denied by this hook.
#   2. Subagent, FRESH wall-clock (first call, no prior state) → not blocked.
#   3. Subagent, STALE wall-clock (state file pre-seeded past the cap) → blocked, reason names
#      both the elapsed time and the knob to raise.
#   4. Wall-clock kill switch (GOVERN_AGENT_WALLCLOCK=0) on the SAME stale state → not blocked.
#   7. Under the cap → not blocked (a healthy child is never touched).
#   8. Minimal payload carrying no transcript_path/session_id → silent no-op, no crash.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Two layouts (#255): scripts/agent-watchdog-guard.sh in a scaffolded workspace,
# templates/hooks/agent-watchdog-guard.sh in the hub repo.
GUARD="$GOVERN_HOOKS_DIR/agent-watchdog-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: agent-watchdog-guard.sh not found under $GOVERN_HOOKS_DIR"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/tmp"; mkdir -p "$TMPDIR"   # isolate the wall-clock state files from the real /tmp

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

# ── 7. Under the cap — a healthy child is never touched ────────────────────────────────────────
out7="$(payload wc-under "$PROJ/s7.jsonl" s7 | env bash "$GUARD")"
assert_eq "$out7" "" "fresh wall-clock → no output"

# ── 8. Minimal payload with no transcript_path/session_id ──────────────────────────────────────
out8="$(printf '{"agent_id":"wc-nopath","agent_type":"worker","hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  | env bash "$GUARD")"
assert_eq "$out8" "" "no transcript_path/session_id on stdin → silent no-op, never a crash"

assert_done
