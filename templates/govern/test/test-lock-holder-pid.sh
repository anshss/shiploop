#!/usr/bin/env bash
# Every claim primitive must stamp its holder file with the pid of the shell that actually holds
# the claim, not `$$`: `$$` keeps the top-level ancestor's pid inside a subshell, so a claim taken
# by a subshell recorded its still-living ancestor and pid-liveness reclaim could never fire while
# that ancestor lived. Proves: a claim taken in a background subshell records that subshell's real
# pid (all three primitives); a holder killed inside its subshell reads dead and is reclaimable;
# a claim taken in a parent and released in the same parent is unaffected (its holder reads alive
# and reclaim refuses it); a double-claim is still rejected.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# lib/install-semaphore.sh and worktree/lib/registry.sh: templates (template layout) | scripts (workspace).
SEM=""; REGSRC=""
for _cand in "$DIR/../../lib/install-semaphore.sh" "$DIR/../../../lib/install-semaphore.sh"; do
  [ -f "$_cand" ] && { SEM="$(cd "$(dirname "$_cand")" && pwd)/install-semaphore.sh"; break; }
done
for _cand in "$DIR/../../worktree/lib/registry.sh" "$DIR/../../../worktree/lib/registry.sh"; do
  [ -f "$_cand" ] && { REGSRC="$(cd "$(dirname "$_cand")" && pwd)/registry.sh"; break; }
done
[ -n "$SEM" ] && [ -n "$REGSRC" ] || { echo "cannot locate install-semaphore scripts from $DIR" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GOVERN_WS_ROOT="$T"
# common.sh sources $WS_ROOT/scripts/lib/workspace.sh; seed a minimal one in the temp WS_ROOT.
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
log() { :; }
export -f log
ROOT="$T/semroot"
export ROOT
command mkdir -p "$ROOT/logs"
# registry.sh derives WT_ROOT from its own location, so run it from a throwaway root (the hub
# checkout can itself be a linked worktree, where registry.sh refuses to run).
command mkdir -p "$T/scripts/worktree/lib"
cp "$REGSRC" "$T/scripts/worktree/lib/registry.sh"

source "$DIR/../lib/common.sh"
source "$T/scripts/worktree/lib/registry.sh"
source "$SEM"

# Wait until a path exists, so a just-forked subshell's claim is observed without a fixed sleep.
await() { # path
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}

# ── each primitive stamps the claiming subshell's real pid ──
# The hold must run as a DIRECT background job of this shell: a background job started inside a
# command substitution is killed when the substitution's subshell exits, so the captured pid would
# be dead before the first assertion ran.
for _fn in govern::_lock_claim sem_claim wt_lock_claim; do
  L="$T/h-$_fn"; command rm -rf "$L"
  ( "$_fn" "$L" && sleep 30 ) &
  bg=$!
  await "$L/holder"
  assert_eq "$(cat "$L/holder" 2>/dev/null)" "$bg" "$_fn: holder records the claiming subshell's pid"
  kill -9 "$bg" 2>/dev/null
  wait "$bg" 2>/dev/null || true
  if kill -0 "$(cat "$L/holder" 2>/dev/null)" 2>/dev/null; then rc=1; else rc=0; fi
  assert_eq "$rc" "0" "$_fn: holder killed inside its subshell reads dead"
  command rm -rf "$L"
done

# ── a dead subshell holder is reclaimable, not just detectable ──
# Reclaim also requires an aged mtime, so backdate the lock: reclaim must not depend on a
# same-second race between the claim and the check.
L="$T/reclaim-g"; command rm -rf "$L"
( govern::_lock_claim "$L" && sleep 30 ) &
bg=$!
await "$L/holder"
kill -9 "$bg" 2>/dev/null
wait "$bg" 2>/dev/null || true
touch -m -t 202001010000 "$L"
assert_eq "$(govern::_lock_reclaim "$L" 0 && echo reclaimed || echo kept)" "reclaimed" \
  "govern::_lock_reclaim removes a lock whose subshell holder is dead"

L="$T/reclaim-w"; command rm -rf "$L"
( wt_lock_claim "$L" && sleep 30 ) &
bg=$!
await "$L/holder"
kill -9 "$bg" 2>/dev/null
wait "$bg" 2>/dev/null || true
touch -m -t 202001010000 "$L"
assert_eq "$(wt_lock_reclaim "$L" 0 && echo reclaimed || echo kept)" "reclaimed" \
  "wt_lock_reclaim removes a lock whose subshell holder is dead"

# Install semaphore: the only slot is held by a dead pid, a new acquirer must reclaim it.
EV="$T/sem.events"; : > "$EV"
( export WORKTREE_INSTALL_PARALLEL=1 WORKTREE_INSTALL_WAIT_TIMEOUT=60
  source "$SEM"
  command mkdir -p "$INSTALL_SEM_DIR/1"
  echo 99999999 > "$INSTALL_SEM_DIR/1/holder"
  sem_acquire "r"; echo "+" >> "$EV"; sem_release; echo "-" >> "$EV" ) &
semwait=$!
wait "$semwait" || true
assert_eq "$(cat "$EV")" "$(printf '+\n-')" "sem_acquire reclaims a slot whose holder pid is dead"

# ── negative control: a claim taken and released in the same parent is unaffected ──
P="$T/parent"; command rm -rf "$P"
govern::_lock_claim "$P"
assert_eq "$(cat "$P/holder" 2>/dev/null)" "$$" "parent claim records the parent's own pid"
if kill -0 "$(cat "$P/holder" 2>/dev/null)" 2>/dev/null; then rc=1; else rc=0; fi
assert_eq "$rc" "1" "parent-held lock reads alive while the parent lives"
assert_eq "$(govern::_lock_holder_dead "$P" && echo dead || echo alive)" "alive" \
  "parent-held lock reads alive"
touch -m -t 202001010000 "$P"
assert_eq "$(govern::_lock_reclaim "$P" 0 && echo reclaimed || echo kept)" "kept" \
  "reclaim refuses a live holder even when its mtime has aged"
govern::lock_release "$P"
govern::_lock_claim "$P" && rc=0 || rc=1
assert_eq "$rc" "0" "lock re-claims after its parent releases it"
govern::lock_release "$P"

# ── exclusivity intact: the stamping write is still the O_EXCL point ──
L="$T/excl"; command rm -rf "$L"
govern::_lock_claim "$L" && rc=0 || rc=1
assert_eq "$rc" "0" "setup: first claim wins"
govern::_lock_claim "$L" && rc=0 || rc=1
assert_eq "$rc" "1" "second claim is rejected while the holder file exists"

# ── the stamp is never an empty or transient value ──
L="$T/sane"; command rm -rf "$L"
govern::_lock_claim "$L"
h="$(cat "$L/holder" 2>/dev/null)"
case "$h" in
  ''|*[!0-9]*) assert_eq "$h" "<numeric pid>" "holder stamp is numeric, got: $h" ;;
  *) assert_eq "ok" "ok" "holder stamp is numeric" ;;
esac
if kill -0 "$h" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "$rc" "0" "holder stamp names a live process immediately after claim"
govern::lock_release "$L"

assert_done
