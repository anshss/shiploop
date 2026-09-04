#!/usr/bin/env bash
# PreToolUse(Read|Bash|Agent) hook: catch a ROUTER-POSTURE violation at the
# MOMENT it happens: the driver session itself about to do a large inline Read
# or a verbose build / `npm run dev` instead of delegating it, or about to spend
# a full-fat subagent on work that belongs to a worker.
#
# Why this exists (companion to router-posture-reminder.sh):
#   router-posture-reminder.sh primes the delegate-heavy-work posture ONCE per
#   session (UserPromptSubmit) and then stays quiet, so an *in-turn* violation
#   isn't caught when it occurs. Per-turn cost is proportional to THIS session's
#   context size, which is re-sent in full every turn — so a driver that reads a
#   1000+ line file inline or runs a verbose build bloats the window and re-pays
#   for it on every later turn. This hook fires a pointed, low-noise warn at the
#   exact tool call so the driver can redirect the work to a sub-agent.
#
# Design constraints (from the ticket + the once-per-session reminder it extends):
#   • The Read/Bash advisories NEVER block; they only advise via
#     additionalContext. The ticket-route guard (below) is the one deliberate
#     exception: it returns permissionDecision "deny" on Agent calls. Either
#     way the script itself always exits 0.
#   • Low-noise / no per-turn token cost — a small per-session warn CAP (not a
#     per-turn re-inject). After the cap is hit the hook goes silent.
#   • DRIVER only — skip when the call originates from a sub-agent (its
#     transcript_path lives under a .../subagents/ dir) or a governor worker
#     (GOVERN_RUN set): those throwaway sub-sessions are the delegation *target*,
#     so nudging them to "delegate" is noise.
#
# Second advisory (same file, same cap, same driver-only guard): a test/build
# runner (npm test, npm run build/test/check, pytest, go test, cargo test,
# vitest, jest, tsc) invoked WITHOUT verify-filter.sh / `npm run vf` wrapping it
# loses the context savings verify-filter exists for (see templates/govern/
# verify-filter.sh): a passing run's output still lands in the transcript and
# is re-sent every later turn. Kill switch: GOVERN_VF_NUDGE=0.
#
# THIRD behavior, and the only BLOCKING one in this file: the ticket-route guard.
# Vocabulary (one noun, one meaning): a **worker** is the trim, single-ticket
# session. It has two lanes and one doctrine: the interactive lane is
# `Agent(subagent_type: "worker")`, the autonomous lane is govern's headless
# spawn-worker.sh. Any Agent-tool child that is NOT subagent_type "worker" is a
# **subagent** (the platform's own term). An `Agent` call whose prompt is
# ticket-shaped (`#<N>` or the word "ticket") WITHOUT subagent_type "worker" is
# a full-fat subagent doing a worker's job: it inherits the driver's posture,
# skips the worker doctrine, and costs multiples of a worker for the same
# ticket. That call is DENIED with the correct call written out to paste, plus
# the govern alternative. Kill switch: GOVERN_TICKET_ROUTE_GUARD=0 (default ON,
# same polarity as GOVERN_VF_NUDGE above). It never fires inside a worker (the
# GOVERN_RUN and .../subagents/ exemptions below already cover both lanes, and
# workers hold the Agent tool for their own sub-delegation) and never on a call
# that already carries subagent_type "worker".
#
# Output contract: a PreToolUse hook that prints
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
# on stdout (exit 0) injects that text into the model's context WITHOUT blocking
# the tool (no permissionDecision => normal permission flow is untouched).
set -uo pipefail

# --- tuning knobs -----------------------------------------------------------
READ_LINE_THRESHOLD=1000   # a Read spanning >= this many lines counts as "large"
MAX_WARNS_PER_SESSION=3    # after this many warns in a session, stay quiet

# --- never nag the delegation target (sub-agent / governor worker) ----------
[ -n "${GOVERN_RUN:-}" ] && exit 0

# --- read the PreToolUse stdin payload --------------------------------------
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0   # parser needed; degrade silently

# Parse the fields we need with one python3 pass (robust vs. nested tool_input).
# Emits ONE FIELD PER LINE (newlines within values flattened to spaces) so empty
# fields survive and we can read them portably (macOS system bash is 3.2 — no
# `mapfile`; a tab-delimited `read` would also collapse the empty middle fields).
{
  IFS= read -r tool_name
  IFS= read -r transcript_path
  IFS= read -r session_id
  IFS= read -r file_path
  IFS= read -r limit
  IFS= read -r command
  IFS= read -r subagent_type
  IFS= read -r agent_prompt
  IFS= read -r agent_desc
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
    g("file_path"),
    g("limit"),
    g("command"),
    g("subagent_type"),
    g("prompt"),
    g("description"),
]
for f in fields:
    print(f.replace("\t", " ").replace("\n", " "))
' 2>/dev/null)
tool_name="${tool_name:-}"; transcript_path="${transcript_path:-}"
session_id="${session_id:-}"; file_path="${file_path:-}"
limit="${limit:-}"; command="${command:-}"
subagent_type="${subagent_type:-}"; agent_prompt="${agent_prompt:-}"
agent_desc="${agent_desc:-}"
[ -n "$tool_name" ] || exit 0

# --- skip sub-agent calls (their transcript lives under .../subagents/) ------
case "$transcript_path" in
  */subagents/*) exit 0 ;;
esac

# --- ticket-route guard: ticket-shaped Agent work belongs to a worker --------
# The one BLOCKING path in this file (see the header). Both worker lanes are
# already exempt above: the autonomous lane exports GOVERN_RUN, the interactive
# lane's transcript lives under .../subagents/, so a worker sub-delegating with
# the Agent tool is never touched by this.
if [ "$tool_name" = "Agent" ]; then
  [ "${GOVERN_TICKET_ROUTE_GUARD:-1}" = "0" ] && exit 0
  # Already the worker agent type: nothing to route.
  [ "$subagent_type" = "worker" ] && exit 0
  probe="$agent_prompt $agent_desc"
  if printf '%s' "$probe" | grep -Eq '#[0-9]+' || printf '%s' "$probe" | grep -Eqi 'ticket'; then
    tnum="$(printf '%s' "$probe" | grep -oE '#[0-9]+' 2>/dev/null | head -1 | tr -d '#' || true)"
    [ -n "$tnum" ] || tnum="N"
    deny="$(cat <<EOF
[ROUTER POSTURE] Denied: this is ticket-shaped work, and ticket-shaped work goes to a WORKER, never to a stock subagent. A worker is the trim, single-ticket session: sonnet floor, trimmed tools, its own workspace worktree, ending at PR-open plus a structured report. A stock subagent doing the same ticket carries the driver's posture and none of the worker doctrine, and costs multiples of a worker for the same result.

Interactive lane. Paste this instead:

  Agent(
    subagent_type: "worker",
    description: "ticket #${tnum}",
    prompt: "<the ticket text plus anything the worker needs to start>"
  )

Autonomous lane, for a multi-ticket batch, a cron run, or no open session:

  npm run govern -- ${tnum}

The interactive lane STOPS at PR-open plus the report. Merge, CI await and queue bookkeeping go through govern's PR-adoption path: run \`npm run govern -- ${tnum}\` once the PR is open and it ADOPTS that PR instead of redoing the work. Never delete the queue block before merge. If the worker fails once, retry it once with \`model: opus\`, then stop and report.

Not ticket work after all (an investigation, a sweep, a diagnosis feeding an answer)? Drop the ticket reference from the prompt and size the subagent per the haiku/sonnet table, or set GOVERN_TICKET_ROUTE_GUARD=0 to turn this guard off for the session.
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
  fi
  exit 0
fi

# --- decide whether THIS call is heavy inline work --------------------------
reason=""
case "$tool_name" in
  Read)
    # Large inline Read: unbounded (or wide-limit) read of a big file.
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
      total_lines="$(wc -l < "$file_path" 2>/dev/null | tr -d ' ')"
      [ -n "$total_lines" ] || total_lines=0
      # effective span = limit if the driver set one, else the whole file
      span="$total_lines"
      if [ -n "$limit" ]; then
        case "$limit" in (*[!0-9]*) ;; (*) span="$limit" ;; esac
      fi
      if [ "$span" -ge "$READ_LINE_THRESHOLD" ] 2>/dev/null; then
        reason="a ${span}-line inline Read of $(basename "$file_path")"
      fi
    fi
    ;;
  Bash)
    # Verbose build / dev-server / install run.
    if printf '%s' "$command" | grep -Eq \
      '(^|[[:space:];&|])((npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(dev|build|start)|(npm|pnpm|bun)[[:space:]]+(ci|install|i)([[:space:]]|$)|yarn[[:space:]]+install|next[[:space:]]+(dev|build)|vite[[:space:]]+build|turbo[[:space:]]+run[[:space:]]+(dev|build)|(cargo|go|docker)[[:space:]]+build|webpack([[:space:]]|$)|tsc([[:space:]]|$))'; then
      reason="a verbose build/dev/install run"
    fi
    ;;
esac

# --- separate advisory: unwrapped test/build runner should use verify-filter
vf_reason=""
if [ "$tool_name" = "Bash" ] && [ "${GOVERN_VF_NUDGE:-1}" != "0" ]; then
  if printf '%s' "$command" | grep -Eq \
      '(^|[[:space:];&|])(npm[[:space:]]+(run[[:space:]]+)?(test|build|check)([[:space:]]|$)|pytest([[:space:]]|$)|go[[:space:]]+test([[:space:]]|$)|cargo[[:space:]]+test([[:space:]]|$)|vitest([[:space:]]|$)|jest([[:space:]]|$)|tsc([[:space:]]|$))' \
    && ! printf '%s' "$command" | grep -Eq \
      '(verify-filter\.sh|npm[[:space:]]+run[[:space:]]+vf([[:space:]]|$))'; then
    vf_reason="a test/build run not wrapped in verify-filter"
  fi
fi

[ -n "$reason" ] || [ -n "$vf_reason" ] || exit 0

# --- rate-limit: cap warns per session --------------------------------------
# sanitize session_id for use in a filename (it's a UUID in practice, but never
# trust it — keep only filename-safe chars so it can't path-traverse).
session_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$session_id" ] || session_id="nosession"
counter="${TMPDIR:-/tmp}/metarepo-router-posture-guard-${session_id}"
count=0
[ -f "$counter" ] && count="$(cat "$counter" 2>/dev/null || echo 0)"
case "$count" in (*[!0-9]*) count=0 ;; esac
[ "$count" -ge "$MAX_WARNS_PER_SESSION" ] 2>/dev/null && exit 0
printf '%s' "$((count + 1))" > "$counter" 2>/dev/null || true

# --- emit the non-blocking warn ---------------------------------------------
warn=""
if [ -n "$reason" ]; then
  warn="[ROUTER POSTURE] About to do ${reason} inline. Delegate it to a subagent (run_in_background if long); relay only its verdict. Size the subagent per CLAUDE.md's delegation table (haiku=mechanical, sonnet=search/edits, inherit=judgment-heavy), reaching for the shipped \`lookup\` or \`investigator\` agent types when they fit. If this is ticket-shaped work it belongs to a worker instead: \`Agent(subagent_type: \"worker\")\` for one ticket in-session, or \`npm run govern -- <N>\` for a batch. Proceed inline only for a quick one-off check."
fi
if [ -n "$vf_reason" ]; then
  vf_warn="[ROUTER POSTURE] ${vf_reason}: wrap it as \`npm run vf -- <cmd>\` (or \`bash scripts/govern/verify-filter.sh -- <cmd>\`) so a passing run emits nothing into context and a failing run still shows its bounded tail."
  if [ -n "$warn" ]; then warn="$warn $vf_warn"; else warn="$vf_warn"; fi
fi

python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": sys.argv[1],
  }
}))
' "$warn" 2>/dev/null || true
exit 0
