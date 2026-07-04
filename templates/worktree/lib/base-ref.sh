#!/usr/bin/env bash
# wt_subrepo_base_ref <repo-dir> — echo the git ref a NEW sub-repo worktree should branch off.
#
# #29: cut sub-repo worktrees off the freshly-fetched origin/main, NOT the main checkout's LOCAL
# `main`. The main checkout is read-only / rarely-pulled (worktree-only workflow), so each sub-repo's
# local `main` drifts behind its remote; branching a ticket/feature worktree off that stale base makes
# PRs born CONFLICTING against current origin/main even when the change is trivial (an upstream commit
# touched the same file since the last local pull).
#
# Fetch first and prefer origin/main; fall back to local `main` only when there is no reachable origin
# — offline, or a local-only repo with no remote (such as the hermetic test stubs). Always succeeds
# (best-effort fetch); a fetch failure is not fatal, it just means we branch off whatever local main is.
wt_subrepo_base_ref() {
  local src="$1"
  if git -C "$src" remote get-url origin >/dev/null 2>&1 \
     && git -C "$src" fetch --quiet origin main 2>/dev/null \
     && git -C "$src" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    echo "origin/main"
  else
    echo "main"
  fi
}
