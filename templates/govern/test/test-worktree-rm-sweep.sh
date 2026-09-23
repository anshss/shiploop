#!/usr/bin/env bash
# worktree/rm.sh --sweep removes an ORPHANED packet-created worktree (govern:dispatch-packet
# died before a worker ever picked it up): the packet's own creation timestamp is older than
# GOVERN_AGENT_WALLCLOCK, AND every sub-repo plus the meta root is clean, AND none has a commit
# beyond its base. Anything else is REPORTED, never removed.
#
#   1. an old, clean, no-commits packet-created worktree is swept.
#   2. an old but DIRTY packet-created worktree is kept, not removed.
#   3. a YOUNG packet-created worktree (packet newer than the wall-clock cap) is kept.
#   4. an old, clean worktree holding a real commit beyond its base is kept (real work, not orphan).
#   5. a worktree with NO packet at all is outside --sweep's scope: untouched either way.
#   6. an old, clean worktree whose commit is already on its upstream (a pushed PR branch) is kept.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib" "$T/alpha"
cp "$DIR/../../worktree/new.sh" "$T/scripts/worktree/new.sh"
cp "$DIR/../../worktree/rm.sh" "$T/scripts/worktree/rm.sh"
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
echo root > "$T/root.txt"
# A real workspace's .gitignore (templates/gitignore) keeps the packet, the per-worktree env file,
# and every sub-repo dir out of the meta root's own `git status` (worktree/new.sh's
# __SUBREPO_IGNORES__); replicate that here or the fixture's OWN scaffolding makes every worktree
# look "dirty" regardless of the scenario under test.
printf '.dispatch-packet.md\nworktree.env\n/alpha/\n' > "$T/.gitignore"
git -C "$T" add -A; git -C "$T" commit -qm init >/dev/null

git -C "$T/alpha" init -q -b main
git -C "$T/alpha" config user.email t@t; git -C "$T/alpha" config user.name t
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm init >/dev/null

NEW="$T/scripts/worktree/new.sh"
RM="$T/scripts/worktree/rm.sh"
export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10

stamp_packet() { # <worktree-name> <age-seconds-ago>
  local wt="$1" ago="$2" epoch
  epoch=$(( $(date +%s) - ago ))
  printf '<!-- GOVERN:PACKET-CREATED %s -->\n# Dispatch packet for #%s\n' "$epoch" "$wt" > "$T/wt/$wt/.dispatch-packet.md"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════
# setup: five worktrees, one per scenario
# ══════════════════════════════════════════════════════════════════════════════════════════════
for n in t1 t2 t3 t4 t5 t6; do
  ( cd "$T" && bash "$NEW" "$n" --skip-bootstrap >/dev/null 2>&1 )
done

# t1: old (2h), clean, no commits beyond base -> SWEEP
stamp_packet t1 7200

# t2: old, DIRTY -> KEEP
stamp_packet t2 7200
echo dirty > "$T/wt/t2/alpha/uncommitted.txt"

# t3: YOUNG (10s old) -> KEEP
stamp_packet t3 10

# t4: old, clean, but holds a real commit beyond base -> KEEP (real work, not an orphan)
stamp_packet t4 7200
( cd "$T/wt/t4/alpha" && echo real-work >> file.txt && git commit -qam "real work in progress" )

# t6: old, clean, commit present on its upstream (pushed) -> KEEP: pushed work is still work
stamp_packet t6 7200
( cd "$T/wt/t6/alpha" && echo pushed-work >> file.txt && git commit -qam "pushed work" \
    && git branch -q t6-upstream && git branch -q --set-upstream-to=t6-upstream )

# t5: no packet at all -> outside --sweep's scope
rm -f "$T/wt/t5/.dispatch-packet.md" 2>/dev/null

out="$( cd "$T" && GOVERN_AGENT_WALLCLOCK=3600 bash "$RM" --sweep 2>&1 )"

assert_eq "$([ -e "$T/wt/t1" ] && echo present || echo gone)" "gone" "1. an old, clean, orphaned worktree is swept"
assert_contains "$out" "sweeping orphaned worktree 't1'" "1. the sweep announces t1 by name"

assert_eq "$([ -e "$T/wt/t2" ] && echo present || echo gone)" "present" "2. an old but DIRTY worktree is kept, not removed"
assert_contains "$out" "kept 't2'" "2. the sweep reports t2 as kept"
assert_contains "$out" "uncommitted changes" "2. ...and names why (uncommitted changes)"

assert_eq "$([ -e "$T/wt/t3" ] && echo present || echo gone)" "present" "3. a YOUNG packet-created worktree is kept"
assert_contains "$out" "kept 't3'" "3. the sweep reports t3 as kept"
assert_contains "$out" "old (<" "3. ...and names why (too young for the wall-clock cap)"

assert_eq "$([ -e "$T/wt/t4" ] && echo present || echo gone)" "present" "4. a clean worktree holding a real commit beyond base is kept"
assert_contains "$out" "kept 't4'" "4. the sweep reports t4 as kept"
assert_contains "$out" "commit(s) beyond its base" "4. ...and names why (real work sitting there)"

assert_eq "$([ -e "$T/wt/t5" ] && echo present || echo gone)" "present" "5. a worktree with no packet at all is untouched"
assert_not_contains "$out" "'t5'" "5. ...and never even mentioned (outside --sweep's scope)"

assert_eq "$([ -e "$T/wt/t6" ] && echo present || echo gone)" "present" "6. a clean worktree whose commit is already pushed is kept"
assert_contains "$out" "kept 't6'" "6. the sweep reports t6 as kept"

assert_done
