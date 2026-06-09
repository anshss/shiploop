#!/usr/bin/env bash
# Registry read/write/lock helpers for the worktree slot allocator.
# Source from other scripts; do not invoke directly. Generic — no per-workspace
# values live here (paths are stored absolute), so /meta-repo:setup never edits it.
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
#                                                refuses on name collision; prints slot
#   wt_registry_remove NAME                    — drop slot entry by name, print its slot
#   wt_registry_path_for NAME                  — print path of named slot, exit 1 if missing
#   wt_registry_slot_for NAME                  — print slot number of named slot, exit 1 if missing
#
# Locking: mkdir is atomic on POSIX filesystems. Works on macOS + Linux with zero
# extra binaries (flock is Linux-only). Stale locks older than 30s are auto-broken
# so a crashed script can't wedge slot allocation forever.
set -uo pipefail

WT_ROOT="${WT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WT_REGISTRY="$WT_ROOT/.worktrees/registry.json"
WT_LOCK="$WT_ROOT/.worktrees/slot-alloc.lock.d"

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
  local tmp="$WT_REGISTRY.tmp.$$"
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$WT_REGISTRY"
}

wt_registry_with_lock() {
  mkdir -p "$(dirname "$WT_LOCK")"
  local tries=0
  # 100 × 100ms = 10s. Stale locks (>30s old) get reaped so a crashed caller
  # doesn't permanently block slot allocation.
  while ! mkdir "$WT_LOCK" 2>/dev/null; do
    if [ -d "$WT_LOCK" ]; then
      local age
      age=$(($(date +%s) - $(stat -f %m "$WT_LOCK" 2>/dev/null || stat -c %Y "$WT_LOCK" 2>/dev/null || date +%s)))
      if [ "$age" -gt 30 ]; then
        rmdir "$WT_LOCK" 2>/dev/null
        continue
      fi
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
  rmdir "$WT_LOCK" 2>/dev/null || true
  return $ret
}

wt_registry_alloc_slot() {
  local reg used i
  reg=$(wt_registry_read)
  used=$(printf '%s' "$reg" | jq -r '.slots | keys[]' | sort -n)
  for i in $(seq 1 99); do
    if ! grep -qx "$i" <<<"$used"; then
      echo "$i"
      return 0
    fi
  done
  echo "no free slot ≤ 99" >&2
  return 1
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
  local reg used i slot now
  reg=$(wt_registry_read)
  if printf '%s' "$reg" | jq -e --arg n "$name" '.slots | to_entries[] | select(.value.name == $n)' >/dev/null 2>&1; then
    echo "worktree '$name' already in registry" >&2
    return 1
  fi
  used=$(printf '%s' "$reg" | jq -r '.slots | keys[]' | sort -n)
  slot=""
  for i in $(seq 1 99); do
    if ! grep -qx "$i" <<<"$used"; then
      slot="$i"
      break
    fi
  done
  if [ -z "$slot" ]; then
    echo "no free slot ≤ 99" >&2
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
  slot=$(printf '%s' "$reg" | jq -r --arg n "$name" '.slots | to_entries[] | select(.value.name == $n) | .key' | head -1)
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
