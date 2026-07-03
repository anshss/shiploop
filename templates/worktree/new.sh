#!/usr/bin/env bash
# Allocate a slot and create a meta-repo worktree at $WORKTREE_BASE/<name>/
# with sub-repo worktrees branched off <name>. The meta root itself is detached
# at main (workspace files commit directly to main in the main checkout, never
# on a worktree branch — see the `worktree add --detach` below).
#
# Usage:  <pm> run worktree:new -- <name> [--only a,b] [--skip-bootstrap]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"
# shellcheck source=../lib/githooks.sh
source "$ROOT/scripts/lib/githooks.sh" 2>/dev/null || true

NAME=""
ONLY=""
SKIP_BOOTSTRAP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    -h|--help)
      echo "usage: $ROOT_PM run worktree:new -- <name> [--only a,b] [--skip-bootstrap]"
      exit 0
      ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"; else echo "extra arg: $1" >&2; exit 2; fi
      shift
      ;;
  esac
done

[ -n "$NAME" ] || { echo "usage: $ROOT_PM run worktree:new -- <name> [--only a,b] [--skip-bootstrap]" >&2; exit 2; }

# Validate name — safe for paths and branches
if ! [[ "$NAME" =~ ^[a-z0-9._/-]+$ ]]; then
  echo "name must match [a-z0-9._/-]+; got: $NAME" >&2
  exit 2
fi

# Default sub-repo scope: all of them
if [ -z "$ONLY" ]; then ONLY="$(wsp_repos_csv)"; fi

# Disk-space sanity check (< 5 GB free in HOME). MUST be non-interactive-safe: a headless
# caller (e.g. a govern worker) has no TTY, so a bare `read` hits EOF and `confirm` stays
# empty → the guard exits silently, read as a phantom worker "failure".
# So: honor WORKTREE_ASSUME_YES=1 to proceed unattended, only prompt when stdin IS a TTY, and
# on no-TTY exit with a DISTINCT code (3) + actionable message instead of a silent abort.
# Test seams: WORKTREE_FREE_GB_OVERRIDE forces the measured free space; WORKTREE_DISK_CHECK_ONLY
# exits right after the guard (so branch logic is testable without creating a real worktree).
free_gb="${WORKTREE_FREE_GB_OVERRIDE:-$(df -k "$HOME" | awk 'NR==2 {printf "%d", $4/1024/1024}')}"
if [ "$free_gb" -lt 5 ]; then
  if [ "${WORKTREE_ASSUME_YES:-0}" = "1" ]; then
    echo "⚠ disk free <5GB in \$HOME ($free_gb GB) — proceeding (WORKTREE_ASSUME_YES=1)" >&2
  elif [ -t 0 ]; then
    echo "⚠ disk free <5GB in \$HOME ($free_gb GB). Continue? [y/N]" >&2
    read -r confirm
    [ "$confirm" = "y" ] || exit 1
  else
    echo "✗ disk free <5GB in \$HOME ($free_gb GB) and no TTY to confirm." >&2
    echo "  Free space (e.g. '$ROOT_PM run worktree:status' then remove stale worktrees)," >&2
    echo "  or set WORKTREE_ASSUME_YES=1 to proceed unattended." >&2
    exit 3
  fi
fi
[ "${WORKTREE_DISK_CHECK_ONLY:-0}" = "1" ] && exit 0

WORKTREE_PATH="$WORKTREE_BASE/$NAME"

if [ -e "$WORKTREE_PATH" ]; then
  echo "path already exists: $WORKTREE_PATH" >&2
  exit 1
fi

# Atomically pick a free slot AND register the entry under one lock so two
# parallel `worktree:new` calls can't both grab the same slot. (Splitting the
# alloc and the registry-add into two locks let a race overwrite the loser's
# entry — the worktree existed on disk but vanished from the registry.)
SLOT=$(wt_registry_with_lock wt_registry_alloc_and_register "$NAME" "$WORKTREE_PATH") || exit 1

echo "Allocating slot $SLOT for '$NAME'"
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create the meta-repo worktree DETACHED at main (not on a feature branch).
# Workspace policy: meta-repo / workspace-coordination files (CLAUDE.md,
# tickets.md, learnings.md, scripts/) commit directly to main in the
# main checkout and are never branched. The worktree only needs the workspace
# files present (scripts, .env, worktree.env) to run the dev stack — it never
# commits them. A detached HEAD provides that scaffold while making it
# structurally impossible to accidentally land workspace files on a stray
# branch. (Also: git refuses to check out `main` in a second worktree, so
# detached is the only way to mirror main here.)
git -C "$ROOT" worktree add --detach "$WORKTREE_PATH" main 2>&1 | sed 's/^/[meta] /'

# For each sub-repo, create a worktree at <meta-worktree>/<repo>/.
# Sub-repos in ONLY: branch <name>. Others: branch main (read-only convention).
for repo in "${REPOS[@]}"; do
  src="$ROOT/$repo"
  dst="$WORKTREE_PATH/$repo"
  if [ ! -d "$src/.git" ] && [ ! -f "$src/.git" ]; then
    echo "[$repo] (missing in main checkout, skipping)"
    continue
  fi

  # The meta worktree create made a placeholder dir from the tracked tree, but
  # sub-repos are *also* git repos, so we need to swap that placeholder for a
  # real sub-repo worktree. (In practice the dir won't exist because sub-repo
  # paths are gitignored at workspace root, but rm -rf is defensive.)
  rm -rf "$dst"

  if [[ ",$ONLY," == *",$repo,"* ]]; then
    # Branch <name>: create if missing, check out if existing
    if git -C "$src" rev-parse --verify "$NAME" >/dev/null 2>&1; then
      echo "[$repo] branch '$NAME' exists, checking out"
      git -C "$src" worktree add "$dst" "$NAME" 2>&1 | sed "s/^/[$repo] /"
    else
      echo "[$repo] creating branch '$NAME' from main"
      git -C "$src" worktree add -b "$NAME" "$dst" main 2>&1 | sed "s/^/[$repo] /"
    fi
  else
    # Not in --only: a DETACHED checkout at main (read-only convention). Must be
    # --detach, NOT `worktree add <dst> main`: git refuses to check out a branch
    # already checked out elsewhere, and the main checkout normally holds `main`,
    # so a plain `worktree add main` FAILS with "'main' is already used by worktree
    # at <main-checkout>" and leaves this sub-repo with NO checkout — while the run
    # still "succeeds" (the per-repo error just scrolls past). That silently breaks
    # the headline use case (run the full stack in a worktree, validate via the real
    # UI) whenever --only scopes to a subset of repos: the others end up empty. A
    # detached-at-main checkout is runnable and never collides — the same pattern the
    # meta worktree uses above at the `worktree add --detach` line.
    echo "[$repo] not in --only, detached worktree at main (read-only)"
    git -C "$src" worktree add --detach "$dst" main 2>&1 | sed "s/^/[$repo] /"
  fi

  # Copy sub-repo .env-style files from the main checkout. Only copy when the
  # file is NOT tracked in the source repo — if it's tracked (e.g. a repo that
  # commits its .env), the git worktree checkout already provides the canonical
  # version and overwriting it would make the fresh worktree dirty from the
  # moment of creation. The whole point of copying is to ferry gitignored
  # secrets into the worktree.
  copy_env_if_untracked() {
    local file="$1"  # path relative to $src / $dst
    [ -f "$src/$file" ] || return 0
    if git -C "$src" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
      return 0   # tracked → worktree already has it
    fi
    cp "$src/$file" "$dst/$file"
  }
  copy_env_if_untracked ".env"
  copy_env_if_untracked ".env.local"

  # Propagate the commit-attribution hook into this sub-repo worktree so agent commits made
  # from inside the worktree carry the Co-Authored-By trailer too (husky repos use a per-worktree
  # core.hooksPath, so a main-checkout install doesn't always cover the worktree). Best-effort.
  if command -v install_subrepo_attribution_hook >/dev/null 2>&1; then
    install_subrepo_attribution_hook "$ROOT" "$dst" || true
  fi
done

# Copy workspace-root .env into the worktree. Scripts that resolve $ROOT/.env
# (test creds, workspace secrets, wallet refs, etc.) need this — sub-Claude
# sessions inside the worktree are otherwise blind to workspace secrets.
if [ -f "$ROOT/.env" ] && [ ! -f "$WORKTREE_PATH/.env" ]; then
  cp "$ROOT/.env" "$WORKTREE_PATH/.env"
  echo "[worktree] copied workspace .env into worktree root"
fi

# Write worktree.env — consumed by dev.sh, doctor.sh, status.sh, exec.sh,
# and the SessionEnd hook to know which ports belong to this worktree.
# Port exports are derived generically from REPO_PORTS in workspace.sh:
# each repo that declares a base port gets WORKTREE_<UPPER_REPO>_PORT set.
{
  echo "# Generated by $ROOT_PM run worktree:new on $(date -u +"%Y-%m-%dT%H:%M:%SZ")."
  echo "# Sourced by scripts/dev.sh, scripts/doctor.sh, scripts/status.sh, and hooks."
  echo "export WORKTREE_NAME=$NAME"
  echo "export WORKTREE_SLOT=$SLOT"
  echo "export WORKTREE_OFFSET=$((SLOT * SLOT_PORT_STEP))"
  echo ""
  for repo in "${REPOS[@]}"; do
    port=$(wsp_repo_port "$repo" "$SLOT")
    [ -n "$port" ] || continue
    upper=$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')
    echo "export WORKTREE_${upper}_PORT=$port"
  done
} > "$WORKTREE_PATH/worktree.env"

# (Registry was written atomically up front via alloc_and_register.)

# Bootstrap: run the project-specific worktree-bootstrap hook if present.
# This is where per-project "make the stack runnable in a fresh worktree" steps
# live — e.g. npm install, prisma generate, pointing a worktree DB at prod,
# setting a per-slot Redis DB number (e.g. REDIS_DB=<slot> so parallel
# orchestrators don't share BullMQ queues on the same localhost:6379 db 0).
# We do NOT bake any of that here because it is entirely project-specific.
# Pass --skip-bootstrap to defer to the user (e.g. you want the raw worktree
# layout without waiting for deps).
if [ "$SKIP_BOOTSTRAP" -eq 0 ]; then
  if [ -x "$ROOT/scripts/lib/worktree-bootstrap.sh" ]; then
    echo "[worktree] running scripts/lib/worktree-bootstrap.sh ..."
    bash "$ROOT/scripts/lib/worktree-bootstrap.sh" "$NAME" "$SLOT" "$WORKTREE_PATH" || true
  else
    echo "[worktree] no scripts/lib/worktree-bootstrap.sh found — skipping bootstrap"
    echo "  (create it to install deps, run codegen, wire the per-slot DB, etc.)"
  fi
fi

# Build a human-readable summary of the ports this worktree will use.
port_summary=""
for repo in "${REPOS[@]}"; do
  port=$(wsp_repo_port "$repo" "$SLOT")
  [ -n "$port" ] || continue
  port_summary="${port_summary}  ${repo}: http://localhost:${port}"$'\n'
done

cat <<EOF

✓ Worktree '$NAME' created at slot $SLOT.
  Path: $WORKTREE_PATH
${port_summary}
  Next:
    cd $WORKTREE_PATH
    $ROOT_PM run dev -- --only $(wsp_repos_csv)
EOF
