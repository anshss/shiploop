#!/usr/bin/env bash
# gotchas-for-paths.sh <repo>/<path> [<repo>/<path> ...] — print the recorded-gotchas block
# for the given <sub-repo>/<path> tokens, or nothing if none of them are named by a
# **Paths:**-tagged CLAUDE.md/learnings.md entry.
#
# A worker's entry point into govern::gotcha_block (lib/common.sh), the one shared implementation.
# Nothing injects a hazard block into a worker's prompt on its behalf, so a worker subagent
# (.claude/agents/worker.md) runs THIS as its own first step, for the paths it is about to touch, and
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
