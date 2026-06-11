#!/usr/bin/env bash
# Shared helpers for the governor harness. Source, don't execute. Generic — all
# per-workspace values come from scripts/lib/workspace.sh, so /meta-repo:setup
# never edits this file.
set -euo pipefail

# Workspace root = three levels up from scripts/govern/lib/
GOVERN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${GOVERN_WS_ROOT:-$(cd "$GOVERN_LIB_DIR/../../.." && pwd)}"

# Pull repo list, org, and the auto-merge allowlist from the one config file.
# shellcheck source=../../lib/workspace.sh
source "$WS_ROOT/scripts/lib/workspace.sh"

GOVERNOR_DIR="$WS_ROOT/governor"
PREFERENCES_FILE="${GOVERN_PREFERENCES_FILE:-$GOVERNOR_DIR/preferences.md}"
ESCALATIONS_FILE="${GOVERN_ESCALATIONS_FILE:-$GOVERNOR_DIR/escalations.md}"
WORKER_PROMPT_FILE="${GOVERN_WORKER_PROMPT_FILE:-$GOVERNOR_DIR/worker-prompt.md}"
SUPERVISOR_PROMPT_FILE="${GOVERN_SUPERVISOR_PROMPT_FILE:-$GOVERNOR_DIR/supervisor-prompt.md}"
TICKETS_FILE="${GOVERN_TICKETS_FILE:-$WS_ROOT/tickets.md}"
LOG_ROOT="${GOVERN_LOG_ROOT:-$WS_ROOT/logs/govern}"

# Auto-mergeable repos (green-or-no-checks CI) come from workspace.sh. Frontend =
# everything else (PR-only).
GOVERN_FRONTEND_REPOS=()
for _r in "${REPOS[@]}"; do
  wsp_is_merge_repo "$_r" || GOVERN_FRONTEND_REPOS+=("$_r")
done
unset _r

govern::log() { printf '[govern %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
govern::die() { printf '[govern ERROR] %s\n' "$*" >&2; exit 1; }

govern::require() {
  command -v "$1" >/dev/null 2>&1 || govern::die "missing required tool: $1"
}

# ── concurrency primitives (#41: safe parallel govern drivers on disjoint tickets) ──
# mkdir is atomic on POSIX, so an empty dir is a portable mutex. Both helpers reclaim a
# STALE lock (holder crashed) so a dead driver can't wedge the queue forever.
govern::_lock_age() { # lockdir -> seconds since mtime (0 if absent)
  local m; m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
  echo $(( $(date +%s) - m ))
}
# Blocking acquire: spin up to timeout_s. Returns 0 acquired, 1 timed out. Caller releases.
govern::lock_acquire() { # lockdir [timeout_s=60] [stale_s=300]
  local lock="$1" timeout="${2:-60}" stale="${3:-300}" waited=0
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  while ! mkdir "$lock" 2>/dev/null; do
    [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]] && { rmdir "$lock" 2>/dev/null && continue; }
    sleep 1; waited=$((waited+1)); [[ "$waited" -ge "$timeout" ]] && return 1
  done
  return 0
}
# Non-blocking try: claim once. Returns 0 claimed, 1 held by a live other holder.
govern::lock_try() { # lockdir [stale_s=4200]
  local lock="$1" stale="${2:-4200}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  mkdir "$lock" 2>/dev/null && return 0
  [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]] && { rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null && return 0; }
  return 1
}
govern::lock_release() { rmdir "$1" 2>/dev/null || true; }

# Is $1 an auto-mergeable repo? (delegates to workspace.sh)
govern::is_merge_repo() { wsp_is_merge_repo "$1"; }

# Find an already-open PR for ticket $1 (branch standardized to "ticket-<N>" by
# worktree:new). Prints "repo number url" if found — lets a re-run resume instead
# of opening a duplicate PR.
govern::find_pr() {
  local n="$1" repo j num
  command -v gh >/dev/null 2>&1 || return 1
  # Search every sub-repo (REPOS is the union of merge + frontend, always
  # non-empty — avoids expanding a possibly-empty array under set -u on bash 3.2).
  for repo in "${REPOS[@]}"; do
    j="$(gh pr list --repo "$GITHUB_ORG/$repo" --head "ticket-$n" --state open --json number,url 2>/dev/null || echo '[]')"
    num="$(jq -r '.[0].number // empty' <<<"$j" 2>/dev/null || true)"
    if [[ -n "$num" ]]; then
      printf '%s %s %s\n' "$repo" "$num" "$(jq -r '.[0].url // ""' <<<"$j")"
      return 0
    fi
  done
  return 1
}
