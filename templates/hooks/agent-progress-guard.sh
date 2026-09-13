#!/usr/bin/env bash
# SubagentStop + TeammateIdle hook: apply the deterministic doom signature
# (govern::early_abort_reason in scripts/govern/lib/common.sh) to in-session `Agent`
# children, which have no pid and no external process for anything to poll. Three behaviors, plus
# the TeammateIdle branch below:
#
#   SCOPE — supervision spans every child, not only governor-spawned work. This is a
#            per-subagent frontmatter hook (worker.md/investigator.md/lookup.md `hooks:`) so it
#            fires for any subagent that carries it, reading `agent_transcript_path` on this
#            hook's stdin for the child's own turns.
#            NOT `transcript_path`: verified live (2026-09-10, claude 2.1.246) that on a
#            SubagentStop event `transcript_path` is the PARENT session's own transcript — reading
#            it would measure the driver's activity, not the child's. `agent_transcript_path` is
#            the child's, at `.../<session>/subagents/agent-<agent_id>.jsonl`.
#   PROGRESS, NOT LIVENESS — a repeated identical Bash command, or a long run of read-only turns
#            right before the child tries to stop, is the STALL/LOOP/ERROR signature
#            govern::early_abort_reason() detects, called from lib/common.sh rather than
#            reimplemented here.
#
#            THE STALL SIGNAL IS GATED TWICE HERE, and neither gate belongs in the shared function
#            (one needs the payload's agent_type, the other needs the filesystem, and that function
#            is a pure read of a transcript). Both close false positives that were costing real
#            work:
#              - a read-only agent type (lookup, investigator) is never stalled. Producing no diff
#                is what success looks like for it.
#              - the stall only stands if the WORKING TREE also failed to change. The transcript
#                signal counts Edit/Write/NotebookEdit tool_uses, and a child that changes files
#                through the shell emits none of them while converging perfectly. Classifying the
#                command text cannot fix that (whether a heredoc piped into an interpreter writes
#                anything is knowable only from the program inside it), so this asks the filesystem,
#                which no idiom can hide from. Unresolvable tree or a git failure means the check
#                cannot tell, and a check that cannot tell never denies.
#            LOOP and ERRORS are deliberately NOT gated: both are evidence of a child fighting its
#            own tools, which is true for every agent type and needs no filesystem to confirm.
#   A COMPLETION NOTIFICATION IS A CLAIM, not evidence. This fires at the moment a
#            subagent is ABOUT to stop, i.e. BEFORE whatever it is about to report reaches the
#            parent as a finished result. A doom signature at that boundary means the "I'm done"
#            (or "I'll wait for X to report back") the parent is about to receive is unearned:
#            block the stop and feed the signature back so the child either resolves it or is
#            forced to keep working until Claude Code's own stop-hook block cap (default 8x,
#            CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) ends the loop — never silently, and never via a
#            notification the parent has no way to check.
#
#   ONE EXCEPTION TO THE BLOCK, and it is a deadlock fix, not a softening: if the wall-clock
#   watchdog has already denied this child's tool calls, the child has been told to stop and report
#   and every tool it could use to answer a block is denied. Blocking its stop as well leaves it no
#   legal move, so the block is skipped in that case (the fleet-event alarm is still emitted). See
#   govern::watchdog_denied and the call site below.
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
# HARD CONSTRAINT: every signal is DETERMINISTIC, read straight off the child's OWN transcript. No
# model call anywhere in this path — an "agent hook" that asked a model whether the child looks
# stuck could itself hang or fabricate a verdict, which is exactly the failure class this is closing.
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
cwd="$(get cwd)"

# Per-agent state file for the working-tree fingerprint, in the SAME ${TMPDIR:-/tmp} per-key idiom
# router-posture-guard.sh uses for its session counters and agent-watchdog-guard.sh uses for its
# wall-clock start time. Not a new state mechanism, the existing one keyed on a new thing. The id is
# sanitized before it reaches a path for the same reason it is there: it is platform-issued in
# practice, never trusted into a path unescaped. Like its two siblings the file is never swept; it
# is a few bytes per child that the OS's own tmp cleanup reclaims.
safe_id="$(printf '%s' "${agent_id:-unknown}" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe_id" ] || safe_id="unknown"
fp_state="${TMPDIR:-/tmp}/metarepo-agent-progress-tree-${safe_id}"

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
  # STALL, and ONLY stall, passes two more gates before it may alarm or block. The loop and
  # tool-error-rate signatures are untouched: both are evidence of a child fighting its tools, which
  # is true for any agent type and needs no filesystem to confirm.
  case "$reason" in
    STALL:*)
      # GATE 1 — a read-only agent type is never stalled. A lookup or an investigator is not
      # supposed to produce a diff, so "no diff" is what SUCCESS looks like for it. Firing here cost
      # two findings reports in one day: both children spent their final message arguing they were
      # not stuck instead of delivering what they had found, and the findings were lost. agent_type
      # is on the payload already, the same field agent-watchdog-guard.sh keys its own scoping on.
      case ",${GOVERN_READONLY_AGENT_TYPES:-lookup,investigator}," in
        *",${agent_type},"*) exit 0 ;;
      esac
      # GATE 2 — did the working tree actually change? The transcript signal only knows about
      # Edit/Write/NotebookEdit tool_uses, and a child that changes files through the shell emits
      # none of them. Ask the filesystem instead: it is immune to command idiom, which no amount of
      # command-text classification can be.
      probe="$(govern::tree_probe "$cwd" 2>/dev/null || true)"
      # Unresolvable tree, no git, or a git failure: this check CANNOT TELL, so it must not be the
      # thing that denies a stop. Allow, and say nothing.
      [ -n "$probe" ] || exit 0
      fp="$(printf '%s\n' "$probe" | sed -n 1p)"
      dirty="$(printf '%s\n' "$probe" | sed -n 2p)"
      prev=""
      [ -f "$fp_state" ] && prev="$(cat "$fp_state" 2>/dev/null || true)"
      printf '%s' "$fp" > "$fp_state" 2>/dev/null || true
      if [ -n "$prev" ]; then
        # The tree moved between two looks. That is progress, whatever produced it.
        [ "$fp" != "$prev" ] && exit 0
      else
        # First look at this child, so there is no baseline to compare against. Uncommitted or
        # unpushed work on disk is the honest evidence that it has produced something, and absent a
        # baseline the fail-open direction is to believe it.
        [ "$dirty" = "1" ] && exit 0
      fi
      reason="$reason Its working tree has not changed either: nothing added, modified or newly committed since the last check."
      ;;
  esac
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
  # A wall-clock watchdog denial is TERMINAL: the child has already been told to stop and report,
  # and every further tool call it makes is denied. Blocking its stop on top of that leaves it with
  # no legal move at all — it cannot produce the diff the block asks for, and it cannot exit either.
  # So the alarm above still fires (an operator should see that this child both stalled and was
  # capped), but the reason is NOT returned, and with nothing returned the block below never runs.
  # Read off the same transcript this check already reads, no second channel.
  if command -v govern::watchdog_denied >/dev/null 2>&1 && govern::watchdog_denied "$transcript_path"; then
    exit 0
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
