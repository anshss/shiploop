#!/usr/bin/env bash
# gotchas-for-paths.sh <repo>/<path> [<repo>/<path> ...] — print the recorded-gotchas block
# (rail 9, #125) for the given <sub-repo>/<path> tokens, or nothing if none of them are named by a
# **Paths:**-tagged CLAUDE.md/learnings.md entry.
#
# This is the interactive lane's entry point into the SAME lookup the headless launcher
# (spawn-worker.sh) runs on a ticket's candidate paths — see govern::gotcha_block in lib/common.sh,
# the one shared implementation both lanes call. The headless lane gets this injected into its
# dispatch prompt automatically; a worker subagent (.claude/agents/worker.md) has no launcher to do
# that for it, so it runs THIS as its own first step, for the paths it is about to touch, and
# treats the output as part of its brief.
#
# Usage: scripts/govern/gotchas-for-paths.sh <repo>/<path> [<repo>/<path> ...]
# Prints nothing (exit 0) when no candidate matches a tagged entry — silent in the common case, by
# design, exactly like the headless lane's injection.
# Honors the same knobs as the headless lane: GOVERN_GOTCHA_INJECT=0 disables it entirely,
# GOVERN_GOTCHA_MAX / GOVERN_GOTCHA_MAX_BYTES cap it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $(basename "$0") <repo>/<path> [<repo>/<path> ...]" >&2
  exit 2
fi

govern::gotcha_block "$@"
