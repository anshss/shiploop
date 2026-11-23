#!/usr/bin/env bash
# Regression: `worktree:new` drift guard (opt-in, WORKTREE_DRIFT_GUARD=1). The
# "branch <name> already exists → check it out as-is" fast path never touches origin/main,
# so a leftover local branch from an earlier session checks out N commits behind
# origin/main while its siblings take the fresh `-b` path; a plausible tree that only
# conflicts at PR time. With the guard ON, a stale branch is fast-forwarded (plain
# staleness) or creation refuses (exit 5, real diverged commits). With the guard OFF (the
# default; enabling mutates a freshly checked-out branch and can refuse creation, which
# changes what an existing install does), behavior is exactly as before.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Sandbox: meta root + sub-repo "alpha" WITH a real (local bare) origin, because the
# drift check fetches origin from inside the new worktree. ──
mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib" "$T/alpha"
cp "$DIR/../../worktree/new.sh" "$T/scripts/worktree/new.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$T/scripts/worktree/lib/registry.sh"
cp "$DIR/../../worktree/lib/base-ref.sh" "$T/scripts/worktree/lib/base-ref.sh"
cat > "$T/scripts/lib/workspace.sh" <<EOF
ROOT_PM=npm
WORKTREE_BASE="$T/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
EOF

git -C "$T" init -q -b main
git -C "$T" config user.email t@t; git -C "$T" config user.name t
echo root > "$T/root.txt"; git -C "$T" add -A; git -C "$T" commit -qm init

git -C "$T/alpha" init -q -b main
git -C "$T/alpha" config user.email t@t; git -C "$T/alpha" config user.name t
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm init   # A
git -C "$T/alpha" remote add origin "$T/origin-alpha.git"
git -C "$T/alpha" init -q --bare "$T/origin-alpha.git"
git -C "$T/alpha" push -q origin main
git -C "$T/alpha" fetch -q origin   # establish origin/main locally

# origin/main moves ahead (commit B); a stale leftover branch t90 sits at A; ff-able.
echo y > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm b
git -C "$T/alpha" push -q origin main; git -C "$T/alpha" fetch -q origin
git -C "$T/alpha" branch t90 HEAD~1            # stale, ff-able
# t97: stale AND diverged (its own commit Z, not on origin/main, and behind).
git -C "$T/alpha" checkout -q t90 2>/dev/null || true
git -C "$T/alpha" checkout -q -b t97 HEAD~1 2>/dev/null || git -C "$T/alpha" checkout -q -b t97 origin/main~1
echo z > "$T/alpha/z.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm z
git -C "$T/alpha" checkout -q main

NEW="$T/scripts/worktree/new.sh"
export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10

head_sha() { git -C "$1" rev-parse HEAD 2>/dev/null; }

# ── 1. Guard OFF (default): stale branch checks out as-is, unchanged behavior ──
out1="$(cd "$T" && bash "$NEW" t90 --skip-bootstrap 2>&1)"; rc1=$?
assert_eq "$rc1" "0" "guard off: creation succeeds"
assert_contains "$out1" "branch 't90' exists, checking out" "guard off: took the branch-exists path"
assert_not_contains "$out1" "fast-forwarded" "guard off: no fast-forward ran"
assert_eq "$(head_sha "$T/wt/t90/alpha")" "$(git -C "$T/alpha" rev-parse origin/main~1)" \
  "guard off: the stale checkout stays stale (worktree still 1 behind origin/main)"

# ── 2. Guard ON, plain staleness: fast-forwarded to origin/main ──
out2="$(cd "$T" && WORKTREE_DRIFT_GUARD=1 bash "$NEW" t95 --skip-bootstrap 2>&1)"; rc2=$?
# t95 does not exist: fresh -b path off a fresh origin/main; up to date, exit 0 either way.
assert_eq "$rc2" "0" "guard on: fresh branch still succeeds"
assert_contains "$out2" "up to date with origin/main" "guard on: fresh branch reports up to date"

# Now a stale ff-able branch under the guard: t98 forks from origin/main~1 (staleness only).
git -C "$T/alpha" branch t98 origin/main~1
out2b="$(cd "$T" && WORKTREE_DRIFT_GUARD=1 bash "$NEW" t98 --skip-bootstrap 2>&1)"; rc2b=$?
assert_eq "$rc2b" "0" "guard on: ff-able staleness fast-forwards and succeeds"
assert_contains "$out2b" "was 1 commit(s) behind origin/main; fast-forwarded" \
  "guard on: reports the fast-forward"
assert_eq "$(head_sha "$T/wt/t98/alpha")" "$(git -C "$T/alpha" rev-parse origin/main)" \
  "guard on: the stale branch is now AT origin/main"

# ── 3. Guard ON, real divergence: refuse with exit 5, tree left for inspection ──
out3="$(cd "$T" && WORKTREE_DRIFT_GUARD=1 bash "$NEW" t97 --skip-bootstrap 2>&1)"; rc3=$?
assert_eq "$rc3" "5" "guard on: diverged branch refuses with exit 5"
assert_contains "$out3" "behind origin/main with real commits of their own" \
  "guard on: refusal names the divergence"
assert_contains "$out3" "alpha:1" "guard on: refusal names the repo and how far behind"
assert_not_contains "$out3" "Worktree 't97' created" "guard on: no success banner"
assert_eq "$([ -e "$T/wt/t97/alpha/.git" ] && echo y || echo n)" "y" \
  "guard on: the diverged tree is left on disk for inspection"
assert_eq "$(head_sha "$T/wt/t97/alpha")" "$(git -C "$T/alpha" rev-parse t97)" \
  "guard on: the diverged branch was NOT mutated"

assert_done
