#!/usr/bin/env bash
# Every mkdir-as-lock site must stay exclusive when mkdir itself is not, and stale reclaim must be
# serialized. A mkdir that exits 0 for a path that already exists (a Rust coreutils build was observed
# doing so for two racers) is simulated by a shim, so the result does not depend on the host's
# coreutils. Proves: exactly one of N concurrent claimers wins each claim primitive; the install
# semaphore never exceeds its cap; the registry lock admits one holder at a time; a second waiter that
# judged the same lock stale cannot remove the fresh lock a successor took; a live .reclaim claim
# blocks a reclaim and a long-dead one does not.
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

# lib/install-semaphore.sh and worktree/lib/registry.sh: templates (template layout) | scripts (workspace).
SEM=""; REGSRC=""
for _cand in "$DIR/../../lib/install-semaphore.sh" "$DIR/../../../lib/install-semaphore.sh"; do
  [ -f "$_cand" ] && { SEM="$(cd "$(dirname "$_cand")" && pwd)/install-semaphore.sh"; break; }
done
for _cand in "$DIR/../../worktree/lib/registry.sh" "$DIR/../../../worktree/lib/registry.sh"; do
  [ -f "$_cand" ] && { REGSRC="$(cd "$(dirname "$_cand")" && pwd)/registry.sh"; break; }
done
[ -n "$SEM" ] && [ -n "$REGSRC" ] || { echo "cannot locate install-semaphore.sh / registry.sh from $DIR" >&2; exit 1; }

# registry.sh derives WT_ROOT from its own location, so run it from a throwaway root.
command mkdir -p "$T/scripts/worktree/lib"
cp "$REGSRC" "$T/scripts/worktree/lib/registry.sh"
log() { :; }
export -f log

# A mkdir that reports success whether or not the path already existed.
mkdir() { command mkdir -p "$@"; return 0; }

source "$T/scripts/worktree/lib/registry.sh"
ROOT="$T/semroot"; command mkdir -p "$ROOT/logs"
source "$SEM"

count_wins() { find "$T/wins" -type f 2>/dev/null | wc -l | tr -d ' '; }
race() { # <claim-fn> <lockdir>: 12 concurrent claimers, prints how many won
  local fn="$1" d="$2" i
  command rm -rf "$T/wins" "$d"; command mkdir -p "$T/wins"
  for i in $(seq 1 12); do ( "$fn" "$d" && : > "$T/wins/$i" ) & bg_reap "$!"; done
  wait
  count_wins
}
assert_eq "$(race govern::_lock_claim "$T/l1")" "1" "govern::_lock_claim: one winner among 12 racers on a non-exclusive mkdir"
assert_eq "$(race sem_claim "$T/l2")" "1" "sem_claim: one winner among 12 racers on a non-exclusive mkdir"
assert_eq "$(race wt_lock_claim "$T/l3")" "1" "wt_lock_claim: one winner among 12 racers on a non-exclusive mkdir"

# Peak concurrent holders from a +/- event log.
peak() { awk '{ if ($0=="+") n++; else n--; if (n>max) max=n } END { print max+0 }' "$1"; }

# Install semaphore: 9 real processes against a cap of 3.
EV="$T/sem.events"; : > "$EV"
for i in $(seq 1 9); do
  (
    export WORKTREE_INSTALL_PARALLEL=3 WORKTREE_INSTALL_WAIT_TIMEOUT=60
    source "$SEM"
    sem_acquire "w$i"
    echo "+" >> "$EV"; sleep 0.4; echo "-" >> "$EV"
    sem_release
  ) &
  bg_reap "$!"
done
wait
p="$(peak "$EV")"
[ "$p" -le 3 ] && r=within || r="peak=$p"
assert_eq "$r" "within" "install semaphore stays within its cap of 3 on a non-exclusive mkdir"

# Registry lock: 8 concurrent critical sections must never overlap.
EV="$T/reg.events"; : > "$EV"
crit() { echo "+" >> "$EV"; sleep 0.15; echo "-" >> "$EV"; }
for i in $(seq 1 8); do ( wt_registry_with_lock crit ) & bg_reap "$!"; done
wait
assert_eq "$(peak "$EV")" "1" "registry lock admits one holder at a time on a non-exclusive mkdir"
assert_eq "$(grep -c '^+$' "$EV")" "8" "every registry critical section ran"

# Stale reclaim, govern lock: waiter A removes the stale lock, a successor claims it fresh, then waiter
# B (which also judged it stale before A acted) takes the reclaim claim. B must re-check and leave the
# successor's lock alone.
STALE="$T/stale"
dead_lock() { command rm -rf "$1" "$1.reclaim"; command mkdir -p "$1"; echo 999999 > "$1/holder"; touch -t 200001010000 "$1"; }
dead_lock "$STALE"
govern::_lock_reclaim "$STALE" 300 && rc=0 || rc=$?
assert_eq "$rc" "0" "govern: first waiter reclaims a truly stale lock"
govern::_lock_claim "$STALE" && rc=0 || rc=$?
assert_eq "$rc" "0" "govern: a successor claims the lock fresh"
govern::_lock_reclaim "$STALE" 300 && rc=0 || rc=$?
assert_eq "$rc" "1" "govern: the second waiter re-checks inside the reclaim claim and removes nothing"
assert_eq "$(cat "$STALE/holder")" "$$" "govern: the successor still holds its lock"
[ -e "$STALE.reclaim" ] && r=left || r=clean
assert_eq "$r" "clean" "govern: the reclaim claim is released after a refused reclaim"

# Two real waiters on one truly stale lock: they never hold it at the same time.
dead_lock "$STALE"; EV="$T/gov.events"; : > "$EV"
for i in 1 2; do
  ( govern::lock_acquire "$STALE" 10 300 && { echo "+" >> "$EV"; sleep 1.5; echo "-" >> "$EV"; govern::lock_release "$STALE"; } ) &
done
wait
assert_eq "$(peak "$EV")" "1" "govern: two waiters on one stale lock never overlap"
assert_eq "$(grep -c '^+$' "$EV")" "2" "govern: both waiters eventually ran"

# A live .reclaim claim blocks a reclaim; a long-dead one does not.
dead_lock "$STALE"; govern::_lock_claim "$STALE.reclaim"
govern::_lock_reclaim "$STALE" 300 && rc=0 || rc=$?
assert_eq "$rc" "1" "govern: a held .reclaim claim blocks another reclaimer"
touch -t 200001010000 "$STALE.reclaim"
govern::_lock_reclaim "$STALE" 300 && rc=0 || rc=$?
assert_eq "$rc" "0" "govern: a .reclaim older than 60s is cleared and the reclaim proceeds"

# Registry reclaim: same shape.
RL="$T/reglock"
dead_lock "$RL"
wt_lock_reclaim "$RL" 30 && rc=0 || rc=$?
assert_eq "$rc" "0" "registry: first waiter reclaims a truly stale lock"
wt_lock_claim "$RL" && rc=0 || rc=$?
assert_eq "$rc" "0" "registry: a successor claims the lock fresh"
wt_lock_reclaim "$RL" 30 && rc=0 || rc=$?
assert_eq "$rc" "1" "registry: the second waiter re-checks inside the reclaim claim and removes nothing"
assert_eq "$(cat "$RL/holder")" "$$" "registry: the successor still holds its lock"
dead_lock "$RL"; wt_lock_claim "$RL.reclaim"
wt_lock_reclaim "$RL" 30 && rc=0 || rc=$?
assert_eq "$rc" "1" "registry: a held .reclaim claim blocks another reclaimer"
touch -t 200001010000 "$RL.reclaim"
wt_lock_reclaim "$RL" 30 && rc=0 || rc=$?
assert_eq "$rc" "0" "registry: a .reclaim older than 60s is cleared and the reclaim proceeds"
dead_lock "$RL"; echo "$$" > "$RL/holder"
wt_lock_reclaim "$RL" 30 && rc=0 || rc=$?
assert_eq "$rc" "1" "registry: a stale lock whose holder is alive is never reclaimed"

# Semaphore reclaim: every slot dead-held. A live .reclaim blocks reclaiming (acquire degrades to
# uncapped after the wait); an old one is cleared, the slots are reclaimed, and the next pass takes one.
sem_case() { # <backdate-reclaim 0|1> -> prints yes if a slot was acquired under the cap
  (
    export WORKTREE_INSTALL_PARALLEL=2 WORKTREE_INSTALL_WAIT_TIMEOUT=4
    ROOT="$T/semcase"; command rm -rf "$ROOT"; command mkdir -p "$ROOT/logs"
    source "$SEM"
    for i in 1 2; do command mkdir -p "$INSTALL_SEM_DIR/$i"; echo 999999 > "$INSTALL_SEM_DIR/$i/holder"; done
    sem_claim "$INSTALL_SEM_DIR/.reclaim" && [ -f "$INSTALL_SEM_DIR/.reclaim/holder" ] || { echo setup-failed; return 0; }
    [ "$1" = 1 ] && touch -t 200001010000 "$INSTALL_SEM_DIR/.reclaim"
    sem_acquire "r"
    [ -n "$INSTALL_SEM_HELD" ] && echo yes || echo no
  )
}
assert_eq "$(sem_case 0)" "no" "semaphore: a held .reclaim claim blocks slot reclaim"
assert_eq "$(sem_case 1)" "yes" "semaphore: a .reclaim older than 60s is cleared and a dead slot is reclaimed"
assert_done
