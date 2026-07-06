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

# resolve_subrepo_hooksdir <subrepo_path>
#   Echo the ABSOLUTE active hooks directory for the repo: honor an existing core.hooksPath
#   (husky's .husky/_ et al), else git's default hooks path (the common dir for a worktree, so one
#   install covers every worktree of a plain sub-repo). Empty stdout + non-zero on failure.
#   Shared by both installers AND the doctor audit so all three resolve identically.
resolve_subrepo_hooksdir() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
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
  [ -n "$hooksdir" ] || return 1
  printf '%s\n' "$hooksdir"
}

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

  local hooksdir
  hooksdir="$(resolve_subrepo_hooksdir "$repo")" || { echo "  ⚠ $name: could not resolve hooks dir — skipped" >&2; return 1; }

  mkdir -p "$hooksdir" \
    && cp "$src" "$hooksdir/prepare-commit-msg" \
    && chmod +x "$hooksdir/prepare-commit-msg" \
    && { echo "  ✓ $name: attribution hook → $hooksdir/prepare-commit-msg"; return 0; }
  echo "  ⚠ $name: failed to install attribution hook into $hooksdir" >&2
  return 1
}

# ── Optional per-sub-repo pre-commit lint-fix hook ──────────────────────────
# Installs .githooks/pre-commit from the harness root into each sub-repo's hooks dir. The hook itself
# is a NO-OP unless workspace.sh defines WSP_LINT_FIX_CMD (see templates/lib/workspace.sh) — so this
# installer is safe to run unconditionally alongside the attribution hook. It is CHAIN-SAFE: if a
# sub-repo already has a pre-commit that is NOT ours (husky, lefthook, hand-rolled), it is left in
# place and skipped with a "·" note. Idempotent for our own hook via a marker line the pre-commit
# template carries; re-installing refreshes it.
#
# install_subrepo_pre_commit_hook <harness_root> <subrepo_path>
install_subrepo_pre_commit_hook() {
  local root="$1" repo="$2"
  local name; name="$(basename "$repo")"
  local src="$root/.githooks/pre-commit"

  [ -f "$src" ] || { echo "  ⚠ $name: shared pre-commit hook missing ($src) — skipped" >&2; return 1; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "  ⚠ $name: not a git repo — skipped pre-commit hook" >&2; return 1; }

  # Same hooks-dir resolver as install_subrepo_attribution_hook — honor an existing core.hooksPath
  # (husky's .husky/_, lefthook, etc.), else git's default hooks path.
  local hooksdir
  hooksdir="$(resolve_subrepo_hooksdir "$repo")" || { echo "  ⚠ $name: could not resolve hooks dir — skipped pre-commit hook" >&2; return 1; }

  local target="$hooksdir/pre-commit"
  local marker='wsp-lint-fix marker'
  # Skip if a NON-ours pre-commit already exists (framework or operator-authored). Only overwrite
  # when the file is missing OR was previously installed by us (marker line present).
  if [ -e "$target" ] && ! grep -qF "$marker" "$target" 2>/dev/null; then
    echo "  · $name: existing pre-commit hook — leaving in place (workspace pre-commit skipped)"
    return 0
  fi

  mkdir -p "$hooksdir" \
    && cp "$src" "$target" \
    && chmod +x "$target" \
    && { echo "  ✓ $name: pre-commit hook → $target"; return 0; }
  echo "  ⚠ $name: failed to install pre-commit hook into $hooksdir" >&2
  return 1
}

# ── Read-only audit: is a sub-repo's installed hook set still what we installed? ──────────────
# A framework reinstall (husky's `prepare` on `npm install`) regenerates its hooks dir unconditionally,
# wiping the attribution/pre-commit hooks we dropped there. Nothing else notices — the root's
# core.hooksPath is untouched. This is the seam doctor.sh uses to surface a stubbed sub-repo.
#
# audit_subrepo_hooks <harness_root> <subrepo_path>
#   Pure read (no writes). Echoes exactly TWO lines — one per managed hook:
#       prepare-commit-msg <state>
#       pre-commit         <state>
#   States:
#     match      — installed hook is byte-identical to .githooks/<hook>
#     mismatch   — a hook exists at the resolved dir but differs from .githooks/<hook>
#                  (husky/framework stub wiped ours, or a stale copy) — a FAULT for attribution
#     stale-ours — pre-commit only: carries OUR marker but differs from the source (needs refresh)
#     foreign    — pre-commit only: a non-ours hook is present (no marker) — legitimately left alone
#     absent     — no hook at the resolved dir (FAULT for attribution; fine/optional for pre-commit)
#     skip       — not a git repo / hooks dir unresolvable / shared source missing — nothing to say
#   The caller decides which states are faults (see doctor.sh): attribution mismatch/absent are
#   faults; pre-commit is only a fault when stale-ours (foreign/absent/match are all acceptable).
audit_subrepo_hooks() {
  local root="$1" repo="$2"
  local hooksdir attr_src pc_src attr_state pc_state marker='wsp-lint-fix marker'
  attr_src="$root/.githooks/prepare-commit-msg"
  pc_src="$root/.githooks/pre-commit"

  if ! hooksdir="$(resolve_subrepo_hooksdir "$repo")"; then
    printf 'prepare-commit-msg skip\npre-commit skip\n'
    return 0
  fi

  # ── prepare-commit-msg (attribution) ──
  if [ ! -f "$attr_src" ]; then
    attr_state="skip"                       # no canonical source to compare against
  elif [ ! -e "$hooksdir/prepare-commit-msg" ]; then
    attr_state="absent"
  elif cmp -s "$attr_src" "$hooksdir/prepare-commit-msg"; then
    attr_state="match"
  else
    attr_state="mismatch"
  fi

  # ── pre-commit (optional lint-fix; chain-safe) ──
  if [ ! -f "$pc_src" ]; then
    pc_state="skip"
  elif [ ! -e "$hooksdir/pre-commit" ]; then
    pc_state="absent"
  elif cmp -s "$pc_src" "$hooksdir/pre-commit"; then
    pc_state="match"
  elif grep -qF "$marker" "$hooksdir/pre-commit" 2>/dev/null; then
    pc_state="stale-ours"                    # ours but drifted → a re-install would refresh it
  else
    pc_state="foreign"                       # framework/operator hook — installer leaves it alone
  fi

  printf 'prepare-commit-msg %s\npre-commit %s\n' "$attr_state" "$pc_state"
}
