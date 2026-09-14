#!/usr/bin/env bash
# HIGH-sev regression (#B1): `worktree:rm` without --force must REFUSE when a sub-repo (or the meta
# worktree) has commits that aren't on its remote yet. The old guard only checked `git status
# --porcelain` (uncommitted changes), so a CLEAN worktree whose branch was N commits ahead of
# origin passed straight through and got `git worktree remove --force` + `git branch -D`'d — making
# those commits reflog-only (silently lost to a normal `worktree:rm`).
#
# Extracts the SHIPPED unpushed_count() + check_worktree_dir() from rm.sh (no drifting copy, exactly
# like test-worktree-rm-stack-kill.sh) and exercises them against a real git fixture:
#   - clean + fully pushed        → 0 unpushed, guard does NOT trip (rm proceeds)
#   - committed-but-unpushed       → counted via @{upstream}, guard trips (rm REFUSES)
#   - detached HEAD ahead of origin/main (no upstream) → counted via the origin/main fallback
# Plus a source-level assertion that rm.sh gates the whole precheck on `--force` (so --force
# bypasses it and rm proceeds).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RM="$DIR/../../worktree/rm.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP - git unavailable"; exit 0; }

# Extract the two shipped functions and source them (runs the real implementation, not a copy).
FN="$(mktemp)"; trap 'rm -f "$FN"' EXIT
awk '/^unpushed_count\(\) \{/{f=1} f{print} f&&/^}$/{exit}'      "$RM" >  "$FN"
awk '/^check_worktree_dir\(\) \{/{f=1} f{print} f&&/^}$/{exit}'  "$RM" >> "$FN"
grep -q 'unpushed_count'     "$FN" || { echo "FAIL - could not extract unpushed_count() from $RM"; exit 1; }
grep -q 'check_worktree_dir' "$FN" || { echo "FAIL - could not extract check_worktree_dir() from $RM"; exit 1; }
# shellcheck disable=SC1090
source "$FN"

# ── git fixture: bare origin + a clone that tracks origin/main ──
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -f "$FN"; rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git -C "$T" clone -q "$T/origin.git" repo
R="$T/repo"
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" checkout -q -b main
echo one > "$R/a.txt"; git -C "$R" add a.txt; git -C "$R" commit -qm one
git -C "$R" push -q -u origin main            # main pushed → upstream set, 0 ahead

# clean + fully pushed → 0, guard does not trip.
assert_eq "$(unpushed_count "$R")" "0" "fully-pushed repo has 0 unpushed commits"
had_problem=0; check_worktree_dir "$R" repo >/dev/null 2>&1
assert_eq "$had_problem" "0" "clean+pushed worktree does NOT trip the guard (rm proceeds)"

# committed-but-unpushed → 1, guard trips (refuse) with the right cause.
echo two > "$R/b.txt"; git -C "$R" add b.txt; git -C "$R" commit -qm two
assert_eq "$(unpushed_count "$R")" "1" "committed-but-unpushed commit is counted via @{upstream}"
# NB: call directly (NOT in $(...)) — check_worktree_dir sets the shared `had_problem`, which a
# command-substitution subshell would swallow. Capture the message via a stderr redirect instead.
had_problem=0; check_worktree_dir "$R" repo 2>"$T/err.txt"
assert_eq "$had_problem" "1" "unpushed commit trips the guard (rm without --force REFUSES) [#B1]"
assert_contains "$(cat "$T/err.txt")" "not pushed to its remote" "refusal message names the unpushed-commit cause"

# origin/main fallback: a DETACHED HEAD (no upstream) ahead of origin/main is still caught.
git -C "$R" push -q origin main               # advance origin/main to include commit two
git -C "$R" checkout -q --detach
echo three > "$R/c.txt"; git -C "$R" add c.txt; git -C "$R" commit -qm three
assert_eq "$(git -C "$R" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo none)" "none" \
  "detached HEAD has no upstream (exercises the origin/main fallback)"
assert_eq "$(unpushed_count "$R")" "1" "detached HEAD ahead of origin/main is counted (fallback path)"

# local-main fallback: a remote-less root (NO origin at all — git remote -v empty, the operator's
# binding "detect an upstream, never impose one" state) still catches an unreported commit, via
# local `main` instead of `origin/main`. The missing remote changes WHICH ref we compare against,
# never whether we check — a root-scope worktree with no remote must not report 0 unpushed just
# because there's no remote to compare against at all.
RL="$T/remoteless"; mkdir -p "$RL"
( cd "$RL" && git init -q && git config user.email t@t && git config user.name t \
    && git checkout -q -b main && echo one > a.txt && git add a.txt && git commit -qm one )
assert_eq "$(git -C "$RL" remote 2>/dev/null)" "" "remote-less fixture genuinely has no origin"
git -C "$RL" checkout -q --detach
echo two > "$RL/b.txt"; git -C "$RL" add b.txt; git -C "$RL" commit -qm two
assert_eq "$(unpushed_count "$RL")" "1" "remote-less root: detached HEAD ahead of local main is counted (no remote needed)"
had_problem=0; check_worktree_dir "$RL" remoteless 2>"$T/err2.txt"
assert_eq "$had_problem" "1" "remote-less root with an uncounted commit trips the guard [rootScope teardown safety net]"
assert_contains "$(cat "$T/err2.txt")" "not pushed to its remote" "remote-less refusal message is the same as the remote-backed one"

# a non-git dir is skipped, never a spurious refusal.
mkdir -p "$T/plain"
had_problem=0; check_worktree_dir "$T/plain" plain >/dev/null 2>&1
assert_eq "$had_problem" "0" "a non-git dir is skipped by the guard"

# rm.sh wires the precheck under the --force gate (so --force bypasses it → rm proceeds) and checks meta too.
rmsrc="$(cat "$RM")"
assert_contains "$rmsrc" 'if [ "$FORCE" -ne 1 ]; then'              "precheck is gated on --force (so --force bypasses it)"
assert_contains "$rmsrc" 'check_worktree_dir "$WORKTREE_PATH" "meta"' "the meta worktree is checked, not just sub-repos"

assert_done
