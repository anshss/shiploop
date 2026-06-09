#!/usr/bin/env bash
# Dispatcher for the `<pm> run worktree` family.
#
# Usage:
#   <pm> run worktree -- new <name> [...]
#   <pm> run worktree -- rm <name> [...]
#   <pm> run worktree -- status [...]
#   <pm> run worktree -- exec <name> [-- <cmd>]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"

SUB="${1:-}"; shift || true
case "$SUB" in
  new)    exec bash "$ROOT/scripts/worktree/new.sh"    "$@" ;;
  rm)     exec bash "$ROOT/scripts/worktree/rm.sh"     "$@" ;;
  status) exec bash "$ROOT/scripts/worktree/status.sh" "$@" ;;
  exec)   exec bash "$ROOT/scripts/worktree/exec.sh"   "$@" ;;
  ""|-h|--help)
    cat <<EOF
usage: $ROOT_PM run worktree -- <subcommand> [args]

subcommands:
  new <name> [--only a,b]     create worktree at next slot
  rm  <name> [--force] [--keep-branch]
                               remove worktree, free slot
  status [--gc]                list worktrees; --gc clears orphans
  exec <name> [-- <cmd>]       source worktree.env + run cmd (or subshell)

see the "Parallel worktrees" section of the workspace CLAUDE.md
EOF
    exit 0
    ;;
  *)
    echo "unknown subcommand: $SUB" >&2
    exit 2
    ;;
esac
