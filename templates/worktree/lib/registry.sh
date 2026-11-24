#!/usr/bin/env bash
# Registry read/write/lock helpers for the worktree slot allocator.
# Source from other scripts; do not invoke directly. Generic — no per-workspace
# values live here (paths are stored absolute), so /shiploop:setup never edits it.
#
# Exports:
#   WT_ROOT          — absolute path of the main checkout
#   WT_REGISTRY      — absolute path of .worktrees/registry.json
#   WT_LOCK          — absolute path of the slot-alloc lock directory
#
# Functions:
#   wt_registry_read                          — cat registry.json (creates default if missing)
#   wt_registry_write JSON                     — atomic write of JSON to registry.json
#   wt_registry_with_lock CMD                  — run CMD while holding the slot-alloc lock
#   wt_registry_alloc_slot                     — pick smallest free slot ≥ 1, print it
#   wt_registry_add NAME PATH SLOT             — append slot entry, bump nextSlot
#   wt_registry_alloc_and_register NAME PATH   — atomic alloc + add (wrap in with_lock);
#                                                self-heals a STALE entry (registered path gone)
#                                                but refuses a LIVE name collision; prints slot
#   wt_registry_remove NAME                    — drop slot entry by name, print its slot
#   wt_registry_path_for NAME                  — print path of named slot, exit 1 if missing
#   wt_registry_slot_for NAME                  — print slot number of named slot, exit 1 if missing
#   wt_registry_find_orphans                  ; print slot/name/path of entries whose path is
#                                                gone from disk (shared orphan detector)
#   wt_registry_gc                            ; remove every orphaned entry (wrap in with_lock).
#                                                The SINGLE gc implementation: status --gc and
#                                                the allocator's inline reclaim both call it
#                                                rather than reimplementing orphan detection.
#
# Locking: a claimed directory (mkdir, then an exclusive holder-file create; see wt_lock_claim).
# Works on macOS + Linux with zero extra binaries (flock is Linux-only). Locks older than 30s whose
# holder is gone are auto-broken, one reclaimer at a time, so a crashed script can't wedge slot
# allocation forever.
set -uo pipefail

# Derived UNCONDITIONALLY from this file's own location. An inherited WT_ROOT env var is
# deliberately ignored: it is not a documented knob (no consumer reads it), and letting it
# redirect WT_REGISTRY/WT_LOCK below would point every registry operation at a directory
# of the caller's choosing instead of the main checkout — silently, since the guard only
# catches the linked-worktree case (.git as a file).
WT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Registry operations are MAIN-CHECKOUT-ONLY. WT_ROOT above is derived from THIS file's
# location, and every dispatch worktree carries its own full copy of scripts/, so a script
# invoked with cwd inside a worktree (its own package.json, or a relative path) sources the
# WORKTREE's copy and resolves WT_ROOT to the worktree. Every function below would then read
# and write <worktree>/.worktrees/registry.json — a file that does not exist until a read
# default-creates one whose __main__ slot points at the worktree itself. That scoped registry
# poisons both directions: dispatches registered against it never reach the real registry
# (the worktree is on disk but unknown to worktree:rm / govern:resolve), and its slot-0 path
# re-anchors every __main__ resolution inside a worktree. A linked worktree is detectable by
# its .git being a FILE (the main checkout's is a directory), so refuse the whole library in
# that context rather than operate on the wrong file silently.
if [ -f "$WT_ROOT/.git" ]; then
  printf '%s\n' \
    "worktree registry: WT_ROOT resolved to '$WT_ROOT', a linked git worktree — not the main checkout." \
    "This scripts/ copy was invoked from inside a worktree; its registry helpers would read and write" \
    "'$WT_ROOT/.worktrees/registry.json' instead of the main checkout's registry. Re-run from the main checkout." >&2
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 1; else exit 1; fi
fi

WT_REGISTRY="$WT_ROOT/.worktrees/registry.json"
WT_LOCK="$WT_ROOT/.worktrees/slot-alloc.lock.d"

# Highest allocatable slot. Each slot owns a SLOT_PORT_STEP-wide port band
# (slot * step + base), so raising the ceiling only widens the port space; it does
# not overlap an existing slot. The hub's slots step by SLOT_PORT_STEP=10, so the
# stock ceiling of 99 covers ports up to base+990; raise it (env override) only
# when a workspace genuinely runs that many concurrent worktrees.
WT_MAX_SLOT="${WT_MAX_SLOT:-99}"

wt_registry_read() {
  if [ ! -f "$WT_REGISTRY" ]; then
    mkdir -p "$(dirname "$WT_REGISTRY")"
    # Pretty-print so subsequent jq-driven writes leave the file format stable.
    jq -n --arg root "$WT_ROOT" '{slots: {"0": {name: "__main__", path: $root}}, nextSlot: 1}' > "$WT_REGISTRY"
  fi
  cat "$WT_REGISTRY"
}

wt_registry_write() {
  local json="$1"
  # Slot 0 is contractually __main__ -> WT_ROOT (the main checkout). Refuse any write that
  # moves or drops it: it would re-anchor every __main__ resolution (worktree:rm, govern:resolve,
  # the exec/stack lookups) at a worktree and reset nextSlot with it. Every writer in this file
  # round-trips slot 0 unchanged from a prior read, so a mismatch means a caller stitched in a
  # foreign or stale registry body — refuse loudly rather than persist it.
  local slot0
  slot0="$(printf '%s' "$json" | jq -r --arg root "$WT_ROOT" '
    (.slots["0"] // null) as $s
    | if ($s | type) == "object" and $s.name == "__main__" and $s.path == $root
      then "ok"
      else "bad:" + (($s.path // "<absent>") | tostring)
      end' 2>/dev/null || echo "bad:<unparseable>")"
  if [ "$slot0" != "ok" ]; then
    echo "wt_registry_write: refusing write — slot 0 (__main__) must stay the main checkout '$WT_ROOT'; got path: ${slot0#bad:}" >&2
    return 1
  fi
  local tmp="$WT_REGISTRY.tmp.$$"
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$WT_REGISTRY"
}

# Exclusive claim of one lock dir: create the dir, then create its `holder` file with noclobber,
# which bash opens O_EXCL. mkdir alone is not trusted: a mkdir that is not itself exclusive (a Rust
# coreutils build was observed exiting 0 for two racers on one path) would let both racers hold the
# lock. Exactly one racer can create the holder file; a loser leaves the dir alone (the winner owns
# it) and reports not claimed. Same idiom as govern::_lock_claim, mirrored here because this file is
# installed under scripts/worktree/lib and cannot assume scripts/govern/lib is sourceable.
# Stamp the holder file with the pid of the shell that is claiming, never `$$`: `$$` keeps the
# top-level ancestor's pid even inside a subshell, so a claim taken by a subshell recorded its
# still-living ancestor and pid-liveness reclaim saw the lock as alive for as long as the ancestor
# ran. The noclobber-create subshell execs sh, so the recorded pid is that of the process which
# launched it: the claiming shell's own pid, visible even inside a subshell where `$$` cannot see
# it. `sh` is used rather than `$BASHPID` because bash 3.2, the system bash on macOS, predates
# BASHPID and this must run on a stock machine. Consume only by redirection: a command
# substitution would fork its own transient subshell and stamp that pid, which is dead before the
# claim is ever checked.
_wt_lock_stamp_holder() { # claimdir
  ( set -C; exec sh -c 'echo "$PPID"' > "$1/holder" ) 2>/dev/null || return 1
  return 0
}

wt_lock_claim() { # dir
  mkdir "$1" 2>/dev/null || return 1
  _wt_lock_stamp_holder "$1" || return 1
  return 0
}

# mtime age of a path in seconds; 0 when it is absent or unreadable, so a lock released mid-check
# never reads as stale. GNU stat first (Linux), then BSD (macOS); see govern::_lock_age for the
# trap this dodges.
wt_lock_age() { # path
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  m="${m//[!0-9]/}"; [ -n "$m" ] || m=0
  if [ "$m" -gt 0 ]; then echo $(( $(date +%s) - m )); else echo 0; fi
}

# Remove a stale lock without letting two waiters both remove it: serialized behind a short-lived
# exclusive `<lock>.reclaim` claim, with the holder-dead and age checks repeated inside it. A
# waiter that cannot take the claim returns 1 and goes back to its normal retry. A `.reclaim` left
# by a reclaimer that died is removed once it is older than 60s. Returns 0 when it removed the lock.
wt_lock_reclaim() { # dir stale_s
  local lock="$1" stale="$2" rl="$1.reclaim" ret=1 hpid=""
  if [ "$(wt_lock_age "$rl")" -gt 60 ]; then rm -rf "$rl" 2>/dev/null || true; fi
  wt_lock_claim "$rl" || return 1
  if [ -f "$lock/holder" ]; then hpid="$(tr -dc '0-9' < "$lock/holder" 2>/dev/null || true)"; fi
  if { [ -z "$hpid" ] || ! kill -0 "$hpid" 2>/dev/null; } && [ "$(wt_lock_age "$lock")" -gt "$stale" ]; then
    rm -rf "$lock" 2>/dev/null || true
    ret=0
  fi
  rm -rf "$rl" 2>/dev/null || true
  return "$ret"
}

wt_registry_with_lock() {
  mkdir -p "$(dirname "$WT_LOCK")"
  local tries=0
  # 100 x 100ms = 10s. A lock whose holder is gone and that is >30s old gets reaped so a crashed
  # caller doesn't permanently block slot allocation.
  while ! wt_lock_claim "$WT_LOCK"; do
    if [ -d "$WT_LOCK" ] && [ "$(wt_lock_age "$WT_LOCK")" -gt 30 ]; then
      wt_lock_reclaim "$WT_LOCK" 30 && continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      echo "slot-alloc lock timeout after 10s" >&2
      return 1
    fi
    sleep 0.1
  done
  local ret=0
  "$@" || ret=$?
  rm -rf "$WT_LOCK" 2>/dev/null || true
  return $ret
}

wt_registry_alloc_slot() {
  local reg used i
  reg=$(wt_registry_read)
  used=$(printf '%s' "$reg" | jq -r '.slots | keys[]' | sort -n)
  for i in $(seq 1 "$WT_MAX_SLOT"); do
    if ! grep -qx "$i" <<<"$used"; then
      echo "$i"
      return 0
    fi
  done
  echo "no free slot ≤ $WT_MAX_SLOT" >&2
  return 1
}

# Orphan = a registered entry whose path no longer exists on disk: the worktree was
# removed by hand (or by a git worktree remove outside worktree:rm) and the registry
# entry outlived it. Shared detector; wt_registry_gc is the ONLY remover.
wt_registry_find_orphans() {
  wt_registry_read | jq -r '.slots | to_entries[] | select(.key != "0") | [.key, .value.name, .value.path] | @tsv' | \
    while IFS=$'\t' read -r slot name path; do
      [ -d "$path" ] || printf '%s\t%s\t%s\n' "$slot" "$name" "$path"
    done
}

# Drop every orphaned entry. Wrap in wt_registry_with_lock (status --gc) or call from
# inside an existing critical section (the allocator's inline reclaim, which must not
# take a second lock; the lock helpers are not reentrant). Prints one line per freed slot.
wt_registry_gc() {
  local orphans slot name path
  orphans="$(wt_registry_find_orphans)"
  [ -n "$orphans" ] || return 0
  while IFS=$'\t' read -r slot name path; do
    wt_registry_remove "$name" >/dev/null
    echo "freed slot $slot ($name)"
  done <<<"$orphans"
  return 0
}

wt_registry_add() {
  local name="$1" path="$2" slot="$3"
  local reg now
  reg=$(wt_registry_read)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  reg=$(printf '%s' "$reg" | jq \
    --arg slot "$slot" --arg name "$name" --arg path "$path" --arg now "$now" \
    '.slots[$slot] = {name: $name, path: $path, createdAt: $now} | .nextSlot = (([.slots | keys[] | tonumber] | max) + 1)')
  wt_registry_write "$reg"
}

wt_registry_alloc_and_register() {
  # Atomic alloc + add. Callers MUST invoke this via wt_registry_with_lock so the
  # read → name-check → slot-pick → write happens in one critical section.
  # Splitting alloc and add into two locks lets two parallel `new` calls grab the
  # same slot, then the second add silently clobbers the first entry.
  local name="$1" path="$2"
  local reg used i slot now existing_path
  reg=$(wt_registry_read)
  # A name collision is only a REAL collision if the registered worktree still exists on disk.
  # A `git worktree remove` (or a manual rm -rf) done OUTSIDE worktree:rm leaves a STALE registry
  # entry whose path is gone — which used to abort worktree:new with "already in registry" and
  # fast-fail a govern re-run of a resolved/re-opened ticket. Self-heal: drop the
  # stale entry and fall through to re-allocate (freeing its slot for reuse). Keep the hard error
  # only when the path is still present (a genuine live collision).
  existing_path=$(printf '%s' "$reg" | jq -r --arg n "$name" \
    '.slots | to_entries[] | select(.value.name == $n) | .value.path' | sed -n '1p')
  if [ -n "$existing_path" ] && [ "$existing_path" != "null" ]; then
    if [ -e "$existing_path" ]; then
      echo "worktree '$name' already in registry (path exists: $existing_path)" >&2
      return 1
    fi
    echo "worktree '$name' had a STALE registry entry (path gone: $existing_path) — self-healing" >&2
    reg=$(printf '%s' "$reg" | jq --arg n "$name" \
      '((.slots | to_entries | map(select(.value.name == $n)))[0].key) as $k
       | if $k then del(.slots[$k]) else . end')
  fi
  used=$(printf '%s' "$reg" | jq -r '.slots | keys[]' | sort -n)
  slot=""
  for i in $(seq 1 "$WT_MAX_SLOT"); do
    if ! grep -qx "$i" <<<"$used"; then
      slot="$i"
      break
    fi
  done
  if [ -z "$slot" ]; then
    # The registry LOOKS full, but an entry whose directory no longer exists on disk is
    # an orphan, not a real occupant: reclaim inline before refusing. A headless caller
    # (a govern worker) has no operator around to run `worktree:status -- --gc` itself.
    # This calls the same gc implementation status --gc uses (wt_registry_gc, above)
    # rather than reimplementing orphan detection here. No separate lock is taken: we
    # are already inside the caller's wt_registry_with_lock critical section.
    local gc_out
    gc_out="$(wt_registry_gc)"
    if [ -n "$gc_out" ]; then
      echo "$gc_out" >&2
      reg=$(wt_registry_read)
      used=$(printf '%s' "$reg" | jq -r '.slots | keys[]' | sort -n)
      for i in $(seq 1 "$WT_MAX_SLOT"); do
        if ! grep -qx "$i" <<<"$used"; then
          slot="$i"
          break
        fi
      done
    fi
  fi
  if [ -z "$slot" ]; then
    # Still nothing free after reclaiming every orphan: a genuine refusal. Name the
    # live/orphan split (orphaned is necessarily 0 here, everything reclaimable has
    # already been reclaimed) and the exact command, instead of a bare threshold.
    local total orphaned live
    total=$(printf '%s' "$used" | grep -vx '0' | grep -c . || true)
    orphaned=$(wt_registry_find_orphans | grep -c . || true)
    live=$((total - orphaned))
    echo "no free slot ≤ $WT_MAX_SLOT ($live live, $orphaned orphaned; all reclaimable slots already reclaimed)" >&2
    echo "run: ${ROOT_PM:-npm} run worktree:status -- --gc" >&2
    return 1
  fi
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  reg=$(printf '%s' "$reg" | jq \
    --arg slot "$slot" --arg name "$name" --arg path "$path" --arg now "$now" \
    '.slots[$slot] = {name: $name, path: $path, createdAt: $now} | .nextSlot = (([.slots | keys[] | tonumber] | max) + 1)')
  wt_registry_write "$reg"
  echo "$slot"
}

wt_registry_remove() {
  local name="$1"
  local reg slot
  reg=$(wt_registry_read)
  slot=$(printf '%s' "$reg" | jq -r --arg n "$name" '.slots | to_entries[] | select(.value.name == $n) | .key' | sed -n '1p')
  if [ -z "$slot" ] || [ "$slot" = "null" ]; then
    return 1
  fi
  reg=$(printf '%s' "$reg" | jq --arg slot "$slot" \
    'del(.slots[$slot]) | .nextSlot = (([.slots | keys[] | tonumber] | max) + 1)')
  wt_registry_write "$reg"
  echo "$slot"
}

wt_registry_path_for() {
  local name="$1"
  local path
  path=$(wt_registry_read | jq -r --arg n "$name" '.slots | to_entries[] | select(.value.name == $n) | .value.path')
  if [ -z "$path" ] || [ "$path" = "null" ]; then
    echo "unknown worktree: $name" >&2
    return 1
  fi
  echo "$path"
}

wt_registry_slot_for() {
  local name="$1"
  local slot
  slot=$(wt_registry_read | jq -r --arg n "$name" '.slots | to_entries[] | select(.value.name == $n) | .key')
  if [ -z "$slot" ] || [ "$slot" = "null" ]; then
    echo "unknown worktree: $name" >&2
    return 1
  fi
  echo "$slot"
}
