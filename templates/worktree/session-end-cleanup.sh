#!/usr/bin/env bash
# SessionEnd hook: run the project-specific session-cleanup hook (e.g. close
# billable test deploys) AND tear down this session's local dev stack so
# processes don't accumulate across sessions.
#
# Walk up from CWD to find a worktree.env and act on THAT worktree's ports,
# not the main checkout's. Falls back to the main checkout (slot-0 ports) when
# no worktree.env is found upward.
#
# Why kill, not just clean: the old approach only closed deploys and left dev
# processes running, so orchestrators / servers piled up across sessions — and
# a prod-pointed process left alive is a latent reconciler/billing hazard.
# The rule is: work done → stack down.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"

# Kill processes on $port that THIS checkout owns (cwd under $2), never a parallel
# session's (anti-pattern #10). Killing whoever holds the port would SIGKILL a
# neighbor's stack mid-run on a slot collision — or via the slot-0 base-port
# fallback below. A process from another checkout is left alone; this is a cleanup
# hook, so we silently skip rather than erroring.
kill_port() {
  local port="$1" owner_root="$2" pids pid pcwd
  [ -n "$port" ] || return 0
  pids=$(lsof -ti tcp:"$port" 2>/dev/null) || true
  for pid in $pids; do
    pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    case "$pcwd" in
      "$owner_root"|"$owner_root"/*) kill -9 "$pid" 2>/dev/null || true ;;
      *) : ;;  # another checkout's process — never ours to kill
    esac
  done
}

dir="$PWD"
while [ "$dir" != "/" ]; do
  if [ -f "$dir/worktree.env" ]; then
    cd "$dir"
    # shellcheck disable=SC1091
    source "$dir/worktree.env"

    # Run project-specific session cleanup (e.g. close billable test deploys)
    # before killing ports — best-effort; never blocks teardown.
    if [ -x "$ROOT/scripts/lib/session-cleanup.sh" ]; then
      bash "$ROOT/scripts/lib/session-cleanup.sh" || true
    fi

    # Kill every port this worktree's slot owns (derived generically from
    # REPO_PORTS + WORKTREE_SLOT set in worktree.env).
    for repo in "${REPOS[@]}"; do
      # Use the WORKTREE_<UPPER>_PORT vars written by new.sh if present;
      # fall back to computing from REPO_PORTS so the hook works even if
      # worktree.env predates the per-repo export format.
      upper=$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')
      var="WORKTREE_${upper}_PORT"
      port="${!var:-}"
      if [ -z "$port" ]; then
        port=$(wsp_repo_port "$repo" "${WORKTREE_SLOT:-0}")
      fi
      kill_port "$port" "$dir"   # only if cwd under this worktree
    done
    exit 0
  fi
  dir="$(dirname "$dir")"
done

# Main checkout (no worktree.env found): run cleanup then kill slot-0 ports.
if [ -x "$ROOT/scripts/lib/session-cleanup.sh" ]; then
  bash "$ROOT/scripts/lib/session-cleanup.sh" || true
fi

for repo in "${REPOS[@]}"; do
  port=$(wsp_repo_port "$repo" 0)
  kill_port "$port" "$ROOT"   # only if cwd under the main checkout
done
exit 0
