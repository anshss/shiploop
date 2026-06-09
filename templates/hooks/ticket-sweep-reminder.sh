#!/usr/bin/env bash
# Stop hook: when a session that did real code work is about to end, nudge once to
# reconcile tickets.md — file any newly-discovered bug/gap as a numbered ticket,
# and delete any ticket whose fix PR was opened this session. Generic — repo list
# from scripts/lib/workspace.sh, paths resolved relative to this script.
#
# Why this exists: the "discovered gap → tickets.md" and "PR opened → delete the
# ticket" rules in CLAUDE.md are convention, not enforced by anything. A
# compaction or a distracted turn silently drops them. This hook makes the "did I
# find something new?" check deterministic at session end.
#
# Design constraints (a Stop hook that always blocks would loop forever):
#   1. Fire AT MOST ONCE per session    — marker keyed on session_id.
#   2. Never re-fire inside its own loop — honor stop_hook_active.
#   3. Only fire when the session touched code — uncommitted changes OR a branch
#      ahead of origin/main in any sub-repo, OR uncommitted tickets.md. Pure
#      Q&A / read-only sessions produce none of these, so they stop silently.
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$SELF_ROOT/scripts/lib/workspace.sh" 2>/dev/null || source "$SELF_ROOT/lib/workspace.sh" 2>/dev/null || true
MAIN="$META_ROOT"

# --- read the Stop hook stdin payload (session_id, stop_hook_active, cwd) ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
session_id="$(get session_id)"
cwd="$(get cwd)"
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

[ -n "$cwd" ] || cwd="$PWD"
[ -n "$session_id" ] || session_id="nosession"

# --- once-per-session marker ---
marker="${TMPDIR:-/tmp}/metarepo-ticket-sweep-${session_id}"
[ -e "$marker" ] && exit 0

# --- resolve the repo root: a worktree (has worktree.env) or the main checkout ---
root="$cwd"
while [ "$root" != "/" ] && [ ! -f "$root/worktree.env" ] && [ ! -f "$root/tickets.md" ]; do
  root="$(dirname "$root")"
done
[ -d "$root" ] || root="$MAIN"

did_code_work() {
  # tickets.md itself dirty in the main checkout → work in progress.
  if [ -f "$MAIN/tickets.md" ] && ! git -C "$MAIN" diff --quiet -- tickets.md 2>/dev/null; then
    return 0
  fi
  local r dir
  for r in "${REPOS[@]:-}"; do
    dir="$root/$r"
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
    # uncommitted changes (staged or unstaged)?
    if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
      return 0
    fi
    # local commits ahead of origin/main?
    local ahead
    ahead=$(git -C "$dir" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && return 0
  done
  return 1
}

if ! did_code_work; then
  exit 0
fi

# Fire once: drop the marker, then block with the reconcile reason.
: > "$marker" 2>/dev/null || true

reason="Before ending: reconcile tickets.md (root meta-repo). \
(1) NEW TICKETS — review what you touched/discovered this session. Any bug, gap, \
missing capability, or follow-up that is NOT already a ticket gets its own numbered \
## #N entry in $MAIN/tickets.md (Severity / Where / Observed / Fix direction / Done when / Ref). \
A discovered gap ALWAYS goes to tickets.md, never learnings.md. \
(2) RESOLVED TICKETS — for any ticket whose fix PR you OPENED this session (PR opened = resolved, \
not merged), DELETE its entry from tickets.md now; promote any durable lesson to CLAUDE.md first, \
and name the PR number in the deletion commit. \
If there is genuinely nothing to file and nothing to delete, say so in one line and stop. \
Do not re-investigate or start new work — this is a bookkeeping pass only."

# JSON-escape the reason and emit the block decision.
esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"%s"}\n' "$esc"
exit 0
