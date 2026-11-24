#!/usr/bin/env bash
# landed.sh: the squash-merge landed-branch check, shared by reap.sh (worktree lifecycle)
# and ship.sh (the per-repo push/PR step). Source, don't execute.
#
# A squash merge severs SHA ancestry forever: the commit a worktree branched off is never
# an ancestor of the squashed merge commit origin/main gains, even though its CONTENT
# landed byte-for-byte. An ancestry count alone therefore cannot distinguish "already
# landed" from "unlanded work"; the tree compare below is the decisive signal, and it
# FAILS CLOSED: a ref that cannot be resolved reports "not landed", never the reverse.
#
# Per-workspace values (tickets file location) resolve from this file's own installed
# location, exactly the way common.sh derives WS_ROOT — never inlined here.
set -uo pipefail

GOVERN_LANDED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOVERN_LANDED_WS_ROOT="${GOVERN_WS_ROOT:-$(cd "$GOVERN_LANDED_LIB_DIR/../../.." && pwd)}"

# rc 0 iff HEAD's tree is byte-identical to origin/<branch>'s. A missing or unresolvable
# origin ref returns 1: could-not-look is never treated as "landed".
govern::tree_matches_origin() { # <repo-dir> <branch>
  git -C "$1" rev-parse --verify -q "origin/$2" >/dev/null 2>&1 || return 1
  git -C "$1" diff --quiet "origin/$2" HEAD -- 2>/dev/null
}

# rc 0 iff the named ticket is gone from the queue AND the repo's committed tree already
# landed on origin/<branch>. Both signals must agree: a gone ticket alone proves nothing
# (the slug convention can collide, and a ticket can resolve without this repo's half
# actually merging), and a tree match alone proves nothing about the ticket lifecycle.
# <tickets-file> defaults to the workspace's own queue; callers that already know their
# root (reap.sh) pass it explicitly so an inherited GOVERN_TICKETS_FILE cannot redirect
# the check.
govern::branch_is_landed() { # <repo-dir> <branch> <ticket> [tickets-file]
  local tickets
  [ -n "$3" ] || return 1
  tickets="${4:-${GOVERN_TICKETS_FILE:-$GOVERN_LANDED_WS_ROOT/queue/tickets.md}}"
  grep -qE "^##[[:space:]]*#${3}([^0-9]|$)" "$tickets" 2>/dev/null && return 1
  govern::tree_matches_origin "$1" "$2"
}
