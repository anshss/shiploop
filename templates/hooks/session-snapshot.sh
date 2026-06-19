#!/usr/bin/env bash
# SessionStart hook: snapshot the workspace's code-work state, keyed by
# session_id, so the ticket-sweep Stop hook can tell work done THIS session apart
# from prior-session residue (commits ahead of origin/main or dirty trees a
# previous session left behind). Generic — repo list from scripts/lib/workspace.sh.
#
# Writes "${TMPDIR}/metarepo-ticket-sweep-baseline-<session_id>" exactly once per
# session. SessionStart also fires on resume/compact/clear with the SAME
# session_id — we must keep the ORIGINAL (startup) baseline, never overwrite it
# with mid-session state, or work would silently rebase into the baseline and the
# reminder would stop firing. The `[ -e ]` guard enforces that.
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$SELF_ROOT/scripts/lib/workspace.sh" 2>/dev/null || source "$SELF_ROOT/lib/workspace.sh" 2>/dev/null || true
# shellcheck source=../lib/session-state.sh
source "$SELF_ROOT/scripts/lib/session-state.sh" 2>/dev/null || source "$SELF_ROOT/lib/session-state.sh" 2>/dev/null || true
MAIN="$META_ROOT"

# --- read the SessionStart stdin payload (session_id, cwd) ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
session_id="$(get session_id)"
cwd="$(get cwd)"
[ -n "$session_id" ] || session_id="nosession"
[ -n "$cwd" ] || cwd="$PWD"

baseline="${TMPDIR:-/tmp}/metarepo-ticket-sweep-baseline-${session_id}"
# Already snapshotted this session (resume/compact/clear) → keep the original.
[ -e "$baseline" ] && exit 0

# --- resolve the repo root: a worktree (has worktree.env) or the main checkout ---
# Same resolution the Stop hook uses, so both fingerprint the same tree.
root="$cwd"
while [ "$root" != "/" ] && [ ! -f "$root/worktree.env" ] && [ ! -f "$root/tickets.md" ]; do
  root="$(dirname "$root")"
done
[ -d "$root" ] || root="$MAIN"

# session-state.sh must have sourced (defines ticket_sweep_state_fingerprint).
if command -v ticket_sweep_state_fingerprint >/dev/null 2>&1; then
  ticket_sweep_state_fingerprint "$MAIN" "$root" > "$baseline" 2>/dev/null || true
fi
exit 0
