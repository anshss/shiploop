#!/usr/bin/env bash
# sync.sh and a DIRTY workspace root: the root is never pulled, rebased or switched, but commits already on
# its main reach origin.
#   1. dirty and ahead: main is pushed and the working tree is byte-identical afterwards.
#   2. dirty and behind: both counts are printed, nothing is pushed, HEAD and tree are unchanged.
#   3. dirty and diverged: the same warning, nothing pushed.
#   4. GOVERN_NO_PUSH=1, no origin, and a root off main: silent, nothing pushed.
#   5. clean and ahead: the preflight-main path still pushes (unchanged).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$DIR/../../sync.sh"
[[ -f "$SYNC" ]] || { echo "SKIP: sync.sh template not found"; exit 77; }
source "$DIR/assert.sh"
set +e

S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$S/scripts/lib"
cp "$SYNC" "$S/scripts/sync.sh"
printf '#!/usr/bin/env bash\nMETA_ROOT="%s"\nROOT_PM="npm"\nREPOS=()\n' "$S" > "$S/scripts/lib/workspace.sh"

mkdir -p "$S/remote"
git init -q --bare -b main "$S/remote/origin.git"
cd "$S" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t
git remote add origin "$S/remote/origin.git"
printf 'scripts/\nremote/\n' > .gitignore
PF="$DIR/../preflight-main.sh"
[[ -f "$PF" ]] || { echo "SKIP: preflight-main.sh not found"; exit 77; }
mkdir -p "$S/scripts/govern/lib"; cp "$PF" "$S/scripts/govern/"; cp "$DIR/../lib/common.sh" "$S/scripts/govern/lib/"
echo base > f.txt && git add . && git commit -qm base && git push -q origin main
git clone -q "$S/remote/origin.git" "$S/remote/pusher" 2>/dev/null
( cd "$S/remote/pusher" && git config user.email t@t && git config user.name t )

origin_head() { git -C "$S/remote/origin.git" rev-parse main; }
local_head() { git -C "$S" rev-parse main; }
tree_sum() { ( cd "$S" && cat f.txt dirty.txt 2>/dev/null; git status --porcelain ) | cksum; }
run_sync() { ( cd "$S" && env "$@" bash "$S/scripts/sync.sh" 2>&1 ); }
commit_local() { ( cd "$S" && echo "$1" > "c-$1.txt" && git add "c-$1.txt" && git commit -qm "$1" ); }
commit_origin() { ( cd "$S/remote/pusher" && git pull -q origin main && echo "$1" > "o-$1.txt" && git add . && git commit -qm "$1" && git push -q origin main ); }
dirty() { echo "wip $1" > "$S/dirty.txt"; }

# 1. dirty and ahead
commit_local a1; dirty 1
before="$(tree_sum)"
out="$(run_sync)"
assert_eq "$(origin_head)" "$(local_head)" "1. dirty and ahead: main reaches origin"
assert_eq "$(tree_sum)" "$before" "1. ...and the working tree is byte-identical"
assert_contains "$out" "pushed 1 root main commit(s)" "1. ...and the push is reported"

# 2. dirty and behind
commit_origin b1
lh="$(local_head)"; oh="$(origin_head)"; before="$(tree_sum)"
out="$(run_sync)"
assert_contains "$out" "ahead by 0 and behind by 1: not pushed" "2. dirty and behind: both counts printed"
assert_eq "$(local_head)" "$lh" "2. ...HEAD unchanged"
assert_eq "$(origin_head)" "$oh" "2. ...nothing pushed"
assert_eq "$(tree_sum)" "$before" "2. ...tree unchanged"

# 3. dirty and diverged
commit_local d1
lh="$(local_head)"; oh="$(origin_head)"
out="$(run_sync)"
assert_contains "$out" "ahead by 1 and behind by 1: not pushed" "3. dirty and diverged: both counts printed"
assert_eq "$(origin_head)" "$oh" "3. ...nothing pushed"
assert_eq "$(local_head)" "$lh" "3. ...HEAD unchanged"

# 4. skips. Reconcile the root first (clean) so ahead is isolated per case.
rm -f "$S/dirty.txt"; run_sync >/dev/null
commit_local n1; dirty 4
oh="$(origin_head)"
out="$(run_sync GOVERN_NO_PUSH=1)"
assert_eq "$(origin_head)" "$oh" "4. GOVERN_NO_PUSH=1: nothing pushed"
assert_not_contains "$out" "pushed" "4. ...and silent about it"
git -C "$S" checkout -q -b side
out="$(run_sync)"
assert_eq "$(origin_head)" "$oh" "4. root off main: nothing pushed"
assert_not_contains "$out" "root main" "4. ...and silent"
git -C "$S" checkout -q main
git -C "$S" remote rename origin gone
out="$(run_sync)"
assert_not_contains "$out" "root main" "4. no origin: silent"
assert_not_contains "$out" "FAILED" "4. ...and no failure"
git -C "$S" remote rename gone origin

# 5. clean and ahead: the preflight-main path pushes, exactly as before
rm -f "$S/dirty.txt"
git -C "$S" status --porcelain >&2
commit_origin p1; run_sync >/dev/null
commit_local p2
out="$(run_sync)"
assert_eq "$(origin_head)" "$(local_head)" "5. clean and ahead: pushed through the unchanged preflight path"
assert_not_contains "$out" "tree left as is" "5. ...not by the dirty-root helper"

assert_done
