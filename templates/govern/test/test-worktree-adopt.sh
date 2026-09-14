#!/usr/bin/env bash
# Regression: worktree/new.sh --adopt lets a retry reuse a preserved worktree from a prior
# attempt on the SAME ticket instead of starting cold, without ever running a destructive git
# command on it. Covers: the default (no-flag) path is unchanged; adoption succeeds and reports
# a dirty tree unmodified; adoption is refused for an unregistered path or a live holder.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh sets -e; several calls below deliberately return non-zero

# worker-prompt.md lives at a DIFFERENT path depending on where the suite runs from: the hub
# (templates/governor) or a scaffolded workspace (<root>/governor). Resolve the first that
# exists; if neither does, the suite is running from a layout that doesn't ship it, so skip
# rather than fail on a path assumption.
first_existing() { for p in "$@"; do [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }; done; return 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Sandbox: a real meta-repo root (git, branch main) plus one real sub-repo ("alpha", also
# git, branch main): new.sh runs actual `git worktree add`, so it needs real repos, not stubs. ──
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

# ── 1. First attempt: a plain worktree:new t99, this stands in for a worker's first,
# unfinished attempt at ticket #99. ─────────────────────────────────────────────────────────
out1="$(cd "$T" && bash "$NEW" t99 --skip-bootstrap 2>&1)"; rc1=$?
assert_eq "$rc1" "0" "first attempt: worktree:new t99 succeeds"
assert_eq "$([ -d "$T/wt/t99/alpha" ] && echo y || echo n)" "y" "first attempt: alpha sub-repo checked out on t99"

# Stand in for what a failed/timed-out worker leaves behind: its own scratchpad notes, plus an
# uncommitted edit, the "preserved work" adoption exists to hand back untouched.
echo "ruled out: X does not work; stopped at alpha/file.txt:1" > "$T/wt/t99/.governor-notes.md"
echo "dirty edit" > "$T/wt/t99/alpha/wip.txt"

# ── 2. Default (no --adopt): a retry on the same name still hard-errors: unchanged behavior. ──
out2="$(cd "$T" && bash "$NEW" t99 --skip-bootstrap 2>&1)"; rc2=$?
assert_eq "$rc2" "1" "no --adopt: retry on an existing path still errors"
assert_contains "$out2" "path already exists" "no --adopt: the default path errors without the flag"
assert_eq "$(cat "$T/wt/t99/alpha/wip.txt")" "dirty edit" "no --adopt: the refused attempt left the dirty file untouched"

# ── 3. --adopt for the matching ticket: adopts, reports the dirty tree, edits untouched. ──────
out3="$(cd "$T" && bash "$NEW" t99 --skip-bootstrap --adopt 2>&1)"; rc3=$?
assert_eq "$rc3" "0" "--adopt on the matching ticket succeeds"
assert_contains "$out3" "Adopting existing worktree" "--adopt: reports that it adopted, not created"
assert_contains "$out3" "dirty:" "--adopt: reports the tree as dirty"
assert_contains "$out3" "alpha" "--adopt: names the dirty sub-repo"
assert_contains "$out3" ".governor-notes.md" "--adopt: surfaces the prior attempt's notes file"
assert_eq "$(cat "$T/wt/t99/alpha/wip.txt")" "dirty edit" "--adopt: the preserved edit is handed back UNMODIFIED"
assert_eq "$(git -C "$T/wt/t99/alpha" status --porcelain | wc -l | tr -d ' ')" "1" \
  "--adopt: git status is unchanged (no checkout/stash/reset/clean ran on the tree)"

# ── 4. --adopt refused for an unregistered path: a directory that merely sits at the requested
# name (never created through worktree:new, so it can't be proven to be the same ticket). ─────
mkdir -p "$T/wt/t100/alpha"
out4="$(cd "$T" && bash "$NEW" t100 --skip-bootstrap --adopt 2>&1)"; rc4=$?
assert_eq "$rc4" "1" "--adopt on an unregistered path is refused"
assert_contains "$out4" "adoption refused" "--adopt: explains why it refused, on stderr"
assert_contains "$out4" "path already exists" "--adopt: refusal still falls back to the standard error"

# ── 5. --adopt refused when another agent holds the tree (test seam: WORKTREE_ADOPT_HELD_OVERRIDE
# stands in for a real live process, the same way WORKTREE_FREE_GB_OVERRIDE stands in for df). ──
out5="$(cd "$T" && WORKTREE_ADOPT_HELD_OVERRIDE="12345" bash "$NEW" t99 --skip-bootstrap --adopt 2>&1)"; rc5=$?
assert_eq "$rc5" "1" "--adopt refused while another agent holds the tree"
assert_contains "$out5" "held by another agent" "--adopt: names a live holder as the reason"
assert_eq "$(cat "$T/wt/t99/alpha/wip.txt")" "dirty edit" "--adopt refusal: still leaves the dirty file untouched"

# ── 6. worker-prompt.md documents how a worker treats notes found in an adopted tree. ─────────
if WP="$(first_existing "$DIR/../../governor/worker-prompt.md" "$DIR/../../../governor/worker-prompt.md")"; then
  assert_contains "$(cat "$WP")" "worktree:new -- <name> --adopt" "worker-prompt.md documents the --adopt flag ($WP)"
  assert_contains "$(cat "$WP")" "not verified fact" "worker-prompt.md labels a prior attempt's notes as unverified ($WP)"
else
  printf 'skip - worker-prompt.md not present in this layout\n'
fi

assert_done
