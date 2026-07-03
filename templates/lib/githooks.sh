#!/usr/bin/env bash
# ── Shared helper: propagate the commit-attribution hook into cloned sub-repos ──
# SOURCE this file; it defines install_subrepo_attribution_hook().
#
# Background: the harness repo activates .githooks/prepare-commit-msg via
# `core.hooksPath=.githooks` (set by the setup wiring). That hook auto-appends the
# `Co-Authored-By` attribution trailer to AGENT commits (CLAUDECODE=1 / GOVERN_RUN=1) so
# attribution can't be forgotten. But each sub-repo is an INDEPENDENT git repo — it does NOT
# inherit the harness's core.hooksPath — so a worker's sub-repo commit would still be prose-only
# for the trailer.
#
# Fix: install JUST the prepare-commit-msg hook into every sub-repo. We deliberately copy the ONE
# attribution hook — NOT the whole .githooks/ dir — because .githooks/pre-push is HARNESS-ONLY (it
# rejects non-ticket-<N> / non-govern feature-branch pushes; a sub-repo legitimately receives
# feature-branch PRs, so that guard must never run there).
#
# Husky-safe: some sub-repos set `core.hooksPath=.husky/_` for lint-staged. We install into
# whatever hooks directory the repo ACTUALLY uses (honoring an existing core.hooksPath), so husky's
# pre-commit is left untouched and our prepare-commit-msg coexists beside it. `.husky/_/` is
# husky-gitignored, so dropping our hook there keeps the worktree clean; re-running setup /
# worktree:new refreshes it if a husky reinstall regenerates its wrappers.
#
# Idempotent: overwrites the installed hook each call (also keeps it in sync with the shared source).

# install_subrepo_attribution_hook <harness_root> <subrepo_path>
#   harness_root : path to the harness checkout/worktree (holds .githooks/prepare-commit-msg)
#   subrepo_path : path to the sub-repo (or its worktree) to install the hook into
# Prints a one-line ✓/⚠ status. Returns 0 on success, non-zero if it could not install.
install_subrepo_attribution_hook() {
  local root="$1" repo="$2"
  local name; name="$(basename "$repo")"
  local src="$root/.githooks/prepare-commit-msg"

  [ -f "$src" ] || { echo "  ⚠ $name: shared attribution hook missing ($src) — skipped" >&2; return 1; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "  ⚠ $name: not a git repo — skipped hook" >&2; return 1; }

  # Resolve the ACTIVE hooks directory: honor an existing core.hooksPath (husky's .husky/_ et al),
  # else git's default hooks path (the common dir for a worktree, so one install covers every
  # worktree of a plain sub-repo).
  local hp toplevel hooksdir
  hp="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$hp" ]; then
    case "$hp" in
      /*) hooksdir="$hp" ;;
      *)  toplevel="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"; hooksdir="$toplevel/$hp" ;;
    esac
  else
    hooksdir="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)"
    case "$hooksdir" in /*) : ;; *) hooksdir="$repo/$hooksdir" ;; esac
  fi
  [ -n "$hooksdir" ] || { echo "  ⚠ $name: could not resolve hooks dir — skipped" >&2; return 1; }

  mkdir -p "$hooksdir" \
    && cp "$src" "$hooksdir/prepare-commit-msg" \
    && chmod +x "$hooksdir/prepare-commit-msg" \
    && { echo "  ✓ $name: attribution hook → $hooksdir/prepare-commit-msg"; return 0; }
  echo "  ⚠ $name: failed to install attribution hook into $hooksdir" >&2
  return 1
}
