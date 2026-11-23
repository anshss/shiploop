#!/usr/bin/env bash
# wt_subrepo_base_ref <repo-dir> — echo the git ref a NEW sub-repo worktree should branch off.
#
# Cut sub-repo worktrees off the freshly-fetched origin/main, NOT the main checkout's LOCAL
# `main`. The main checkout is read-only / rarely-pulled (worktree-only workflow), so each sub-repo's
# local `main` drifts behind its remote; branching a ticket/feature worktree off that stale base makes
# PRs born CONFLICTING against current origin/main even when the change is trivial (an upstream commit
# touched the same file since the last local pull).
#
# Fetch first and prefer origin/main. The fetch is LOAD-BEARING, not best-effort: an origin ref that
# was never refreshed is exactly as stale as local main, and branching off it produced the stacked-PR
# clobber (one PR's lines silently dropped by a later PR's merge) this library exists to prevent.
# So when the repo HAS an origin but the fetch fails, fail LOUD: the caller aborts the worktree
# creation rather than derive a base from a possibly-stale ref. Flip GOVERN_BASE_FETCH_GATE=0 to
# restore the old best-effort fallback (branch off local main when the fetch fails). A repo with no
# origin at all (offline is indistinguishable from this for a local-only repo, and hermetic test
# stubs are local-only by construction) still falls back to local `main`.
wt_subrepo_base_ref() {
  local src="$1"
  if ! git -C "$src" remote get-url origin >/dev/null 2>&1; then
    echo "main"
    return 0
  fi
  if git -C "$src" fetch --quiet --prune origin 2>/dev/null; then
    if git -C "$src" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      echo "origin/main"
    else
      # Freshly fetched but no origin/main (master-default or empty remote): the local refs are
      # current, so local `main` is a safe base.
      echo "main"
    fi
    return 0
  fi
  if [ "${GOVERN_BASE_FETCH_GATE:-1}" = "1" ]; then
    echo "wt_subrepo_base_ref: fetch from origin failed for $src — refusing to derive a base from a possibly-stale ref (the stacked-PR clobber shape). Fix the remote (or go online), or set GOVERN_BASE_FETCH_GATE=0 to restore the old best-effort fallback." >&2
    return 1
  fi
  echo "main"
}
