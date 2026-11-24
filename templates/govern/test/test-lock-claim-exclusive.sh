#!/usr/bin/env bash
# The lock helpers must not rely on mkdir's exit status alone for mutual exclusion. A mkdir that is
# not itself exclusive (a Rust coreutils mkdir was observed exiting 0 for two racers on one path) let
# two actors both "acquire" one lock. The claim is completed by creating the holder file with
# noclobber, which only one racer can do. Proves: with a mkdir that always reports success, a second
# claimant on a held lock is refused by lock_try, and a blocking lock_acquire times out instead of
# entering.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# common.sh sources $WS_ROOT/scripts/lib/workspace.sh, which exists only in a scaffolded
# workspace; seed a minimal one in a temp GOVERN_WS_ROOT so the test also runs from the hub.
export GOVERN_WS_ROOT="$T"
mkdir -p "$T/scripts/lib"
cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
GITHUB_ORG="acme"
REPOS=(alpha)
GOVERN_MERGE_REPOS=(alpha)
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
source "$DIR/../lib/common.sh"

LOCK="$T/locks/x"; command mkdir -p "$T/locks"

govern::lock_try "$LOCK" && rc=0 || rc=$?
assert_eq "$rc" "0" "first claimant takes a free lock"
assert_eq "$(cat "$LOCK/holder")" "$$" "the holder file records the claimant pid"

# From here every mkdir "succeeds" without creating or failing, like a non-exclusive implementation.
mkdir() { return 0; }

govern::_lock_claim "$LOCK" && rc=0 || rc=$?
assert_eq "$rc" "1" "a second claimant is refused although mkdir reported success"
govern::lock_try "$LOCK" && rc=0 || rc=$?
assert_eq "$rc" "1" "lock_try refuses a lock whose holder file already exists"
govern::lock_acquire "$LOCK" 1 300 && rc=0 || rc=$?
assert_eq "$rc" "1" "lock_acquire times out instead of entering a held lock"
assert_eq "$(cat "$LOCK/holder")" "$$" "the holder file is untouched by the refused claimants"
assert_done
