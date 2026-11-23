#!/usr/bin/env bash
# Regression: `worktree:new` must never print a success banner (exit 0) over a tree that
# failed to build. Covers:
#   (a) a sub-repo `git worktree add` that fails is a HARD failure (exit 1, "FAILED" line,
#       no success banner); the old code piped the add through `sed` and reported the
#       FILTER's exit status, so a rejected add looked like success;
#   (b) a commit-hook install failure is FATAL (exit 4, every offender named); the old
#       code swallowed it with `|| true` and printed the success banner anyway;
#   (c) the success path still exits 0 and still prints the banner.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh sets -e; several calls below deliberately return non-zero

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Sandbox: a real meta-repo root plus one real sub-repo ("alpha"), mirroring the
# test-worktree-adopt.sh layout. The stub workspace.sh keeps new.sh repo-agnostic. ──
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
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm init

NEW="$T/scripts/worktree/new.sh"
export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10

# ── (a) checkout failure: branch t90 exists AND is already checked out in another
# worktree, so `git worktree add <dst> t90` fails with "'t90' is already used by ..." ──
git -C "$T/alpha" branch t90
git -C "$T/alpha" worktree add "$T/wt-blocker" t90 >/dev/null 2>&1
mkdir -p "$T/wt"   # wt-blocker above already created the base dir

out_a="$(cd "$T" && bash "$NEW" t90 --skip-bootstrap 2>&1)"; rc_a=$?
assert_eq "$rc_a" "1" "checkout failure: worktree:new exits non-zero (was 0 before the fix)"
assert_contains "$out_a" "FAILED: git worktree add did not produce a checkout" \
  "checkout failure: names the sub-repo and the real cause"
assert_not_contains "$out_a" "Worktree 't90' created" \
  "checkout failure: no success banner over a broken tree"
assert_eq "$([ -e "$T/wt/t90/alpha/.git" ] && echo y || echo n)" "n" \
  "checkout failure: the failed repo really has no checkout"
git -C "$T/alpha" worktree remove --force "$T/wt-blocker" >/dev/null 2>&1 || true

# ── (b) hook-install failure is fatal with exit 4. A stub githooks.sh whose attribution
# install returns 1 stands in for the real cp failure (full disk, unwritable hooks dir). ──
cat > "$T/scripts/lib/githooks.sh" <<'EOF'
install_subrepo_attribution_hook() { return 1; }
install_subrepo_pre_commit_hook() { return 0; }
EOF

out_b="$(cd "$T" && bash "$NEW" t91 --skip-bootstrap 2>&1)"; rc_b=$?
assert_eq "$rc_b" "4" "hook install failure: exits 4 (was 0 before the fix)"
assert_contains "$out_b" "worktree hook install failed for: alpha:prepare-commit-msg" \
  "hook install failure: names the repo and which hook"
assert_not_contains "$out_b" "Worktree 't91' created" \
  "hook install failure: no success banner over a tree without its hooks"
assert_eq "$([ -e "$T/wt/t91/alpha/.git" ] && echo y || echo n)" "y" \
  "hook install failure: the tree itself IS left on disk for inspection"

# ── (c) success path: with working hook installers the same run exits 0 with a banner ──
cat > "$T/scripts/lib/githooks.sh" <<'EOF'
install_subrepo_attribution_hook() { return 0; }
install_subrepo_pre_commit_hook() { return 0; }
EOF

out_c="$(cd "$T" && bash "$NEW" t92 --skip-bootstrap 2>&1)"; rc_c=$?
assert_eq "$rc_c" "0" "success path: exits 0"
assert_contains "$out_c" "Worktree 't92' created" "success path: banner still printed"

assert_done
