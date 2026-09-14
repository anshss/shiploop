#!/usr/bin/env bash
# Fleet event emitter for a subagent's own lifecycle: `worker_spawned` and `worker_done` into
# governor/events.jsonl (govern::event in scripts/govern/lib/common.sh, gated on GOVERN_EVENTS=1
# the same as every other row in that log). status.sh, statusline-segment.sh and
# tools/fleet-monitor.sh fold this stream to answer "what is the fleet doing right now": before
# this hook existed, nothing wrote either event type, so none of the three could ever show a
# worker that is actually running.
#
# KEYED ON THE SUBAGENT'S OWN IDENTITY, not a ticket. An in-session `Agent` child is a sidechain
# inside the SAME running `claude` process, not a separate OS process. It has no pid to carry, and
# a hook has no channel back to the ticket number a worker is handed only inside its own prompt (the
# same constraint agent-watchdog-guard.sh's `watchdog-kill` event already accepts: an honest null is
# better than a guess). `agent_id` and `agent_type` are the fields a hook payload actually carries;
# they ride where `pid` used to, and every reader now folds and displays by agent_id.
#
# THREE EVENTS, ONE SCRIPT, branching on `hook_event_name`:
#   - `SubagentStart`: documented as firing once when a subagent is spawned (fires "when a subagent
#     is spawned", https://code.claude.com/docs/en/hooks). The installed CLI's own binary carries
#     the string at a count in the same order of magnitude as `SubagentStop` and `TeammateIdle`
#     (both already relied on elsewhere in this repo's hooks), checked directly against the running
#     `claude` binary rather than assumed. This script has NOT been verified against a live
#     SubagentStart payload the way agent-watchdog-guard.sh verified PreToolUse's `agent_id` field
#     (spawn a real subagent, diff the payload): only the docs and the binary string count are in
#     hand. The PreToolUse fallback below exists precisely because of that gap: if the event never
#     actually fires on some installed CLI version, the fallback still produces the row.
#   - `PreToolUse`: fires on every tool call a subagent makes (matcher `*`, alongside
#     agent-watchdog-guard.sh and advisor-steer-guard.sh). A spawn marker file, written the first
#     time either path emits for a given `agent_id`, makes the two paths idempotent together: if
#     SubagentStart already recorded the spawn, PreToolUse's own check is a single `-f` stat and a
#     no-op; if SubagentStart never fires, PreToolUse's first call for that `agent_id` emits instead.
#     Either way, one spawn produces exactly one `worker_spawned` row.
#   - `SubagentStop`: emits `worker_done`. Skipped when `stop_hook_active` is true: that flag means
#     THIS stop attempt is a retry after a previous one was blocked (agent-progress-guard.sh, the
#     other hook registered on the same event, can deny a stop on a doom signature), and emitting
#     again on every retry would pile up duplicate rows for one real completion. Emitting on the
#     FIRST attempt, before this script can know whether that attempt gets blocked, is a real but
#     narrow inaccuracy: a worker that gets blocked and keeps working can show as briefly "done"
#     until its actual final stop closes the row again (a duplicate `worker_done` on the same
#     `agent_id` is harmless, since the fold is last-event-wins and both say "done"). No hook can see
#     another hook's decision on the same event, so this is the best any single hook can do; the
#     staleness fallback in status.sh's own age bound is what a reader leans on when a row never
#     gets a real completion at all.
#
# GOVERN_EVENTS gate checked FIRST, before sourcing common.sh, so the common (off) case costs one
# env read rather than paying to source a 4000-line library on every subagent tool call.
#
# HARD CONSTRAINT, same as every other hook here: never abort the caller. The whole body degrades
# to a silent no-op on a missing common.sh, a missing agent_id, or any parse failure.
set -uo pipefail

[ "${GOVERN_EVENTS:-0}" = "1" ] || exit 0

payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

agent_id="$(get agent_id)"
[ -n "$agent_id" ] || exit 0   # no agent_id → the driver/advisor's own call, never touch it

agent_type="$(get agent_type)"
event_name="$(get hook_event_name)"

# Sanitize for filename use, same idiom agent-watchdog-guard.sh and agent-progress-guard.sh already
# apply to this exact field for the exact same reason: an agent_id is platform-issued in practice,
# never trusted into a path unescaped.
safe_id="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe_id" ] || safe_id="unknown"
spawn_marker="${TMPDIR:-/tmp}/metarepo-worker-event-spawned-${safe_id}"

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

emit() { # <type> [k=v ...] -- reaches govern::event the same defensive way every sibling hook does
  (
    source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
      || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
    command -v govern::event >/dev/null 2>&1 || exit 0
    govern::event "$@"
  ) >/dev/null 2>&1 || true
  return 0
}

emit_spawn_once() {
  [ -f "$spawn_marker" ] && return 0
  : > "$spawn_marker" 2>/dev/null || true
  emit worker_spawned agent_id="$agent_id" agent_type="${agent_type:-unknown}"
  return 0
}

case "$event_name" in
  SubagentStart)
    emit_spawn_once
    ;;
  PreToolUse)
    # The fallback path: only fires when SubagentStart never recorded this agent_id, and the check
    # above is already a single -f stat, so this costs nothing extra on the common (already-marked)
    # case.
    emit_spawn_once
    ;;
  SubagentStop)
    case "$payload" in
      *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
    esac
    emit worker_done agent_id="$agent_id" agent_type="${agent_type:-unknown}" status=stopped
    ;;
esac

exit 0
