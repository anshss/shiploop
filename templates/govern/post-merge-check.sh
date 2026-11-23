#!/usr/bin/env bash
# post-merge-check.sh: the merged-ref gate behind "landed".
#
# Worktree-green is not merged-green when PRs stack: each PR's CI ran on ITS OWN branch base, so a
# squash-merge can silently resolve a stacked conflict to the stale-base side and drop the other
# PR's lines (the stacked-PR clobber). CI on the branches says nothing about the tree a merge
# PRODUCES. This script runs a configurable check command against the POST-MERGE ref (freshly
# fetched origin/main, in a throwaway detached worktree) so the resolve path can refuse to bookkeep
# "landed" on a merged-but-broken main.
#
# Usage:  post-merge-check.sh <repo> <pr>          (the <pr> arg is only used in messages)
#
# Configuration:
#   GOVERN_POST_MERGE_GATE   1 (default) = gate on; 0 = always pass. Kill switch.
#   GOVERN_POST_MERGE_CMD    the check command, run with cwd = a fresh temp checkout of merged
#                            origin/main. Empty (default) = gate ARMED but INERT — there is nothing
#                            to run, so the gate passes with a note. Set it to turn the gate on
#                            (workspace.sh seeds the value; note a fresh temp checkout has no
#                            node_modules, so prefer a dependency-free command or have the command
#                            install/point at deps).
#   GOVERN_ECHO=1            print what would run, touch nothing, exit 0 (dry-run convention).
#
# Exit codes:
#   0   passed (or gate off, or no command configured)
#   7   the check command FAILED on the merged ref — caller must NOT bookkeep "landed"
#   8   could not build a trustworthy merged checkout (fetch failure / missing ref / worktree
#       add failed) — FAIL-CLOSED: an unverifiable merged ref never counts as a pass
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

REPO="${1:?repo required}"
PR="${2:-}"

if [[ "${GOVERN_POST_MERGE_GATE:-1}" != "1" ]]; then
  govern::log "post-merge-check: GOVERN_POST_MERGE_GATE=0 — gate off, passing"
  exit 0
fi
CMD="${GOVERN_POST_MERGE_CMD:-}"
if [[ -z "$CMD" ]]; then
  govern::log "post-merge-check: GOVERN_POST_MERGE_CMD empty — gate armed but inert (nothing to run), passing"
  exit 0
fi

localdir="$(govern::repo_localdir "$REPO")"
if ! { [[ -d "$localdir/.git" ]] || [[ -f "$localdir/.git" ]]; }; then
  echo "[govern ERROR] post-merge-check: no checkout of '$REPO' at $localdir to resolve the merged ref through" >&2
  exit 8
fi

if [[ "${GOVERN_ECHO:-0}" == "1" ]]; then
  printf 'WOULD RUN (post-merge check on %s merged main): %s\n' "$REPO" "$CMD"
  exit 0
fi

# Resolve the merged ref through a FRESH fetch — the whole point is to check what origin/main is
# NOW, post-merge, not what some checkout last saw. A fetch failure is exit 8 (fail-closed), never
# a silent pass.
if ! git -C "$localdir" fetch --quiet --prune origin main >/dev/null 2>&1; then
  echo "[govern ERROR] post-merge-check: fetch of origin main failed for $REPO — cannot verify the merged ref" >&2
  exit 8
fi
sha="$(git -C "$localdir" rev-parse --verify origin/main)" || {
  echo "[govern ERROR] post-merge-check: no origin/main ref on $REPO after fetch" >&2
  exit 8
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/govern-post-merge-check.XXXXXX")"
cleanup() {
  git -C "$localdir" worktree remove --force "$tmp/check" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! git -C "$localdir" worktree add --detach "$tmp/check" "$sha" >/dev/null 2>&1; then
  echo "[govern ERROR] post-merge-check: could not materialize merged main ($sha) for $REPO at $tmp/check" >&2
  exit 8
fi

govern::log "post-merge-check: running GOVERN_POST_MERGE_CMD on merged $REPO main ($sha)${PR:+, PR #$PR}"
if ( cd "$tmp/check" && bash -c "$CMD" ); then
  govern::log "post-merge-check: PASS on merged ref ($sha)"
  exit 0
else
  rc=$?
  govern::log "post-merge-check: FAIL (rc=$rc) on merged $REPO main ($sha): $CMD"
  exit 7
fi
