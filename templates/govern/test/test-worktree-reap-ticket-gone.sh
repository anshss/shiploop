#!/usr/bin/env bash
# Regression: the reaper's squash-merge downgrade. A squash-merge severs SHA ancestry
# forever; the commit `worktree:new` branched off is never an ancestor of the squashed
# merge commit origin/main gains, so a resolved-and-deleted ticket's worktree shows
# "unmerged" forever even though its content landed byte-for-byte. The unmerged blocker
# is downgraded ONLY when BOTH signals agree:
#   · the ticket named by the t<N> slug is gone from tickets.md, AND
#   · the repo's committed tree is byte-identical to origin/main (git diff --quiet).
# Either signal alone (or a tree with real unlanded work) still blocks the reap.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq unavailable"; exit 0; }

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# ── Sandbox: meta repo + sub-repo "alpha", each with a local bare origin so the reaper's
# once-per-repo fetch and its origin/main ancestry checks resolve. ──
mkdir -p "$T/scripts/worktree" "$T/scripts/lib" "$T/alpha" "$T/queue"
cp "$DIR/../../worktree/reap.sh" "$T/scripts/worktree/reap.sh"
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
git -C "$T" init -q --bare "$T/origin-root.git"
git -C "$T" remote add origin "$T/origin-root.git"
git -C "$T" push -q origin main; git -C "$T" fetch -q origin

git -C "$T/alpha" init -q -b main
git -C "$T/alpha" config user.email t@t; git -C "$T" config user.name t
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm a   # A
git -C "$T/alpha" init -q --bare "$T/origin-alpha.git"
git -C "$T/alpha" remote add origin "$T/origin-alpha.git"
git -C "$T/alpha" push -q origin main; git -C "$T/alpha" fetch -q origin

# Squash-merge shape: the ticket branch t7 commits B on top of A; origin/main gains a
# DIFFERENT commit S with the SAME tree (a squash of B); ancestry severed, content landed.
git -C "$T/alpha" branch t7
git -C "$T/alpha" worktree add "$T/wt/t7/alpha" t7 >/dev/null 2>&1
git -C "$T" worktree add --detach "$T/wt/t7" main >/dev/null 2>&1
echo b > "$T/wt/t7/alpha/file.txt"; git -C "$T/wt/t7/alpha" add -A; git -C "$T/wt/t7/alpha" commit -qm b   # B (tree: file=b)
git -C "$T/alpha" checkout -q --detach
git -C "$T/alpha" checkout -q -b squasher t7
git -C "$T/alpha" checkout -q main
git -C "$T/alpha" rm -q file.txt >/dev/null 2>&1 || true
echo b > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm s   # S: same tree as B, different SHA, parent A
git -C "$T/alpha" push -q origin main; git -C "$T/alpha" fetch -q origin

# Sanity: the shape really is "unmerged but tree-identical".
ahead="$(git -C "$T/wt/t7/alpha" rev-list --count origin/main..HEAD)"
assert_eq "$ahead" "1" "setup: t7 is 1 commit ahead of origin/main (ancestry severed)"
git -C "$T/wt/t7/alpha" diff --quiet origin/main HEAD --
assert_eq "$?" "0" "setup: t7 tree is byte-identical to origin/main"

# tickets.md: #7 absent, another ticket present.
printf '# tickets\n\n## #8 - unrelated ticket\n\nbody\n' > "$T/queue/tickets.md"

# ── 1. Ticket gone + tree identical → downgrade fires, the worktree is REAPABLE ──
out1="$(bash "$T/scripts/worktree/reap.sh" 2>&1)"; rc1=$?
assert_eq "$rc1" "0" "reap dry run succeeds"
assert_contains "$out1" "REAPABLE (1)" "ticket gone + tree identical: t7 is reapable"
assert_not_contains "$out1" "unmerged(alpha:1)" "ticket gone + tree identical: no unmerged blocker"

# ── 2. Ticket STILL OPEN: the same tree keeps the blocker (t-N slug alone proves nothing) ──
printf '# tickets\n\n## #7 - the t7 ticket\n\n## #8 - unrelated ticket\n' > "$T/queue/tickets.md"
out2="$(bash "$T/scripts/worktree/reap.sh" 2>&1)"; rc2=$?
assert_contains "$out2" "unmerged(alpha:1)" "ticket still open: unmerged blocker kept"
assert_contains "$out2" "REAPABLE (0)" "ticket still open: not reapable"

# ── 3. Ticket gone but REAL unlanded work (tree differs): still blocked ──
printf '# tickets\n\n## #8 - unrelated ticket\n' > "$T/queue/tickets.md"
echo c > "$T/wt/t7/alpha/extra.txt"; git -C "$T/wt/t7/alpha" add -A; git -C "$T/wt/t7/alpha" commit -qm c
out3="$(bash "$T/scripts/worktree/reap.sh" 2>&1)"; rc3=$?
assert_contains "$out3" "unmerged(alpha:2)" "ticket gone but tree differs: unmerged blocker kept"
assert_contains "$out3" "REAPABLE (0)" "ticket gone but tree differs: not reapable"

assert_done
