#!/usr/bin/env bash
# Regression: re-running govern on a previously-resolved/re-opened ticket must spawn a fresh
# worker cleanly (no manual branch/worktree cleanup), and any GENUINE collision must surface its
# real cause instead of an opaque "#N FAILED".
#
# Worktree registry self-heals a STALE entry (path gone) and re-allocates; a LIVE entry (path
# still on disk) still hard-errors as a real collision.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# ── Part A: registry self-heal ──────────────────────────────────────────────
TMPA="$(mktemp -d)"; trap 'rm -rf "$TMPA"' EXIT
export WT_ROOT="$TMPA"
mkdir -p "$TMPA/.worktrees"
# Seed: slot 1 = a STALE entry whose path is gone; slot 2 = a LIVE entry whose path exists.
LIVE_PATH="$TMPA/live-wt"; mkdir -p "$LIVE_PATH"
GONE_PATH="$TMPA/gone-wt"   # deliberately NOT created
jq -n --arg gone "$GONE_PATH" --arg live "$LIVE_PATH" --arg root "$TMPA" '{
  slots: {
    "0": {name:"__main__", path:$root},
    "1": {name:"ticket-67", path:$gone, createdAt:"x"},
    "2": {name:"ticket-99", path:$live, createdAt:"x"}
  }, nextSlot: 3
}' > "$TMPA/.worktrees/registry.json"

source "$DIR/../../worktree/lib/registry.sh"

# Stale entry (path gone) → self-heals: returns a slot, drops the stale entry, frees its slot.
set +e
slot="$(wt_registry_alloc_and_register "ticket-67" "$TMPA/wt/ticket-67" 2>"$TMPA/err67")"; rc=$?
set -e
assert_eq "$rc" "0" "stale ticket-67 registry entry → alloc_and_register succeeds (self-heal)"
assert_contains "$(cat "$TMPA/err67")" "self-healing" "stale entry logs a self-heal, not a hard error"
# The healed registry must hold exactly one ticket-67 entry pointing at the NEW path.
reg="$(cat "$TMPA/.worktrees/registry.json")"
assert_eq "$(printf '%s' "$reg" | jq '[.slots[] | select(.name=="ticket-67")] | length')" "1" "exactly one ticket-67 entry after self-heal"
assert_eq "$(printf '%s' "$reg" | jq -r '[.slots[] | select(.name=="ticket-67")][0].path')" "$TMPA/wt/ticket-67" "ticket-67 entry now points at the fresh path"

# Live entry (path exists) → genuine collision: hard error, registry untouched.
set +e
out99="$(wt_registry_alloc_and_register "ticket-99" "$TMPA/wt/ticket-99" 2>&1)"; rc99=$?
set -e
assert_eq "$rc99" "1" "live ticket-99 (path on disk) → alloc_and_register refuses (real collision)"
assert_contains "$out99" "already in registry (path exists" "live collision reports the path that exists"

assert_done
