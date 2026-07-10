#!/usr/bin/env bash
# Source a worktree's env and run a command (or open a subshell) inside it.
#
# Usage:
#   <pm> run worktree:exec -- <name> -- <cmd> [args...]    # run a command
#   <pm> run worktree:exec -- <name>                       # open subshell
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"

[ $# -ge 1 ] || { echo "usage: $ROOT_PM run worktree:exec -- <name> [-- <cmd>]" >&2; exit 2; }
NAME="$1"; shift
WORKTREE_PATH=$(wt_registry_path_for "$NAME") || exit 1

if [ $# -gt 0 ] && [ "$1" = "--" ]; then shift; fi

cd "$WORKTREE_PATH"
# shellcheck disable=SC1091
source "$WORKTREE_PATH/worktree.env"

# Derive a CONSOLE_URL from the first repo in REPO_PORTS that looks like a
# frontend (name contains "console", "web", or "frontend"); fall back to the
# first ported repo if none match. This gives exec.sh a useful URL hint without
# hardcoding any repo name.
CONSOLE_URL=""
for repo in "${REPOS[@]}"; do
  port=$(wsp_repo_port "$repo" "$WORKTREE_SLOT")
  [ -n "$port" ] || continue
  if [[ "$repo" == *console* ]] || [[ "$repo" == *web* ]] || [[ "$repo" == *frontend* ]]; then
    CONSOLE_URL="http://localhost:$port"
    break
  fi
  # Fallback: first ported repo
  [ -n "$CONSOLE_URL" ] || CONSOLE_URL="http://localhost:$port"
done
export CONSOLE_URL

if [ $# -eq 0 ]; then
  echo "→ subshell in $NAME (slot $WORKTREE_SLOT${CONSOLE_URL:+, $CONSOLE_URL})"
  exec "${SHELL:-/bin/bash}"
else
  exec "$@"
fi
