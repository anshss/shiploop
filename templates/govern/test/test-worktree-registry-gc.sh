#!/usr/bin/env bash
# Regression: worktree registry gc and the allocator's inline reclaim.
#   (a) wt_registry_gc removes ONLY entries whose path is gone from disk (shared
#       implementation; the single gc both status --gc and the allocator call);
#   (b) the allocator, on a registry that LOOKS full, reclaims orphaned slots inline
#       before refusing (a headless caller has no operator to run status --gc);
#   (c) a genuinely full registry refuses with the live/orphan split named;
#   (d) `worktree:status -- --gc` delegates to the same shared implementation.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq unavailable"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib"

REG="$T/scripts/worktree/lib/registry.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$REG"

write_reg() { # <json>
  mkdir -p "$T/.worktrees"
  printf '%s\n' "$1" > "$T/.worktrees/registry.json"
}
read_reg() { cat "$T/.worktrees/registry.json"; }

# ══ (a) gc removes only orphans ═══════════════════════════════════════════════════════
mkdir -p "$T/wt/live-a" "$T/wt/live-c"     # slots 1 and 3 have live dirs; slot 2's dir is gone
write_reg '{"slots": {"0": {"name": "__main__", "path": "'"$T"'"}, "1": {"name": "live-a", "path": "'"$T/wt/live-a"'"}, "2": {"name": "dead-b", "path": "'"$T/wt/gone"'"}, "3": {"name": "live-c", "path": "'"$T/wt/live-c"'"}}, "nextSlot": 4}'

# shellcheck disable=SC1090
source "$REG"

out_gc="$(wt_registry_gc)"; rc_gc=$?
assert_eq "$rc_gc" "0" "gc on a mixed registry succeeds"
assert_contains "$out_gc" "freed slot 2 (dead-b)" "gc: reports the orphaned slot freed"
assert_not_contains "$out_gc" "live-a" "gc: never touches a live entry"
assert_eq "$(read_reg | jq -r '.slots | keys | join(",")')" "0,1,3" "gc: only the orphan slot removed"
assert_eq "$(wt_registry_find_orphans | wc -l | tr -d ' ')" "0" "gc: no orphans left after gc"

out_gc2="$(wt_registry_gc)"
assert_eq "$out_gc2" "" "gc on a clean registry is a no-op"

# ══ (b) allocator reclaims orphans inline before refusing ═════════════════════════════
# Cap the ceiling low so "full" is reachable in a test: 3 slots, all orphaned.
# WT_MAX_SLOT is expanded AT SOURCE TIME ("${WT_MAX_SLOT:-99}"), so set it and re-source
# the library; a plain env assignment after sourcing would change nothing.
WT_MAX_SLOT=3
# shellcheck disable=SC1090
source "$REG"
mkdir -p "$T/wt/gone1" "$T/wt/gone2" "$T/wt/gone3"
write_reg '{"slots": {"0": {"name": "__main__", "path": "'"$T"'"}, "1": {"name": "gone1", "path": "'"$T/wt/gone1"'"}, "2": {"name": "gone2", "path": "'"$T/wt/gone2"'"}, "3": {"name": "gone3", "path": "'"$T/wt/gone3"'"}}, "nextSlot": 4}'
rm -rf "$T/wt/gone1" "$T/wt/gone2" "$T/wt/gone3"

slot="$(wt_registry_alloc_and_register fresh-one "$T/wt/fresh-one")"; rc_alloc=$?
assert_eq "$rc_alloc" "0" "allocator on an all-orphans full registry: succeeds via inline reclaim"
assert_eq "$slot" "1" "allocator: reclaims the smallest orphaned slot"
assert_contains "$(read_reg | jq -r '.slots | keys | join(",")')" "1" "allocator: new entry registered"
assert_eq "$(read_reg | jq -r '.slots["1"].name')" "fresh-one" "allocator: new entry named"

# ══ (c) genuinely full registry: refuse, naming the live/orphan split ═════════════════
mkdir -p "$T/wt/fresh-one" "$T/wt/gone2" "$T/wt/gone3"   # all three slots LIVE this time
write_reg '{"slots": {"0": {"name": "__main__", "path": "'"$T"'"}, "1": {"name": "fresh-one", "path": "'"$T/wt/fresh-one"'"}, "2": {"name": "live2", "path": "'"$T/wt/gone2"'"}, "3": {"name": "live3", "path": "'"$T/wt/gone3"'"}}, "nextSlot": 4}'
out_refused="$(wt_registry_alloc_and_register fresh-two "$T/wt/fresh-two" 2>&1)"; rc_refused=$?
assert_eq "$rc_refused" "1" "allocator on a genuinely full registry refuses"
assert_contains "$out_refused" "no free slot ≤ 3 (3 live, 0 orphaned" \
  "allocator refusal: names the live/orphan split instead of a bare threshold"
assert_contains "$out_refused" "worktree:status -- --gc" "allocator refusal: names the command"
assert_eq "$(read_reg | jq -r '.slots["1"].name')" "fresh-one" "refusal wrote nothing"

# ══ (d) status --gc delegates to the shared implementation ════════════════════════════
ST="$T/scripts/worktree/status.sh"
cp "$DIR/../../worktree/status.sh" "$ST"
cat > "$T/scripts/lib/workspace.sh" <<EOF
ROOT_PM=npm
WORKTREE_BASE="$T/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
EOF
mkdir -p "$T/wt/live-x"
write_reg '{"slots": {"0": {"name": "__main__", "path": "'"$T"'"}, "1": {"name": "live-x", "path": "'"$T/wt/live-x"'"}, "2": {"name": "stale-y", "path": "'"$T/wt/no-such-dir"'"}}, "nextSlot": 3}'

out_status="$(bash "$ST" --gc 2>&1)"; rc_status=$?
assert_eq "$rc_status" "0" "status --gc succeeds"
assert_contains "$out_status" "freed slot 2 (stale-y)" "status --gc: delegates to wt_registry_gc"
assert_contains "$out_status" "(orphaned)" "status --gc: table still flags the orphan before removal"
assert_not_contains "$(read_reg | jq -r '.slots | keys | join(",")')" "2" "status --gc: orphaned slot removed from the registry"
assert_contains "$(read_reg | jq -r '.slots | keys | join(",")')" "1" "status --gc: live slots untouched"

assert_done
