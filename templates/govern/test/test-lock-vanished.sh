#!/usr/bin/env bash
# A lock released between a waiter's failed mkdir and its staleness check must never be reclaimed.
# govern::mtime prints 0 for a missing path; turning that into an age as "now minus 0" read as
# decades, judged the vanished lock stale, and rm -rf'd whatever another actor had just re-created
# there (two holders, one lost update). Proves: the age of a missing path is 0, and lock_acquire /
# lock_try facing a lock that vanishes mid-check never remove anything and simply take it with mkdir.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
source "$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

assert_eq "$(govern::_lock_age "$T/missing")" "0" "_lock_age of a missing path is 0"

mkdir "$T/old"; touch -t 200001010000 "$T/old"
[[ "$(govern::_lock_age "$T/old")" -gt 300 ]] && r=old || r=young
assert_eq "$r" "old" "_lock_age still reports a genuinely old lock as old"

# Simulate the release landing between the failed mkdir and the check: the first mkdir fails (a lock
# exists), the holder check then runs with the dir already gone. rm is shadowed to record any removal.
RMLOG="$T/rm.log"
rm() { printf '%s\n' "$*" >> "$RMLOG"; command rm "$@"; }

vanish_mkdir() { # first call: create-then-fail path; later calls: real mkdir
  if [[ ! -e "$T/.mk" ]]; then : > "$T/.mk"; command rm -rf "$LOCK"; return 1; fi
  command mkdir "$@"
}
mkdir() { if [[ "$1" == "$LOCK" ]]; then vanish_mkdir "$@"; else command mkdir "$@"; fi; }

LOCK="$T/locks/a"; command mkdir -p "$T/locks"
govern::lock_acquire "$LOCK" 5 300 && rc=0 || rc=$?
assert_eq "$rc" "0" "lock_acquire takes a lock that vanished mid-check"
assert_eq "$(cat "$RMLOG" 2>/dev/null)" "" "lock_acquire removed nothing"
[[ -d "$LOCK" ]] && h=held || h=free
assert_eq "$h" "held" "lock_acquire holds the lock afterwards"

command rm -f "$T/.mk" "$RMLOG"; command rm -rf "$LOCK"
LOCK="$T/locks/b"
govern::lock_try "$LOCK" 300 && rc=0 || rc=$?
# lock_try's first mkdir fails; with the dir vanished it must not reclaim (no rm), so it returns 1 and
# the caller retries; a second call then succeeds.
assert_eq "$(cat "$RMLOG" 2>/dev/null)" "" "lock_try removed nothing"
govern::lock_try "$LOCK" 300 && rc2=0 || rc2=$?
assert_eq "$rc2" "0" "lock_try takes the vanished lock on retry"
assert_done
