#!/usr/bin/env bash
# PreToolUse(*) hook, DRIVER-scoped: the per-session cap on advisor-to-worker STEERS. The upward
# half of the same bound is script-owned in advisor-consult.sh (how often a worker may ask); this is
# its downward counterpart (how often the advisor may tell).
#
# WHAT A STEER IS. The advisor session sends a message to a worker subagent it dispatched. That is
# a correction: the proposal was wrong somewhere, or the worker asked and this is the answer.
# Steering is a real and wanted thing, which is why the worker is a subagent at all: the two-way
# channel is the reason for the shape.
#
# WHY IT IS BOUNDED. The failure this architecture exists to prevent is the premium session relaying
# instead of reasoning. Unbounded turn-by-turn steering re-creates exactly that: the advisor stops
# handing over a solution and starts driving the keyboard through a proxy, paying premium tokens for
# every implementation step it said it would not take. A steer is a correction, not a remote
# control. Past the cap the answer is not another message, it is a corrected `**Proposed solution:**`
# and a fresh dispatch, which is cheap, restates the whole decision in one place, and leaves the
# next worker with a brief instead of a conversation.
#
# THE CAP (GOVERN_STEER_CAP, default 12, `0` disables). Not a derived constant, a starting point,
# and it is deliberately NOT 6: the downward channel carries two kinds of traffic. Answers to a
# worker's own consults are already bounded at GOVERN_ADVISOR_PER_SESSION (default 6,
# advisor-consult.sh), and a cap that counted those would let a session that used its consult
# budget be denied every genuine correction. So the default is that budget plus an equal allowance
# for unsolicited corrections: 6 + 6. A session doing real advising lands far under it; a session
# remote-controlling one worker passes it well before the work is done.
#
# DETECTION, reusing what the tree already has rather than inventing a second way:
#   * "is this the driver" -- the same two exemptions router-posture-guard.sh uses: GOVERN_RUN set
#     (a headless worker) and a transcript under `.../subagents/` (an in-session child). Plus
#     `agent_id`, the field agent-watchdog-guard.sh keys its own child detection on (present on
#     every tool call a subagent makes, absent on the driver's own). A worker messaging UP to its
#     advisor is a CONSULT, budgeted by advisor-consult.sh, and must never be counted here.
#   * "is the target a worker" -- `subagent_type: "worker"` on the dispatching Agent call, the
#     exact signal router-posture-guard.sh already treats as the worker lane. This hook sees that
#     call too (PreToolUse `*`), so it records the dispatched worker's ADDRESS as the session goes,
#     and a later SendMessage is a steer only if it is addressed to one of those recorded names.
#     Messages to an `investigator`/`lookup` child, or to `main`, are not steers and are not
#     counted: those are the advisor's own read-only data-collection children, not work being
#     driven.
#
# An agent dispatched with no `name` is addressable by its type ("worker") or by a raw agentId the
# dispatch call cannot know in advance. Both are handled: "worker" is recorded as an address for an
# unnamed dispatch, and an agentId-shaped target counts only when this session actually dispatched
# an unnamed worker. That last one is a heuristic and is documented as such: it can over-count a
# message addressed by raw id to some other unnamed child. It errs toward counting, which costs a
# nudge to re-dispatch, never a lost message: the deny is recoverable and names its kill switch.
#
# SHIPS ON. An inert-by-default gate is a check that reads as configured and controls nothing. This
# is the deliberate counterpart to the rule that new mechanisms default OFF in the govern suite's
# test/assert.sh: that rule exists for mechanisms that SPAWN and so perturb dispatch fixtures. This
# one only ever denies a message, so it is pinned at its shipped value in assert.sh instead, the way
# GOVERN_AGENT_SUPERVISION already is.
#
# Fail-open discipline, same as every hook here: no python3, no parseable payload, no session id,
# an unwritable counter -- every one of them degrades to "allow", and the script always exits 0.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# --- never count a CHILD's own messages (a worker consulting UP is not a steer) ---------------
[ -n "${GOVERN_RUN:-}" ] && exit 0

command -v python3 >/dev/null 2>&1 || exit 0   # parser needed; degrade silently

# ONE python3 pass, one field per line (the idiom router-posture-guard.sh uses: newlines flattened
# so empty fields survive and macOS bash 3.2 can read them back without `mapfile`).
{
  IFS= read -r tool_name
  IFS= read -r transcript_path
  IFS= read -r session_id
  IFS= read -r agent_id
  IFS= read -r subagent_type
  IFS= read -r agent_name
  IFS= read -r msg_to
} < <(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
def g(k):
    v = ti.get(k)
    return "" if v is None else str(v)
fields = [
    d.get("tool_name") or "",
    d.get("transcript_path") or "",
    d.get("session_id") or "",
    d.get("agent_id") or "",
    g("subagent_type"),
    g("name"),
    g("to"),
]
for f in fields:
    print(f.replace("\t", " ").replace("\n", " "))
' 2>/dev/null)
tool_name="${tool_name:-}"; transcript_path="${transcript_path:-}"; session_id="${session_id:-}"
agent_id="${agent_id:-}"; subagent_type="${subagent_type:-}"; agent_name="${agent_name:-}"
msg_to="${msg_to:-}"
[ -n "$tool_name" ] || exit 0
[ -n "$agent_id" ] && exit 0                   # a subagent's own call: never a steer
case "$transcript_path" in */subagents/*) exit 0 ;; esac

[ "${GOVERN_STEER_CAP:-12}" = "0" ] && exit 0

# Per-session state, keyed the same sanitised way router-posture-guard.sh keys its own counters
# (never trust a session id into a path unescaped). Two files: the addresses of the workers this
# session dispatched, and the running steer count.
safe_sid="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe_sid" ] || safe_sid="nosession"
registry="${TMPDIR:-/tmp}/metarepo-advisor-steer-workers-${safe_sid}"
counter="${TMPDIR:-/tmp}/metarepo-advisor-steer-count-${safe_sid}"

# --- record a worker dispatch's address ---------------------------------------------------------
if [ "$tool_name" = "Agent" ]; then
  if [ "$subagent_type" = "worker" ]; then
    if [ -n "$agent_name" ]; then
      printf '%s\n' "$(printf '%s' "$agent_name" | tr '[:upper:]' '[:lower:]')" >> "$registry" 2>/dev/null || true
    else
      # No name: addressable by its type, or by a raw agentId this call cannot know yet.
      printf 'worker\n@unnamed\n' >> "$registry" 2>/dev/null || true
    fi
  fi
  exit 0
fi

[ "$tool_name" = "SendMessage" ] || exit 0
[ -n "$msg_to" ] || exit 0
[ -f "$registry" ] || exit 0                   # this session never dispatched a worker

# `to` may carry a disambiguating " [ref]" suffix (SendMessage's own documented form).
target="$(printf '%s' "$msg_to" | sed -E 's/[[:space:]]*\[[^]]*\][[:space:]]*$//' \
            | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')"
[ -n "$target" ] || exit 0
[ "$target" = "main" ] && exit 0                # upward, by definition not a steer

is_steer=0
if grep -qxF "$target" "$registry" 2>/dev/null; then
  is_steer=1
elif grep -qxF '@unnamed' "$registry" 2>/dev/null; then
  # Raw agentId form (`a...-...`), only meaningful when an unnamed worker is in flight.
  case "$target" in a*-*) is_steer=1 ;; esac
fi
[ "$is_steer" = 1 ] || exit 0

cap="${GOVERN_STEER_CAP:-12}"
case "$cap" in (*[!0-9]*) cap=12 ;; esac
count=0
[ -f "$counter" ] && count="$(cat "$counter" 2>/dev/null || echo 0)"
case "$count" in (*[!0-9]*) count=0 ;; esac
count=$((count + 1))
printf '%s' "$count" > "$counter" 2>/dev/null || true
[ "$count" -gt "$cap" ] 2>/dev/null || exit 0

deny="$(cat <<EOF
[STEER CAP] Denied: this session has already sent ${cap} steers to workers (GOVERN_STEER_CAP). A steer is a correction, not a remote control -- past this point, turn-by-turn steering is the premium session implementing through a proxy, which is the one cost the advisor/worker split exists to avoid.

Do this instead: let the worker finish and report, then rewrite the ticket's \`**Proposed solution:**\` to say what you have been steering toward, and dispatch a fresh worker on it. A corrected proposal states the whole decision in one place; a conversation does not, and the next worker cannot read this one's inbox.

If the run genuinely needs a longer leash, raise GOVERN_STEER_CAP (or set it to 0 to disable the cap for the session).
EOF
)"
python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.argv[1],
  }
}))
' "$deny" 2>/dev/null || true
exit 0
