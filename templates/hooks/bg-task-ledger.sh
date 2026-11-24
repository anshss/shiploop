#!/usr/bin/env bash
# PostToolUse hook (matcher Bash|Monitor), subagent calls only: records every background task a
# child starts, at the moment the tool returns, in governor/.bg-ledger/<agent_id>.tsv. One line per
# launch:
#   <epoch>\t<task_id>\t<bash|monitor>\t<output_file>
# agent-progress-guard.sh reads it (through govern::pending_bg_tasks_for in lib/common.sh) when the
# child tries to stop, so a launch made in the same turn as the stop is already on disk. A
# transcript read at that moment can miss it: the transcript may not yet hold the current turn.
#
# What counts as a launch, from the tool_response Claude Code hands this hook (verified live):
#   - Bash with run_in_background, and a Bash moved to the background when it hit its timeout:
#     tool_response.backgroundTaskId (the second also carries timedOutAfterMs).
#   - Monitor: tool_response.taskId.
# A foreground Bash that finished carries neither and is ignored.
#
# The output file is not in the payload. Claude Code writes it under its own temp root as
# claude-<uid>/<project-slug>/<session_id>/tasks/<task_id>.output, so it is looked up there by
# session id and task id. That layout is an undocumented internal: when no such file is found the
# line is still written with an empty output file, and the guard then tells the child to wait in its
# turn instead of waiting for it.
#
# A tool call with no agent_id is the driver's own and is never recorded. GOVERN_BG_LEDGER=0 turns
# the hook off. Never blocks, never fails the call: every degenerate input exits 0 silently.
set -uo pipefail

[ "${GOVERN_BG_LEDGER:-1}" = "1" ] || exit 0

payload="$(cat 2>/dev/null || true)"
# Cheap string filter before jq: this hook fires on every Bash call a subagent makes.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
case "$payload" in *'"backgroundTaskId"'*|*'"taskId"'*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

fields="$(printf '%s' "$payload" | jq -r '
  (.tool_response | objects) as $r
  | [ (.agent_id // ""), (.tool_name // ""),
      (if .tool_name == "Monitor" then ($r.taskId // "") else ($r.backgroundTaskId // "") end),
      (.session_id // "") ] | @tsv' 2>/dev/null || true)"
[ -n "$fields" ] || exit 0
IFS=$'\t' read -r agent_id tool_name task_id session_id <<< "$fields"
[ -n "$agent_id" ] && [ -n "$task_id" ] || exit 0
case "$task_id" in (*[!A-Za-z0-9_-]*) exit 0 ;; esac
kind="bash"
[ "$tool_name" = "Monitor" ] && kind="monitor"

output_file=""
if [ -n "$session_id" ]; then
  case "$session_id" in (*[!A-Za-z0-9_-]*) session_id="" ;; esac
fi
if [ -n "$session_id" ]; then
  uid="$(id -u 2>/dev/null || true)"
  for base in "${CLAUDE_CODE_TMPDIR:-}" /tmp /private/tmp "${TMPDIR:-}"; do
    [ -n "$base" ] && [ -d "${base%/}/claude-$uid" ] || continue
    for f in "${base%/}/claude-$uid"/*/"$session_id"/tasks/"$task_id".output; do
      [ -f "$f" ] && { output_file="$f"; break 2; }
    done
  done
fi

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${GOVERN_WS_ROOT:-$SELF_ROOT}"
dir="$root/governor/.bg-ledger"
safe_id="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe_id" ] || exit 0
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$task_id" "$kind" "$output_file" >> "$dir/$safe_id.tsv" 2>/dev/null || true
exit 0
