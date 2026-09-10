#!/usr/bin/env bash
# SubagentStop hook: reach the SAME deterministic doom signature the headless watchdog uses
# (govern::early_abort_reason in scripts/govern/lib/common.sh) to in-session `Agent` children,
# which have no pid and no worker.jsonl for that watchdog to see. Closes #116 — rails 6-8 of
# .specs/2026-09-09-model-orchestration-design.md:
#
#   RAIL 6 — supervision spans every child, not only governor-spawned PROCESSES. This is a
#            per-subagent frontmatter hook (worker.md/investigator.md/lookup.md `hooks:`) so it
#            fires for any subagent that carries it, on the SAME transcript shape spawn-worker.sh
#            already reads off a headless worker's worker.jsonl — `agent_transcript_path` on this
#            hook's stdin IS that shape, just for the child's own turns instead of a subprocess's.
#            NOT `transcript_path`: verified live (2026-09-10, claude 2.1.246) that on a
#            SubagentStop event `transcript_path` is the PARENT session's own transcript — reading
#            it would measure the driver's activity, not the child's. `agent_transcript_path` is
#            the child's, at `.../<session>/subagents/agent-<agent_id>.jsonl`.
#   RAIL 7 — progress, not liveness. A repeated identical Bash command, or a long run of
#            read-only turns right before the child tries to stop, is the same STALL/LOOP/ERROR
#            signature §4.4a already detects — reused via govern::early_abort_reason(), never
#            reimplemented.
#   RAIL 8 — a completion notification is a CLAIM, not evidence. This fires at the moment a
#            subagent is ABOUT to stop, i.e. BEFORE whatever it is about to report reaches the
#            parent as a finished result. A doom signature at that boundary means the "I'm done"
#            (or "I'll wait for X to report back") the parent is about to receive is unearned:
#            block the stop and feed the signature back so the child either resolves it or is
#            forced to keep working until Claude Code's own stop-hook block cap (default 8x,
#            CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) ends the loop — never silently, and never via a
#            notification the parent has no way to check.
#
# SHIPS INERT: GOVERN_AGENT_SUPERVISION defaults to 0, same idiom as GOVERN_EARLY_ABORT (root
# CLAUDE.md anti-pattern 12) — this hook is reachable from every subagent that carries it, in
# every session, so a workspace that has not opted in must see zero behavior change.
#
# HARD CONSTRAINT unchanged from spawn-worker.sh's watchdog: every signal is DETERMINISTIC, read
# straight off the child's OWN transcript. No model call anywhere in this path — an "agent hook"
# that asked a model whether the child looks stuck could itself hang or fabricate a verdict,
# which is exactly the failure class this is closing.
#
# Design constraints (a Stop-family hook that always blocks would loop forever):
#   1. Honor stop_hook_active — never add a THIRD loop turn on top of Claude Code's own cap.
#   2. Read-only against the transcript; the only side effect is an OPTIONAL fleet event (gated
#      independently by GOVERN_EVENTS, same as every other govern::event call) and, when a doom
#      signature fires, the block decision itself.
#   3. Absence of data is never evidence of doom (govern::early_abort_reason's own contract) — a
#      missing transcript_path, a missing common.sh, or a missing jq all degrade to silent exit 0.
set -uo pipefail

[ "${GOVERN_AGENT_SUPERVISION:-0}" = "1" ] || exit 0

# --- read the SubagentStop hook stdin payload ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

transcript_path="$(get agent_transcript_path)"
agent_id="$(get agent_id)"
agent_type="$(get agent_type)"
[ -n "$transcript_path" ] || exit 0

# --- reach govern::early_abort_reason() the same way ticket-sweep-reminder.sh reaches
# govern::is_validation_ticket(): source common.sh defensively so a missing workspace config
# (bare checkout, hermetic test with no stub) degrades to a silent no-op rather than an error a
# subagent would have to explain. SELF_ROOT mirrors ticket-sweep-reminder.sh exactly: this script
# installs to scripts/ (workspace) or lives at templates/hooks/ (hub repo / hermetic tests). ---
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

result="$(
  source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
    || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
  command -v govern::early_abort_reason >/dev/null 2>&1 || exit 0
  reason="$(govern::early_abort_reason "$transcript_path")"
  [ -n "$reason" ] || exit 0
  # Surfaced via the fleet event log (governor/events.jsonl) BEFORE the block decision below, so
  # an operator watching fleet-monitor.sh sees the alarm even on a session that never re-prompts
  # (e.g. the child's stop is force-ended by Claude Code's own block cap without ever resolving
  # it). Gated independently by GOVERN_EVENTS, same as every other govern::event call — this is
  # not a second kill switch, it is the existing one.
  { command -v govern::event >/dev/null 2>&1 && govern::event agent_progress_alarm \
    "agent_id=${agent_id:-unknown}" "agent_type=${agent_type:-unknown}" "reason=${reason}"; } || true
  printf '%s' "$reason"
)" || true
[ -n "$result" ] || exit 0

esc="$(printf '%s' "$result" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"decision":"block","reason":"%s — this is a deterministic progress check, not a judgment call: address it directly (break the loop, land real progress, or state the actual blocker) rather than repeating the same stop."}\n' "$esc"
exit 0
