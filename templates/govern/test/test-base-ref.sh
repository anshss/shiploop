#!/usr/bin/env bash
# #29: wt_subrepo_base_ref must branch a NEW sub-repo worktree off the freshly-fetched origin/main
# (so a stale, behind local `main` in the read-only main checkout can't produce PRs born conflicting),
# and fall back to local `main` only when there's no reachable origin. Hermetic: real temp git repos,
# no network. gh is never touched.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# base-ref.sh lives at templates/worktree/lib/ (sibling of govern/) — same relative layout at runtime.
source "$DIR/../../worktree/lib/base-ref.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git_q() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
commit() { # <repo-dir> <file-content>
  printf '%s\n' "$2" > "$1/f.txt"; git_q -C "$1" add f.txt; git_q -C "$1" commit -q -m "$2"
}

# ── 1. origin/main is AHEAD of local main → base resolves to origin/main, pointing at the fresh tip.
git_q init -q --bare "$TMP/origin.git"
git_q clone -q "$TMP/origin.git" "$TMP/work"; commit "$TMP/work" c1
git_q -C "$TMP/work" branch -M main; git_q -C "$TMP/work" push -q -u origin main
git_q clone -q "$TMP/origin.git" "$TMP/local"            # local main + origin/main both at c1
commit "$TMP/work" c2; git_q -C "$TMP/work" push -q origin main   # origin main advances to c2
local_main_before="$(git_q -C "$TMP/local" rev-parse main)"
origin_tip="$(git_q -C "$TMP/work" rev-parse HEAD)"

base="$(wt_subrepo_base_ref "$TMP/local")"
assert_eq "$base" "origin/main" "base ref is origin/main when an origin is reachable"
assert_eq "$(git_q -C "$TMP/local" rev-parse "$base")" "$origin_tip" "the fetch advanced origin/main to the live tip (c2) — a worktree cut off \$base lands on c2"
assert_eq "$(git_q -C "$TMP/local" rev-parse main)" "$local_main_before" "local main is left untouched (still stale c1) — proving we do NOT branch off it"
[[ "$origin_tip" != "$local_main_before" ]] && assert_eq "ok" "ok" "precondition: origin tip (c2) differs from stale local main (c1)"

# Actually cutting a worktree off \$base must land on the fresh tip, not stale local main.
git_q -C "$TMP/local" worktree add -q -b feat "$TMP/local-wt" "$base" 2>/dev/null
assert_eq "$(git_q -C "$TMP/local-wt" rev-parse HEAD)" "$origin_tip" "new worktree off \$base is at the live origin tip, not the stale local main"

# ── 2. No origin remote (local-only repo, e.g. a hermetic stub) → fall back to local main.
git_q init -q "$TMP/lonely"; commit "$TMP/lonely" solo; git_q -C "$TMP/lonely" branch -M main
assert_eq "$(wt_subrepo_base_ref "$TMP/lonely")" "main" "falls back to local main when there is no origin remote"

# ── 3. Origin configured but UNREACHABLE (offline) → fetch fails → fall back to local main.
git_q -C "$TMP/lonely" remote add origin "$TMP/does-not-exist.git"
assert_eq "$(wt_subrepo_base_ref "$TMP/lonely")" "main" "falls back to local main when origin is unreachable (fetch fails)"

assert_done
