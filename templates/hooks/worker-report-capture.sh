#!/usr/bin/env bash
# SubagentStop hook: when a worker subagent stops, write its structured report to
# governor/reports/<N>.json at the workspace root, one file per ticket number it was dispatched on,
# so `govern:resolve -- <N>` can land it without anyone copying the JSON by hand.
#
# Which child: a worker type ("worker", or "worker-retry", the same worker on its one retry) as
# agent_type on the payload, or, for a named teammate (whose payload type can be its name), that
# same type as the customAgentType/spawnedAgentType recorded in the transcript's own
# agent-<id>.meta.json. Every other child is ignored.

# A worker is any of the worker types: `worker` for a first attempt, `worker-retry` for the one
# retry on the family's top model. Same doctrine, same body, two names.
is_worker_type() { case "$1" in worker|worker-retry) return 0 ;; *) return 1 ;; esac; }
#
# Where the report comes from, first hit wins:
#   1. a SubagentHandback tool call in the child's transcript: its input.message;
#   2. the payload's last_assistant_message;
#   3. the last assistant text in agent_transcript_path (the transcript can lag the current turn,
#      which is why it comes last).
# Each candidate must parse as a contract report (govern::extract_report) whose status is resolved,
# parked or failed. Prose, or JSON without such a status, is skipped and nothing is written.
#
# Which N: the ticket numbers come from the child's spawn prompt (the first user entry in its
# transcript). A dispatch packet path named there wins: its `## Ticket #N` headings list the batch.
# Without one, the `#N` tokens on the prompt's first line are used, "PR #N" excluded. No number,
# no write.
#
# Each later stop of the same child overwrites the file, so the last report it gives is the one on
# disk. GOVERN_REPORT_CAPTURE=0 turns the hook off. Never blocks: every degenerate input (no jq, no
# common.sh, no transcript) exits 0 silently.
#
# The same stop also records WHICH subagent ran each of those tickets, as
# governor/agents/<N>/<agent_id>.json holding the agent's id, type and transcript path, whether or
# not its report parsed. A worker dispatched in-session is a sidechain with no stream of its own, so
# that transcript is the only place its token usage exists; resolve-ticket.sh sums it per ticket and
# model from this record. One file per agent, overwritten on each of its stops (the transcript is
# cumulative for that agent), so a first attempt and a retry both stay on record.
set -uo pipefail

[ "${GOVERN_REPORT_CAPTURE:-1}" = "1" ] || exit 0

payload="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
  || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
set +e
command -v govern::extract_report >/dev/null 2>&1 || exit 0

agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // empty' 2>/dev/null)"
agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null)"
transcript="$(printf '%s' "$payload" | jq -r '.agent_transcript_path // empty' 2>/dev/null)"
last_msg="$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)"

if ! is_worker_type "$agent_type"; then
  meta_type="$(govern::agent_meta "$transcript" customAgentType)"
  [ -n "$meta_type" ] || meta_type="$(govern::agent_meta "$transcript" spawnedAgentType)"
  is_worker_type "$meta_type" || exit 0
fi

entries=""
if [ -n "$transcript" ] && [ -s "$transcript" ]; then
  entries="$(LC_ALL=C tr -d '\000' < "$transcript" 2>/dev/null | jq -R 'fromjson? // empty' 2>/dev/null | jq -cs '.' 2>/dev/null)"
fi

# A candidate text -> the report JSON when it is one with a terminal status, else nothing.
as_report() {
  local rep st
  [ -n "${1:-}" ] || return 1
  rep="$(printf '%s' "$1" | govern::extract_report 2>/dev/null)" || return 1
  st="$(printf '%s' "$rep" | jq -r '.status? // empty' 2>/dev/null)"
  case "$st" in resolved|parked|failed) printf '%s' "$rep"; return 0 ;; esac
  return 1
}

report=""
if [ -n "$entries" ]; then
  handback="$(printf '%s' "$entries" | jq -r '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "SubagentHandback") | (.input.message // empty) | strings ]
    | last // empty' 2>/dev/null)"
  report="$(as_report "$handback")"
fi
[ -n "$report" ] || report="$(as_report "$last_msg")"
if [ -z "$report" ] && [ -n "$entries" ]; then
  last_text="$(printf '%s' "$entries" | jq -r '
    [ .[] | select(.type == "assistant") | [ .message.content[]? | select(.type == "text") | .text ]
      | select(length > 0) | join("\n") ] | last // empty' 2>/dev/null)"
  report="$(as_report "$last_text")"
fi
# --- the ticket numbers, from the spawn prompt ---
prompt=""
if [ -n "$entries" ]; then
  prompt="$(printf '%s' "$entries" | jq -r '
    [ .[] | select(.type == "user") | .message.content
      | if type == "string" then . else ([ .[]? | select(.type == "text") | .text ] | join("\n")) end
      | select(length > 0) ] | first // empty' 2>/dev/null)"
fi
[ -n "$prompt" ] || exit 0
nums=""
packet="$(grep -oE '[^[:space:]"`'"'"']*\.dispatch-packet\.md' <<< "$prompt" | sed -n '1p')"
if [ -n "$packet" ] && [ -f "$packet" ]; then
  nums="$(sed -n 's/^## Ticket #\([0-9][0-9]*\).*/\1/p' "$packet" | awk '!seen[$0]++')"
fi
if [ -z "$nums" ]; then
  first_line="$(sed -n '1p' <<< "$prompt" | sed -E 's/([Pp][Rr]|[Pp]ull [Rr]equest)[[:space:]]*#[0-9]+/ /g')"
  nums="$(grep -oE '#[0-9]+' <<< "$first_line" | tr -d '#' | awk '!seen[$0]++')"
fi
[ -n "$nums" ] || exit 0

governor="${GOVERNOR_DIR:-${GOVERN_WS_ROOT:-$SELF_ROOT}/governor}"

# --- which subagent ran these tickets: one record per agent, written on every stop ---
if [ -n "$agent_id" ] && [ -n "$transcript" ]; then
  safe_agent="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -n "$safe_agent" ]; then
    for n in $nums; do
      adir="$governor/agents/$n"
      mkdir -p "$adir" 2>/dev/null || continue
      tmp="$adir/.$safe_agent.json.$$"
      jq -cn --arg id "$agent_id" --arg ty "$agent_type" --arg tp "$transcript" --argjson ts "$(date +%s)" \
        '{agent_id:$id, agent_type:$ty, transcript:$tp, ts:$ts}' > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$adir/$safe_agent.json" 2>/dev/null
      rm -f "$tmp" 2>/dev/null
    done
  fi
fi

# --- the report itself, when the child gave one ---
[ -n "$report" ] || exit 0
dir="$governor/reports"
mkdir -p "$dir" 2>/dev/null || exit 0
for n in $nums; do
  tmp="$dir/.$n.json.$$"
  printf '%s\n' "$report" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$n.json" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
done
exit 0
