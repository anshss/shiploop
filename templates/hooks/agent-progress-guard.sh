#!/usr/bin/env bash
# SubagentStop + TeammateIdle hook: reach the SAME deterministic doom signature the headless
# watchdog uses (govern::early_abort_reason in scripts/govern/lib/common.sh) to in-session `Agent`
# children, which have no pid and no worker.jsonl for that watchdog to see. Three behaviors, plus
# the TeammateIdle branch below:
#
#   SCOPE — supervision spans every child, not only governor-spawned PROCESSES. This is a
#            per-subagent frontmatter hook (worker.md/investigator.md/lookup.md `hooks:`) so it
#            fires for any subagent that carries it, on the SAME transcript shape spawn-worker.sh
#            already reads off a headless worker's worker.jsonl — `agent_transcript_path` on this
#            hook's stdin IS that shape, just for the child's own turns instead of a subprocess's.
#            NOT `transcript_path`: verified live (2026-09-10, claude 2.1.246) that on a
#            SubagentStop event `transcript_path` is the PARENT session's own transcript — reading
#            it would measure the driver's activity, not the child's. `agent_transcript_path` is
#            the child's, at `.../<session>/subagents/agent-<agent_id>.jsonl`.
#   PROGRESS, NOT LIVENESS — a repeated identical Bash command, or a long run of read-only turns
#            right before the child tries to stop, is the same STALL/LOOP/ERROR signature the
#            headless watchdog already detects: reused via govern::early_abort_reason(), never
#            reimplemented.
#   A COMPLETION NOTIFICATION IS A CLAIM, not evidence. This fires at the moment a
#            subagent is ABOUT to stop, i.e. BEFORE whatever it is about to report reaches the
#            parent as a finished result. A doom signature at that boundary means the "I'm done"
#            (or "I'll wait for X to report back") the parent is about to receive is unearned:
#            block the stop and feed the signature back so the child either resolves it or is
#            forced to keep working until Claude Code's own stop-hook block cap (default 8x,
#            CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) ends the loop — never silently, and never via a
#            notification the parent has no way to check.
#
# THE IDLE CASE, on TeammateIdle:
#   SubagentStop only fires when a child tries to STOP. A child that goes quiet WITHOUT stopping —
#   still running, mid-tool-call, or correctly blocked on a background task it must not poll —
#   never reaches SubagentStop at all, so the unearned-claim check above never runs for it. That
#   silence is not evidence of misconduct. A worker mid-suite-run, healthy
#   and 128 tests in, presents identically to one that is dead. So this hook now ALSO answers
#   `TeammateIdle` (fires when an agent-team teammate is about to go idle), running the SAME
#   `govern::early_abort_reason` check against the SAME kind of transcript. Two differences from
#   the SubagentStop path, both because idle is not a stop:
#     - this branch DELIBERATELY never blocks, and that is a design choice rather than a missing
#       lever. Do not "restore" blocking here on discovering that the event supports it. Blocking
#       idle would be exactly the wrong call: a worker correctly waiting on a
#       background task it must not poll emits the identical signal to a doomed one, so a block
#       punishes waiting correctly. The remedy for a genuinely stuck child is the advisor
#       establishing state from the repository itself, not holding a teammate open.
#       UNVERIFIED, and deliberately not relied upon either way: whether `TeammateIdle` accepts an
#       exit-2 / decision:block at all. Two sources checked on 2026-09-11 disagreed (one read the
#       docs as listing it blockable like `SubagentStop`, one as not in the blockable set), and
#       nothing here depends on the answer. `TeammateIdle` itself IS real and shipped: 16
#       occurrences in the installed 2.1.246 binary, against a 1542-hit control for the version
#       string, verified firsthand rather than relayed.
#     - the transcript field: the official docs describe `transcript_path` for this event, while
#       the SubagentStop path above needs `agent_transcript_path` (verified live 2026-09-10). The
#       try-both order below therefore covers the documented answer and the neighbouring verified
#       one. Still unverified against a real TeammateIdle payload (undocumented at
#       this level of detail as of this writing): try `agent_transcript_path` first (the
#       SubagentStop shape, in case the event is delivered to an observing parent), then fall back
#       to `transcript_path` (the teammate's own, in case it fires inside the idling session
#       itself) — same "absence of data is never evidence of doom" contract as everywhere else in
#       this script, so an unrecognized shape degrades to silent exit 0 rather than a wrong verdict.
#   The alarm is the whole remedy on this path: worker-prompt.md's doctrine (an idle notification
#   is a question, never a result) is what actually closes the idle case — this hook only gives
#   the advisor something to check against instead of nothing.
#
# SHIPS ON: GOVERN_AGENT_SUPERVISION defaults to 1, because an inert-by-default gate is the exact
# defect this guard exists to avoid. GOVERN_AGENT_SUPERVISION=0 is the kill switch, same
# idiom as GOVERN_EARLY_ABORT (root CLAUDE.md anti-pattern 12).
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
#      signature fires on the SubagentStop path, the block decision itself.
#   3. Absence of data is never evidence of doom (govern::early_abort_reason's own contract) — a
#      missing transcript_path, a missing common.sh, or a missing jq all degrade to silent exit 0.
set -uo pipefail

[ "${GOVERN_AGENT_SUPERVISION:-1}" = "1" ] || exit 0

# --- read the SubagentStop/TeammateIdle hook stdin payload ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

event_name="$(get hook_event_name)"
transcript_path="$(get agent_transcript_path)"
agent_id="$(get agent_id)"
agent_type="$(get agent_type)"

idle=0
if [ "$event_name" = "TeammateIdle" ]; then
  idle=1
  [ -n "$transcript_path" ] || transcript_path="$(get transcript_path)"
fi
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
  # not a second kill switch, it is the existing one. `signal=idle` on the TeammateIdle path is
  # the only thing that distinguishes it from a SubagentStop alarm in the log.
  if [ "$idle" = "1" ]; then
    { command -v govern::event >/dev/null 2>&1 && govern::event agent_progress_alarm \
      "agent_id=${agent_id:-unknown}" "agent_type=${agent_type:-unknown}" "reason=${reason}" \
      "signal=idle"; } || true
  else
    { command -v govern::event >/dev/null 2>&1 && govern::event agent_progress_alarm \
      "agent_id=${agent_id:-unknown}" "agent_type=${agent_type:-unknown}" "reason=${reason}"; } || true
  fi
  printf '%s' "$reason"
)" || true
[ -n "$result" ] || exit 0

# TeammateIdle cannot block (it is not a stop — there is nothing to hold open, and a worker
# correctly waiting on a background task must not be forced into "resolving" a signature it
# doesn't have). The fleet-event alarm above is the whole remedy on this path.
[ "$idle" = "1" ] && exit 0

esc="$(printf '%s' "$result" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"decision":"block","reason":"%s — this is a deterministic progress check, not a judgment call: address it directly (break the loop, land real progress, or state the actual blocker) rather than repeating the same stop."}\n' "$esc"
exit 0
