#!/usr/bin/env bash
# PreToolUse(Read|Bash) hook: catch a ROUTER-POSTURE violation at the MOMENT it
# happens — the driver session itself about to do a large inline Read or a
# verbose build / `npm run dev`, instead of delegating it to a child Agent.
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
#   • NEVER block — always exit 0; we only *advise* via additionalContext.
#   • Low-noise / no per-turn token cost — a small per-session warn CAP (not a
#     per-turn re-inject). After the cap is hit the hook goes silent.
#   • DRIVER only — skip when the call originates from a sub-agent (its
#     transcript_path lives under a .../subagents/ dir) or a governor worker
#     (GOVERN_RUN set): those throwaway sub-sessions are the delegation *target*,
#     so nudging them to "delegate" is noise.
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
]
for f in fields:
    print(f.replace("\t", " ").replace("\n", " "))
' 2>/dev/null)
tool_name="${tool_name:-}"; transcript_path="${transcript_path:-}"
session_id="${session_id:-}"; file_path="${file_path:-}"
limit="${limit:-}"; command="${command:-}"
[ -n "$tool_name" ] || exit 0

# --- skip sub-agent calls (their transcript lives under .../subagents/) ------
case "$transcript_path" in
  */subagents/*) exit 0 ;;
esac

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
[ -n "$reason" ] || exit 0

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
warn="[ROUTER POSTURE] You (the driver) are about to do ${reason} inline. Per-turn cost ∝ this session's context, re-sent every turn — heavy inline work bloats every later turn. Prefer delegating this to an \`Agent\` worker (run_in_background for long ones) and relaying only its verdict. Proceed inline only if this is a quick, one-off check. (the delegation rule in CLAUDE.md; this warn is rate-limited.)"

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
