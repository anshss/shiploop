#!/usr/bin/env bash
# Retry memory: the scratchpad (.governor-notes.md) a worker writes during an attempt is git-ignored
# (never lands in a PR) and every worker is told to write it as it goes, so a retry has something to
# read. The injection of a preserved worktree's notes into a re-dispatched worker's prompt lived in
# the headless dispatch launcher, retired along with it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# ── Wiring checks. These files live at DIFFERENT paths depending on where the suite runs from: the
# hub (templates/govern/test → templates/gitignore) or a scaffolded workspace (scripts/govern/test →
# <ws>/.gitignore). Resolve the first that exists; if neither does, the suite is running from a
# layout that doesn't ship them, so skip rather than fail on a path assumption.
first_existing() { for p in "$@"; do [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }; done; return 1; }

# The scratchpad is git-ignored, so it can never land in a PR.
if gi="$(first_existing "$DIR/../../gitignore" "$DIR/../../../.gitignore")"; then
  assert_contains "$(cat "$gi")" ".governor-notes.md" \
    "gitignore ignores the scratchpad so it never lands in a PR ($gi)"
else
  printf 'skip - gitignore not present in this layout\n'
fi
# And every worker is told to write it (otherwise a retry has nothing to read).
if wp="$(first_existing "$DIR/../../governor/worker-prompt.md" "$DIR/../../../governor/worker-prompt.md")"; then
  assert_contains "$(cat "$wp")" ".governor-notes.md" \
    "worker prompt instructs the worker to record findings to the scratchpad ($wp)"
else
  printf 'skip - worker-prompt.md not present in this layout\n'
fi

assert_done
