#!/usr/bin/env bash
# UserPromptSubmit hook: prime the ROUTER POSTURE once per session.
#
# Why this exists: the delegation rule in CLAUDE.md makes "delegate heavy work to a child Agent,
# keep the driver context thin" a HARD rule, but it's one item in a large file.
# Per-turn cost is proportional to THIS session's context size, which is re-sent
# in full every turn — so a driver that reads big files / runs verbose builds /
# investigates inline bloats the window and re-pays for it on every later turn.
# A live interactive transcript here measured 9.7 MB; a governor worker never
# gets near that because it's a throwaway sub-session. This hook surfaces the
# rule at the moment a task arrives so the session adopts the posture from the
# start.
#
# Fire-ONCE-per-session by design: the standing rule already lives in CLAUDE.md
# (loaded every turn at zero marginal cost), so re-injecting it on every prompt
# would just add tokens each turn — the very thing we're trying to cut. We prime
# once (marker keyed on session_id, mirroring ticket-sweep-reminder.sh) to set
# the posture, then stay quiet.
#
# D4 (2026-09-11 spec): the ticket-shaped CLAUSE below is now CONDITIONAL, using the
# **Proposed solution:** signal D2 introduces, so the banner is a dispatch QUALIFIER
# rather than a dispatch ACCELERATOR. Ticket-shaped work naming a ticket with no
# proposal yet means the advisor's next move is to WRITE one, not to spawn a worker;
# a ticket that already carries one routes to a worker exactly as before. Resolution
# is best-effort and degrades to today's unconditional wording (never a hard fail) on
# ANY of: no python3, no resolvable ticket number in the prompt, or the
# ticket-proposal.sh helper (PR #180, .specs/2026-09-11-advisor-worker-design.md D2)
# not yet present on this workspace's govern install.
#
# Output contract: a UserPromptSubmit hook's stdout (on exit 0) is added to the
# model's context as additional guidance. Never block — always exit 0.
set -uo pipefail

# --- read the UserPromptSubmit stdin payload (session_id, prompt, cwd) ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
session_id="$(get session_id)"
[ -n "$session_id" ] || session_id="nosession"

# --- once-per-session marker ---
marker="${TMPDIR:-/tmp}/metarepo-router-posture-${session_id}"
[ -e "$marker" ] && exit 0
: > "$marker" 2>/dev/null || true

# --- default clause: today's unconditional wording, used whenever the D2 lookup
#     below can't run or finds nothing conclusive ---
ticket_clause='Ticket-shaped (a `## #N` block exists, or the operator names tickets) → a WORKER, one per ticket:'

# --- best-effort D2 lookup: extract the prompt via python3 (handles embedded quotes
#     and newlines the sed `get()` helper above can't -- same reason
#     router-posture-guard.sh parses its own payload with python3), find a ticket
#     number that ISN'T a "PR #NNN" reference (same anchoring as that guard's #126
#     fix), and check govern::ticket_proposal for it via the shared CLI wrapper. ---
if command -v python3 >/dev/null 2>&1; then
  prompt="$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("prompt") or "")
' 2>/dev/null)"
  if [ -n "$prompt" ]; then
    prompt_lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
    pr_ref_re='(^|[^[:alnum:]])(pr|pull[[:space:]]+request)[[:space:]]*#[0-9]+'
    prompt_lc_noPR="$(printf '%s' "$prompt_lc" | sed -E "s/$pr_ref_re/ /g")"
    tnum="$(printf '%s' "$prompt_lc_noPR" | grep -oE '#[0-9]+' 2>/dev/null | head -1 | tr -d '#' || true)"
    if [ -n "$tnum" ]; then
      # Dual-layout resolve (#255's pattern, same as ticket-sweep-reminder.sh beside
      # this file): scaffolded workspace has hooks at <root>/scripts/, govern at
      # <root>/scripts/govern/; the hub template repo has hooks at templates/hooks/,
      # govern at templates/govern/ (one level up, not under scripts/).
      SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
      prop_sh="$SELF_ROOT/scripts/govern/ticket-proposal.sh"
      [ -f "$prop_sh" ] || prop_sh="$SELF_ROOT/govern/ticket-proposal.sh"
      source "$SELF_ROOT/scripts/lib/workspace.sh" 2>/dev/null \
        || source "$SELF_ROOT/lib/workspace.sh" 2>/dev/null || true
      tickets_file="${META_ROOT:-}/queue/tickets.md"
      if [ -f "$prop_sh" ] && [ -n "${META_ROOT:-}" ] && [ -f "$tickets_file" ]; then
        prop_out="$(bash "$prop_sh" "$tnum" "$tickets_file" 2>/dev/null || true)"
        if [ -z "$prop_out" ]; then
          ticket_clause="Ticket-shaped, #${tnum} has no \`**Proposed solution:**\` yet → write one first; with one → a WORKER, one per ticket:"
        fi
      fi
    fi
  fi
fi

banner_template='[ROUTER POSTURE] Route by SHAPE before acting. __TICKET_CLAUSE__ `Agent(subagent_type: "worker")` in-session, or the headless lane (`npm run govern:pre-dispatch -- <N>` then `spawn-worker.sh <N>`) for a cron run or no open session, several tickets go through the same steps one at a time, never batched into one dispatch. Either lane ENDS at PR-open plus a structured report; landing it is `npm run govern:resolve -- <N>` fed that report, which awaits CI, merges, and edits the queue file, and the queue block is never deleted before merge. A worker that failed once → retry it once with `model: opus`, then stop and report. Heavy but NOT ticket-shaped (multi-file investigation, codebase sweep, diagnosis, build/test, multi-file change) → delegate to a subagent (run_in_background if long) and relay ONLY its verdict; don'"'"'t Read big files or run verbose builds here. Size subagents per CLAUDE.md'"'"'s delegation rule, reaching for the shipped `lookup` (single-fact, haiku) or `investigator` (multi-file diagnosis, sonnet) agent types when they fit. Multi-stage dependent steps → drive with a `Workflow` (final object only). Trivial (single answer/edit/command/known lookup) → inline. Wrap test/build commands as `npm run vf -- <cmd>` so a passing run stays silent.'

# Plain parameter substitution, NOT eval/sed -- $ticket_clause's own backticks and
# `$` stay literal text, never re-parsed as command/variable substitution.
printf '%s\n' "${banner_template/__TICKET_CLAUSE__/$ticket_clause}"
exit 0
