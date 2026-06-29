#!/usr/bin/env bash
# Multi-session sync — bring every sub-repo's local main up to date with origin
# without disturbing the working state, prune dead branches, and repair the
# duplicate branch.*.merge config bug (a `git push -u origin main` run from a
# feature branch corrupts the upstream config → a later pull fails with
# "Cannot fast-forward to multiple branches").
#
# What it does, per sub-repo:
#   1. fetch --prune origin
#   2. update local main to origin/main (no checkout if you're on a feature
#      branch — uses `git fetch origin main:main`)
#   3. detect + auto-repair duplicate `branch.<X>.merge` entries
#   4. delete local feature branches whose upstream is gone AND that are already
#      merged into origin/main
#   5. print a one-line summary
#
# Skips any sub-repo that has uncommitted/unstaged changes (won't touch your
# dirty working tree) — prints "DIRTY — skipped" so you know to commit/stash.
#
# Run at start of a session, before branching new work. Generic — repo list from
# scripts/lib/workspace.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

ANSI_RESET=$'\033[0m'
ANSI_GREEN=$'\033[32m'
ANSI_YELLOW=$'\033[33m'
ANSI_RED=$'\033[31m'
ANSI_DIM=$'\033[2m'

[ -t 1 ] || { ANSI_RESET=""; ANSI_GREEN=""; ANSI_YELLOW=""; ANSI_RED=""; ANSI_DIM=""; }

ok()   { printf "  %s✓%s %s\n" "$ANSI_GREEN"  "$ANSI_RESET" "$1"; }
warn() { printf "  %s⚠%s %s\n" "$ANSI_YELLOW" "$ANSI_RESET" "$1"; }
fail() { printf "  %s✗%s %s\n" "$ANSI_RED"    "$ANSI_RESET" "$1"; }
dim()  { printf "  %s%s%s\n"   "$ANSI_DIM"    "$1" "$ANSI_RESET"; }

# Repair duplicate branch.<name>.merge entries.
# Cause: an earlier `git push -u origin main` was run from a feature branch and
# corrupted the upstream config. Symptom: `fatal: Cannot fast-forward to multiple
# branches.` on pull.
repair_duplicate_upstream() {
  local local_branches
  local_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
  for b in $local_branches; do
    local count
    count=$(git config --get-all "branch.$b.merge" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
      local intended
      intended="refs/heads/$b"
      git config --unset-all "branch.$b.merge" 2>/dev/null || true
      git config "branch.$b.merge" "$intended"
      warn "repaired duplicate branch.$b.merge → $intended"
    fi
  done
}

sync_repo() {
  local sub="$1"
  local dir="$ROOT/$sub"
  printf "\n%s── %s ──%s\n" "$ANSI_DIM" "$sub" "$ANSI_RESET"

  if [ ! -d "$dir/.git" ]; then
    warn "$sub/ not a git repo — skipped"
    return
  fi

  cd "$dir" || { fail "cd $dir failed"; return; }

  # 1. dirty check — never touch dirty trees
  local dirty
  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  if [ "$dirty" -gt 0 ]; then
    warn "DIRTY ($dirty files modified/untracked) — skipped. Commit or stash first."
    return
  fi

  # 2. repair config first so subsequent steps don't trip
  repair_duplicate_upstream

  # 3. fetch + prune
  git fetch --prune origin >/dev/null 2>&1 || { fail "fetch failed"; return; }
  ok "fetched + pruned"

  local current
  current=$(git branch --show-current)

  # 4. update local main from origin/main without checkout if on a feature branch
  if [ "$current" = "main" ]; then
    if git pull --ff-only >/dev/null 2>&1; then
      local count
      count=$(git rev-list --count HEAD@{1}..HEAD 2>/dev/null || echo 0)
      if [ "$count" -gt 0 ]; then
        ok "main fast-forwarded $count commits"
      else
        ok "main already up-to-date"
      fi
    else
      warn "could not ff main from origin (diverged?) — inspect manually"
    fi
  else
    # On feature branch — update local main in place
    if git fetch origin main:main >/dev/null 2>&1; then
      ok "local main updated (you're on $current)"
    else
      dim "could not update main from here (likely no upstream change, OR local main diverged)"
    fi
  fi

  # 5. delete branches whose upstream is gone (merged + remote-deleted)
  local merged_branches
  merged_branches=$(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/ \
    | awk '$2 == "[gone]" { print $1 }')

  for b in $merged_branches; do
    if [ "$b" = "$current" ]; then
      dim "skipping current branch $b (upstream gone)"
      continue
    fi
    # Check if it's merged into origin/main
    if git merge-base --is-ancestor "$b" origin/main 2>/dev/null; then
      git branch -D "$b" >/dev/null 2>&1
      ok "deleted merged branch $b"
    else
      dim "$b has [gone] upstream but isn't merged into origin/main — leaving alone"
    fi
  done

  # 6. final state
  local pr_branches
  pr_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^main$' || true)
  if [ -n "$pr_branches" ]; then
    local count
    count=$(echo "$pr_branches" | wc -l | tr -d ' ')
    dim "still on $count non-main branch(es): $(echo "$pr_branches" | tr '\n' ' ')"
  fi
}

# Also sync the workspace root (it's a git repo too).
sync_root() {
  printf "\n%s── %s ──%s\n" "$ANSI_DIM" "root (meta-repo)" "$ANSI_RESET"
  cd "$ROOT" || return
  if [ ! -d ".git" ]; then
    dim "workspace root not a git repo — skipped"
    return
  fi
  local dirty
  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  if [ "$dirty" -gt 0 ]; then
    warn "DIRTY ($dirty files) — skipped"
    return
  fi
  repair_duplicate_upstream
  if git pull --ff-only >/dev/null 2>&1; then
    ok "root main up to date"
  else
    dim "no remote tracking or already up to date"
  fi
}

sync_root
for sub in "${REPOS[@]}"; do
  sync_repo "$sub"
done

printf "\n%s── done ──%s\n" "$ANSI_DIM" "$ANSI_RESET"
printf "  Run %s%s run status%s to see the final state.\n" "$ANSI_GREEN" "$ROOT_PM" "$ANSI_RESET"
