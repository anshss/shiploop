#!/usr/bin/env bash
# Allocate a slot and create a meta-repo worktree at $WORKTREE_BASE/<name>/
# with sub-repo worktrees branched off <name>. The meta root itself is detached
# at main (workspace files commit directly to main in the main checkout, never
# on a worktree branch — see the `worktree add --detach` below).
#
# Usage:  <pm> run worktree:new -- <name> [--only a,b] [--skip-bootstrap] [--base <branch>] [--adopt]
#
# --base <branch> bases the new sub-repo branch on that ref (origin/<branch> when
# reachable, else the local ref) instead of the sub-repo's default base — use it to
# stack a worktree on an open PR's branch, typically together with --only <repo>.
#
# Exit codes: 0 created/adopted · 1 path exists, or a sub-repo failed to check out ·
# 2 usage/bad name/base error · 3 no TTY to confirm the low-disk guard · 4 a commit-hook
# install failed · 5 (only with WORKTREE_DRIFT_GUARD=1, off by default) a sub-repo branch
# was behind origin/main with diverged commits and could not be fast-forwarded. A non-zero
# exit means the worktree may be PARTIALLY built (left on disk for inspection); never read
# a failure as success.
#
# --adopt hands back an EXISTING path at $WORKTREE_BASE/<name> instead of erroring, for a retry
# that wants the worktree a prior attempt on the same ticket left behind (worker-prompt.md has a
# worker preserve that tree on failure/timeout and append findings to .governor-notes.md in it, so
# a retry starting there skips re-deriving what the prior attempt already worked out). Off by
# default: without the flag an existing path is still a hard error, because silently reusing a
# tree would let two independent dispatches collide on one working copy. With the flag, adoption
# still only fires when the path is registered under this exact <name> (worker.md's own convention
# names a ticket dispatch's worktree `t<N>` or `t<N>-<slug>`, so the ticket identity IS <name>,
# and a registry match already proves "same ticket"), the sub-repos in --only are on branch <name>,
# and no other process has its cwd inside the tree. Any of those failing falls straight back to
# the same "path already exists" error as a plain retry with no flag. A dirty adopted tree is
# handed back exactly as it sits: no checkout/stash/reset/clean runs anywhere on this path,
# because those uncommitted edits are the preserved work a retry exists to reuse.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"
# shellcheck source=lib/base-ref.sh
source "$ROOT/scripts/worktree/lib/base-ref.sh"
# shellcheck source=../lib/githooks.sh
source "$ROOT/scripts/lib/githooks.sh" 2>/dev/null || true

NAME=""
ONLY=""
SKIP_BOOTSTRAP=0
BASE_OVERRIDE=""
ADOPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    --base) BASE_OVERRIDE="$2"; shift 2 ;;
    --adopt) ADOPT=1; shift ;;
    -h|--help)
      echo "usage: $ROOT_PM run worktree:new -- <name> [--only a,b] [--skip-bootstrap] [--base <branch>] [--adopt]"
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

[ -n "$NAME" ] || { echo "usage: $ROOT_PM run worktree:new -- <name> [--only a,b] [--skip-bootstrap] [--base <branch>] [--adopt]" >&2; exit 2; }

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
  if [ "$ADOPT" -eq 1 ]; then
    # Adoption only fires when every check below clears; the first miss falls straight
    # through to the same "path already exists" error a plain retry with no flag gets.
    ADOPT_REFUSAL=""

    # Registered under this exact name AND pointing at this exact path: the only way an
    # on-disk directory proves it is really the worktree a prior attempt on THIS name (and
    # so, by worker.md's `t<N>` convention, this ticket) left behind, rather than something
    # foreign that merely landed at the same path.
    REGISTERED_PATH="$(wt_registry_path_for "$NAME" 2>/dev/null || true)"
    if [ "$REGISTERED_PATH" != "$WORKTREE_PATH" ]; then
      ADOPT_REFUSAL="'$NAME' is not a registered worktree at this path"
    fi

    # No other process has its cwd inside the tree. Test seam: WORKTREE_ADOPT_HELD_OVERRIDE
    # forces this branch without needing a real background process holding the tree.
    if [ -z "$ADOPT_REFUSAL" ]; then
      if [ -n "${WORKTREE_ADOPT_HELD_OVERRIDE:-}" ]; then
        ADOPT_REFUSAL="held by another agent (pids: ${WORKTREE_ADOPT_HELD_OVERRIDE})"
      else
        ADOPT_LIVE_PIDS="$(lsof -a +D "$WORKTREE_PATH" -d cwd 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | tr '\n' ' ')"
        [ -n "$ADOPT_LIVE_PIDS" ] && ADOPT_REFUSAL="held by another agent (pids: ${ADOPT_LIVE_PIDS% })"
      fi
    fi

    # Every sub-repo this call scopes to (--only, default all) sits on the ticket's own
    # branch: a worktree left on some other branch (or detached) isn't a clean adoption
    # target even if the registry entry matches.
    if [ -z "$ADOPT_REFUSAL" ]; then
      for repo in "${REPOS[@]}"; do
        [[ ",$ONLY," == *",$repo,"* ]] || continue
        dst="$WORKTREE_PATH/$repo"
        { [ -d "$dst/.git" ] || [ -f "$dst/.git" ]; } || { ADOPT_REFUSAL="$repo has no checkout at $dst"; break; }
        branch="$(git -C "$dst" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
        if [ "$branch" != "$NAME" ]; then
          ADOPT_REFUSAL="$repo is on branch '$branch', not '$NAME'"
          break
        fi
      done
    fi

    if [ -z "$ADOPT_REFUSAL" ]; then
      # Adopted: skip slot allocation entirely and hand back the existing path. Report
      # per-repo dirty state so the caller knows what it's inheriting; never touch it:
      # no checkout/stash/reset/clean runs here, because those uncommitted edits are
      # exactly the preserved work adoption exists to hand back.
      ADOPT_DIRTY=""
      for repo in "${REPOS[@]}"; do
        [[ ",$ONLY," == *",$repo,"* ]] || continue
        dst="$WORKTREE_PATH/$repo"
        { [ -d "$dst/.git" ] || [ -f "$dst/.git" ]; } || continue
        if [ -n "$(git -C "$dst" status --porcelain 2>/dev/null)" ]; then
          ADOPT_DIRTY="$ADOPT_DIRTY $repo"
        fi
      done
      echo "Adopting existing worktree '$NAME' (slot $(wt_registry_slot_for "$NAME" 2>/dev/null || echo '?'))"
      if [ -n "$ADOPT_DIRTY" ]; then
        echo "  dirty:$ADOPT_DIRTY, uncommitted edits from the earlier attempt are left exactly as they are"
      else
        echo "  clean: no uncommitted changes in the adopted tree"
      fi
      if [ -f "$WORKTREE_PATH/.governor-notes.md" ]; then
        echo "  notes: $WORKTREE_PATH/.governor-notes.md, the earlier attempt's OWN notes, not verified fact"
      fi
      echo
      echo "✓ Worktree '$NAME' adopted."
      echo "  Path: $WORKTREE_PATH"
      exit 0
    fi

    echo "adoption refused ($ADOPT_REFUSAL): falling back to the path-exists error" >&2
  fi
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

# Run a `git worktree add ...` and report its REAL exit code, not the exit code of a pipe
# to sed (a pipe reports the FILTER's status). `git worktree add -b "$NAME" ...` swallowed
# through `| sed` used to look like success even when -b rejected an already-existing
# branch, leaving the repo never checked out while this script printed a clean success
# banner. Capture output into a var first, print it prefixed, THEN branch on the real
# status; no pipe involved in the status check at all.
wt_add() { # <repo-label> <src-repo-dir> <git worktree add ...args>
  local label="$1" src="$2"; shift 2
  local out rc
  out=$(git -C "$src" worktree add "$@" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed "s/^/[$label] /"
  return "$rc"
}

# For each sub-repo, create a worktree at <meta-worktree>/<repo>/.
# Sub-repos in ONLY: branch <name>. Others: detached at the base ref (read-only convention).
# Accumulates every hook-install failure across the loop so one exit reports every
# offender, not just the first.
HOOK_INSTALL_FAILURES=()
# Accumulates every sub-repo whose branch is behind origin/main AND could not be
# fast-forwarded (real diverged commits of its own, not just staleness). Only recorded
# under WORKTREE_DRIFT_GUARD=1; see the drift block inside the loop.
DRIFT_REFUSALS=()
# Repos actually confirmed checked out below; the closing port-summary banner is built
# from THIS, not from the static REPOS list, so a repo that failed to check out no longer
# appears in the banner as though it exists.
CREATED_REPOS=()
CHECKOUT_FAILED=0
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

  repo_rc=0
  if [[ ",$ONLY," == *",$repo,"* ]]; then
    # Branch <name>: create if missing, check out if existing
    if git -C "$src" rev-parse --verify "$NAME" >/dev/null 2>&1; then
      echo "[$repo] branch '$NAME' exists, checking out"
      wt_add "$repo" "$src" "$dst" "$NAME"; repo_rc=$?
    else
      if [ -n "$BASE_OVERRIDE" ]; then
        # A failed fetch must not fall through to a possibly-stale origin/<base>: that ref
        # silently becomes the branch base and produces the stacked-PR clobber shape (see
        # base-ref.sh). Fail loud under the gate; no-origin stubs keep the local-ref path.
        if git -C "$src" remote get-url origin >/dev/null 2>&1 \
           && ! git -C "$src" fetch origin "$BASE_OVERRIDE" --quiet 2>/dev/null \
           && [ "${GOVERN_BASE_FETCH_GATE:-1}" = "1" ]; then
          echo "[$repo] fetch of --base '$BASE_OVERRIDE' from origin failed — refusing to derive the base from a possibly-stale origin ref (GOVERN_BASE_FETCH_GATE=0 restores best-effort)" >&2
          exit 2
        fi
        if git -C "$src" rev-parse --verify "origin/$BASE_OVERRIDE" >/dev/null 2>&1; then
          base="origin/$BASE_OVERRIDE"
        elif git -C "$src" rev-parse --verify "$BASE_OVERRIDE" >/dev/null 2>&1; then
          base="$BASE_OVERRIDE"
        else
          echo "[$repo] --base '$BASE_OVERRIDE' not found (tried origin/$BASE_OVERRIDE and $BASE_OVERRIDE)" >&2; exit 2
        fi
      else
        base="$(wt_subrepo_base_ref "$src")" || exit 2   # origin/main when reachable; LOUD abort on fetch failure (see base-ref.sh)
      fi
      echo "[$repo] creating branch '$NAME' from $base"
      wt_add "$repo" "$src" -b "$NAME" "$dst" "$base"; repo_rc=$?
      if [ "$repo_rc" -ne 0 ] && git -C "$src" rev-parse --verify "$NAME" >/dev/null 2>&1; then
        # -b rejected because the branch now exists (created concurrently since the
        # rev-parse check above, or left behind by a prior partial run); reuse it
        # instead of a hard failure, same as the "branch exists" branch above.
        echo "[$repo] -b '$NAME' failed but the branch now exists; reusing it instead of -b"
        wt_add "$repo" "$src" "$dst" "$NAME"; repo_rc=$?
      fi
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
    base="$(wt_subrepo_base_ref "$src")" || exit 2   # origin/main when reachable; LOUD abort on fetch failure (see base-ref.sh)
    echo "[$repo] not in --only, detached worktree at $base (read-only)"
    wt_add "$repo" "$src" --detach "$dst" "$base"; repo_rc=$?
  fi

  # A repo present in the main checkout that failed to check out is a hard failure, not a
  # skip-and-continue: bootstrap can't install deps for a repo that was never checked out,
  # hook install below would fail against a nonexistent .git and mask the real cause behind
  # an unrelated "hook install failed" message, and letting the run reach the success banner
  # is exactly what made this failure read as a product/bootstrap issue instead of the
  # checkout swallow it actually was.
  if [ "$repo_rc" -ne 0 ] || { [ ! -d "$dst/.git" ] && [ ! -f "$dst/.git" ]; }; then
    echo "[$repo] FAILED: git worktree add did not produce a checkout at $dst (exit $repo_rc)" >&2
    CHECKOUT_FAILED=1
    continue
  fi
  CREATED_REPOS+=("$repo")

  # ── Drift guard: self-heal-or-refuse against origin/main ──
  # The "branch <name> already exists → check it out as-is" fast path above NEVER touches
  # origin/main at all. A repo that still holds a local branch named <name> left over from
  # an earlier session can come out many commits behind origin/main while its siblings take
  # the fresh `worktree add -b` path (which bases off a freshly-fetched origin/main) and
  # were never stale. The result is a PLAUSIBLE tree: it parses, type-checks, and only
  # conflicts at PR time. BEHAVIOR KNOB, OFF BY DEFAULT (WORKTREE_DRIFT_GUARD=1 enables):
  # enabling mutates a freshly checked-out branch (fast-forward) and can refuse creation
  # (exit 5) for a branch with real diverged commits, which changes what an existing
  # install does. When enabled, the heal/refuse is checked unconditionally; not just on
  # the branch-exists path; because a base-ref fetch failure falling back to local main
  # produces the same staleness from the other direction.
  if [ "${WORKTREE_DRIFT_GUARD:-0}" = "1" ] \
     && git -C "$dst" fetch origin --quiet 2>/dev/null \
     && git -C "$dst" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    behind="$(git -C "$dst" rev-list --count HEAD..origin/main 2>/dev/null)"
    if [ -n "$behind" ] && [ "$behind" -gt 0 ]; then
      if git -C "$dst" merge --ff-only origin/main >/dev/null 2>&1; then
        echo "[$repo] was $behind commit(s) behind origin/main; fast-forwarded"
      else
        DRIFT_REFUSALS+=("$repo:$behind")
      fi
    else
      echo "[$repo] up to date with origin/main"
    fi
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
  # core.hooksPath, so a main-checkout install doesn't always cover the worktree).
  # FATAL, not best-effort: a `cp` failure here (observed cause: a full disk) used to be
  # swallowed by `|| true`, so `worktree:new` printed a clean success banner over a
  # half-built tree that never got a pre-commit hook; the format guard silently never
  # runs, and the gap surfaces later as an unrelated review finding with no trace back to
  # the cause. Failures are accumulated and reported once below (exit 4).
  if command -v install_subrepo_attribution_hook >/dev/null 2>&1; then
    install_subrepo_attribution_hook "$ROOT" "$dst" || HOOK_INSTALL_FAILURES+=("$repo:prepare-commit-msg")
  fi
  # Propagate the workspace pre-commit lint-fix hook too. Same fatality. A chain-safe skip
  # (an existing FOREIGN pre-commit, e.g. husky's) returns 0 and is never a failure; only a
  # genuine install error (missing shared source, unresolvable hooks dir, failed cp) returns
  # non-zero.
  if command -v install_subrepo_pre_commit_hook >/dev/null 2>&1; then
    install_subrepo_pre_commit_hook "$ROOT" "$dst" || HOOK_INSTALL_FAILURES+=("$repo:pre-commit")
  fi
done

# Checked first: a repo that never checked out has no hooks to install and no drift to
# check, and reporting THIS as the failure (rather than the hook-install/drift noise a
# missing checkout produces downstream) is the whole point of the fix.
if [ "$CHECKOUT_FAILED" -eq 1 ]; then
  echo "" >&2
  echo "✗ worktree '$NAME' NOT fully created: one or more sub-repos failed to check out (see [repo] FAILED lines above)." >&2
  echo "  Checked out OK: ${CREATED_REPOS[*]:-<none>}" >&2
  exit 1
fi

if [ "${#HOOK_INSTALL_FAILURES[@]}" -gt 0 ]; then
  echo "✗ worktree hook install failed for: ${HOOK_INSTALL_FAILURES[*]}" >&2
  echo "  The worktree at $WORKTREE_PATH is left on disk for inspection (a common cause is disk" >&2
  echo "  space; see 'df -h'. Any cp/mkdir failure lands here). Free space or fix the" >&2
  echo "  cause, then re-run: $ROOT_PM run worktree:new -- $NAME --adopt" >&2
  exit 4
fi

if [ "${#DRIFT_REFUSALS[@]}" -gt 0 ]; then
  echo "✗ sub-repo branch(es) behind origin/main with real commits of their own; could not" >&2
  echo "  fast-forward (not a plain staleness): ${DRIFT_REFUSALS[*]}" >&2
  echo "  This worktree would build against a stale contract and only surface it as a PR-time" >&2
  echo "  conflict. The worktree at $WORKTREE_PATH is left on disk for inspection; resolve the" >&2
  echo "  divergence in the named repo(s) by hand, then re-run: $ROOT_PM run worktree:new -- $NAME --adopt" >&2
  exit 5
fi

# Copy workspace-root .env into the worktree. Scripts that resolve $ROOT/.env
# (test creds, workspace secrets, wallet refs, etc.) need this — sub-Claude
# sessions inside the worktree are otherwise blind to workspace secrets.
if [ -f "$ROOT/.env" ] && [ ! -f "$WORKTREE_PATH/.env" ]; then
  cp "$ROOT/.env" "$WORKTREE_PATH/.env"
  echo "[worktree] copied workspace .env into worktree root"
fi

# Write worktree.env — consumed by dev.sh, doctor.sh, exec.sh,
# and the SessionEnd hook to know which ports belong to this worktree.
# Port exports are derived generically from REPO_PORTS in workspace.sh:
# each repo that declares a base port gets WORKTREE_<UPPER_REPO>_PORT set.
{
  echo "# Generated by $ROOT_PM run worktree:new on $(date -u +"%Y-%m-%dT%H:%M:%SZ")."
  echo "# Sourced by scripts/dev.sh, scripts/doctor.sh, and hooks."
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
#
# IF YOUR BOOTSTRAP INSTALLS DEPS CONCURRENTLY, CAP IT with scripts/lib/install-semaphore.sh:
#
#     source "$ROOT/scripts/lib/install-semaphore.sh"
#     ( trap sem_release EXIT; sem_acquire "$repo"; <install cmd> ) &
#
# A `wait` at the end of your bootstrap bounds only YOUR worktree. It cannot see the
# installs another worktree's bootstrap started, so under `govern --parallel` the real
# ceiling is (tickets in flight x repos per worktree x ~1 GB per install) — measured at
# ~14 GB on a 24 GB machine before the cap existed. install-semaphore.sh is a
# cross-process cap; see its header for the full reasoning and how to measure it.
if [ "$SKIP_BOOTSTRAP" -eq 0 ]; then
  if [ -x "$ROOT/scripts/lib/worktree-bootstrap.sh" ]; then
    echo "[worktree] running scripts/lib/worktree-bootstrap.sh ..."
    bash "$ROOT/scripts/lib/worktree-bootstrap.sh" "$NAME" "$SLOT" "$WORKTREE_PATH" || true
  else
    echo "[worktree] no scripts/lib/worktree-bootstrap.sh found — skipping bootstrap"
    echo "  (create it to install deps, run codegen, wire the per-slot DB, etc.)"
  fi

  # RE-ASSERT the commit hooks AFTER bootstrap. The bootstrap step commonly runs `npm install`,
  # which triggers husky's `prepare` and regenerates `.husky/_/*` UNCONDITIONALLY — wiping the
  # attribution/pre-commit hooks installed in the per-repo loop above (which ran BEFORE bootstrap).
  # Re-installing here is idempotent and makes the hooks survive the reinstall. Failures are
  # fatal (exit 4) for the same reason the per-repo installs above are: a swallowed failure
  # here would print a success banner over a tree whose hooks were just wiped and never
  # restored.
  if command -v install_subrepo_attribution_hook >/dev/null 2>&1; then
    echo "[worktree] re-asserting sub-repo commit hooks post-bootstrap ..."
    for repo in "${REPOS[@]}"; do
      dst="$WORKTREE_PATH/$repo"
      { [ -d "$dst/.git" ] || [ -f "$dst/.git" ]; } || continue
      install_subrepo_attribution_hook "$ROOT" "$dst" || HOOK_INSTALL_FAILURES+=("$repo:prepare-commit-msg")
      if command -v install_subrepo_pre_commit_hook >/dev/null 2>&1; then
        install_subrepo_pre_commit_hook "$ROOT" "$dst" || HOOK_INSTALL_FAILURES+=("$repo:pre-commit")
      fi
    done
    if [ "${#HOOK_INSTALL_FAILURES[@]}" -gt 0 ]; then
      echo "✗ worktree hook install failed for: ${HOOK_INSTALL_FAILURES[*]}" >&2
      echo "  The worktree at $WORKTREE_PATH is left on disk for inspection. Fix the" >&2
      echo "  cause, then re-run: $ROOT_PM run worktree:new -- $NAME --adopt" >&2
      exit 4
    fi
  fi
fi

# Build a human-readable summary of the ports this worktree will use; from the repos
# actually confirmed checked out, never the static REPOS list: a repo that failed to
# check out must not appear in the banner as though it exists.
port_summary=""
for repo in ${CREATED_REPOS[@]+"${CREATED_REPOS[@]}"}; do
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
