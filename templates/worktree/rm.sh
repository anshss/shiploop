#!/usr/bin/env bash
# Remove a worktree: clean up its deploys, then git-worktree-remove each sub-repo
# and the meta-worktree, then free the registry slot.
#
# Usage:  <pm> run worktree:rm -- <name> [--force] [--keep-branch]
#         <pm> run worktree:rm -- --sweep [--force]
#
# --force        skip the dirty-tree refusal
# --keep-branch  don't delete the sub-repo branches after worktree removal
# --sweep        remove every PACKET-CREATED worktree (a `.dispatch-packet.md` at its root,
#                which govern:dispatch-packet writes) that is orphaned: the packet's own creation
#                timestamp is older than GOVERN_AGENT_WALLCLOCK (default 3600s), AND every sub-repo
#                plus the meta root is clean, AND none has a commit beyond its base. Anything else
#                (too young, dirty, or holding commits, pushed or not) is REPORTED, never removed: a
#                worker that is genuinely still running, or that finished with real work sitting on
#                disk, must never be swept out from under it. A worktree with no packet at all
#                (never created by govern:dispatch-packet) is outside --sweep's scope entirely.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"

NAME=""
FORCE=0
KEEP_BRANCH=0
SWEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
    --sweep) SWEEP=1; shift ;;
    -h|--help)
      echo "usage: $ROOT_PM run worktree:rm -- <name> [--force] [--keep-branch]"
      echo "       $ROOT_PM run worktree:rm -- --sweep [--force]"
      exit 0
      ;;
    --) shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"; else echo "extra arg: $1" >&2; exit 2; fi
      shift
      ;;
  esac
done

if [ "$SWEEP" -eq 1 ]; then
  [ -z "$NAME" ] || { echo "--sweep takes no <name>" >&2; exit 2; }
else
  [ -n "$NAME" ] || { echo "usage: $ROOT_PM run worktree:rm -- <name> [--force] [--keep-branch]" >&2; exit 2; }
  [ "$NAME" = "__main__" ] && { echo "refusing to remove main checkout" >&2; exit 1; }
fi

# Commits on HEAD not reachable from the repo's remote. Prefer the branch's configured upstream;
# fall back to origin/main (the meta worktree is a DETACHED origin/main checkout with no upstream);
# then local main (a remote-less root has no origin/main to fall back to at all — a missing remote
# changes WHICH ref we compare against, never whether we check: the root is detect-never-impose, so
# it must still be checked, just against local main instead); if none of those resolve (no
# remote-tracking ref and no local main) we can't compare, so report 0 — never block on a case we
# can't measure.
unpushed_count() { # <dir>
  local dir="$1"
  if git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0
  elif git -C "$dir" rev-parse --verify origin/main >/dev/null 2>&1; then
    git -C "$dir" rev-list --count 'origin/main..HEAD' 2>/dev/null || echo 0
  elif git -C "$dir" rev-parse --verify main >/dev/null 2>&1; then
    git -C "$dir" rev-list --count 'main..HEAD' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Check one worktree dir; sets the shared `had_problem` flag and prints why. A non-git dir is skipped.
had_problem=0
check_worktree_dir() { # <dir> <label>
  local dir="$1" label="$2" n
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "✗ '$label' has uncommitted changes in $dir" >&2
    had_problem=1
  fi
  n="$(unpushed_count "$dir")"
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    echo "✗ '$label' has $n commit(s) not pushed to its remote in $dir" >&2
    had_problem=1
  fi
}

# Kill a worktree's orphaned dev stack BEFORE removing the dir (Leak B). `git worktree remove`
# deletes the tree but leaves any dev process (orchestrator / server / Next.js) that was booted
# inside it running — a prod-pointed process then outlives its removed worktree as a zombie
# squatting the slot's port. The kill is OWNERSHIP-scoped: a process on a slot port is killed ONLY
# if its cwd is under THIS worktree, so a parallel session on a colliding slot is never
# cross-killed. Ports come from the worktree's own worktree.env (the WORKTREE_<REPO>_PORT vars
# written by new.sh: slot × SLOT_PORT_STEP offset). If worktree.env is gone we can't resolve the
# ports/owner root — skip gracefully, never an unscoped kill.
# Top-level (not nested in wt_remove_one) on purpose: test-worktree-rm-stack-kill.sh extracts this
# exact function body by name to exercise the shipped implementation directly.
kill_worktree_stack() {
  local wt_root="$1" envf="$1/worktree.env"
  [ -f "$envf" ] || { echo "  (no worktree.env — skipping stack kill; nothing to scope to)"; return 0; }
  # shellcheck disable=SC1090
  source "$envf"
  local var port pids pid pcwd killed=0
  # Iterate every WORKTREE_<REPO>_PORT the worktree.env declares (repo-agnostic — no REPOS needed, so
  # this stays self-contained when extracted for testing). WORKTREE_SLOT/OFFSET are skipped (not _PORT).
  for var in ${!WORKTREE_*}; do
    case "$var" in *_PORT) : ;; *) continue ;; esac
    port="${!var:-}"
    [ -n "$port" ] || continue
    pids=$(lsof -ti tcp:"$port" 2>/dev/null) || true
    for pid in $pids; do
      pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      case "$pcwd" in
        "$wt_root"|"$wt_root"/*) kill -9 "$pid" 2>/dev/null && killed=$((killed + 1)) || true ;;
        *) : ;;  # a process from another checkout on this port — never ours to kill
      esac
    done
  done
  [ "$killed" -gt 0 ] && echo "  killed $killed orphaned stack process(es) owned by this worktree"
  return 0
}

# ── the actual removal, factored out so both the direct CLI path and --sweep call ONE
# implementation. Reads NAME/WORKTREE_PATH/FORCE/KEEP_BRANCH from the caller's scope. ────────────
wt_remove_one() {
  had_problem=0
  if [ "$FORCE" -ne 1 ]; then
    for repo in "${REPOS[@]}"; do
      [ -d "$WORKTREE_PATH/$repo" ] || continue
      check_worktree_dir "$WORKTREE_PATH/$repo" "$repo"
    done
    check_worktree_dir "$WORKTREE_PATH" "meta"
    if [ "$had_problem" -ne 0 ]; then
      echo "  pass --force to discard, or commit/push them first" >&2
      return 1
    fi
  fi

  # Run the project-specific session-cleanup hook before tearing down (best-effort).
  # This is where project-specific teardown lives — e.g. closing billable test
  # deploys against a cloud provider. We do NOT bake that here because it is
  # entirely project-specific.
  if [ -x "$ROOT/scripts/lib/session-cleanup.sh" ]; then
    echo "→ running scripts/lib/session-cleanup.sh for slot's stack"
    ( cd "$WORKTREE_PATH" && bash "$ROOT/scripts/lib/session-cleanup.sh" ) || \
      echo "  (session-cleanup failed — continuing; stack may already be down)"
  fi

  echo "→ killing this worktree's dev stack (ownership-scoped)"
  kill_worktree_stack "$WORKTREE_PATH"

  # Remove each sub-repo worktree
  for repo in "${REPOS[@]}"; do
    src="$ROOT/$repo"
    dst="$WORKTREE_PATH/$repo"
    [ -d "$src/.git" ] || [ -f "$src/.git" ] || continue
    if [ -e "$dst" ]; then
      echo "→ removing $repo worktree"
      git -C "$src" worktree remove --force "$dst" 2>&1 | sed "s/^/[$repo] /" || true
    fi
    # Delete the feature branch unless --keep-branch
    if [ "$KEEP_BRANCH" -ne 1 ]; then
      if git -C "$src" rev-parse --verify "$NAME" >/dev/null 2>&1; then
        git -C "$src" branch -D "$NAME" 2>&1 | sed "s/^/[$repo] /" || true
      fi
    fi
  done

  # Remove meta-repo worktree. The meta root is detached at main (no <name>
  # branch — workspace files commit directly to main in the main checkout), so
  # there's nothing to `branch -D` here. Guard the legacy case where an older
  # worktree:new created a meta branch, so cleaning up pre-existing worktrees
  # still works.
  echo "→ removing meta-repo worktree"
  git -C "$ROOT" worktree remove --force "$WORKTREE_PATH" 2>&1 | sed 's/^/[meta] /' || true
  if [ "$KEEP_BRANCH" -ne 1 ] && git -C "$ROOT" rev-parse --verify "$NAME" >/dev/null 2>&1; then
    git -C "$ROOT" branch -D "$NAME" 2>&1 | sed 's/^/[meta] /' || true
  fi

  # Free slot
  FREED_SLOT=$(wt_registry_with_lock wt_registry_remove "$NAME")
  echo "✓ Worktree '$NAME' removed; slot $FREED_SLOT freed"
  return 0
}

if [ "$SWEEP" -eq 0 ]; then
  WORKTREE_PATH=$(wt_registry_path_for "$NAME") || exit 1
  wt_remove_one
  exit $?
fi

# ── --sweep: packet-created, orphaned worktrees only ─────────────────────────────────────────────
packet_epoch() { # <packet-file> -> epoch, "" if unparseable
  grep -m1 -oE 'GOVERN:PACKET-CREATED [0-9]+' "$1" 2>/dev/null | awk '{print $2}'
}

# Commits on HEAD beyond the repo's base branch (origin's default, else origin/main, else local
# main), deliberately NOT unpushed_count: a pushed branch with an open PR still holds real work, and
# its upstream would report 0. No resolvable base reports 1, so an unmeasurable tree is kept.
beyond_base_count() { # <dir>
  local dir="$1" base
  base="$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "$base" ]; then
    if git -C "$dir" rev-parse --verify -q origin/main >/dev/null 2>&1; then base=origin/main
    elif git -C "$dir" rev-parse --verify -q main >/dev/null 2>&1; then base=main
    else echo 1; return 0
    fi
  fi
  git -C "$dir" rev-list --count "$base..HEAD" 2>/dev/null || echo 1
  return 0
}

# rc 0 = qualifies for removal; rc 1 = does not (sets $SWEEP_REASON). Never touches disk.
sweep_candidate_ok() { # <path>
  local path="$1"
  local packet="$path/.dispatch-packet.md"
  local epoch now cap age dir label n
  epoch="$(packet_epoch "$packet")"
  if [ -z "$epoch" ]; then
    SWEEP_REASON="no parseable creation timestamp in .dispatch-packet.md"
    return 1
  fi
  cap="${GOVERN_AGENT_WALLCLOCK:-3600}"
  now="$(date +%s)"
  age=$((now - epoch))
  if [ "$age" -lt "$cap" ]; then
    SWEEP_REASON="packet is only ${age}s old (< ${cap}s cap)"
    return 1
  fi
  for label in meta "${REPOS[@]}"; do
    if [ "$label" = meta ]; then dir="$path"; else dir="$path/$label"; fi
    { [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; } || continue
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      SWEEP_REASON="'$label' has uncommitted changes"
      return 1
    fi
    n="$(beyond_base_count "$dir")"
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      SWEEP_REASON="'$label' has $n commit(s) beyond its base"
      return 1
    fi
  done
  return 0
}

swept=0
kept=0
while IFS=$'\t' read -r _name _path; do
  [ -n "$_name" ] && [ "$_name" != "__main__" ] || continue
  [ -e "$_path" ] || continue
  [ -f "$_path/.dispatch-packet.md" ] || continue   # not packet-created: outside --sweep's scope
  SWEEP_REASON=""
  if sweep_candidate_ok "$_path"; then
    echo "→ sweeping orphaned worktree '$_name' ($_path)"
    NAME="$_name"; WORKTREE_PATH="$_path"
    wt_remove_one || echo "  (removal of '$_name' hit a problem — left in place)" >&2
    swept=$((swept + 1))
  else
    echo "  kept '$_name' ($_path): $SWEEP_REASON"
    kept=$((kept + 1))
  fi
done < <(wt_registry_read | jq -r '.slots[] | select(.name != "__main__") | "\(.name)\t\(.path)"' 2>/dev/null)

echo "✓ sweep done: $swept removed, $kept kept"
