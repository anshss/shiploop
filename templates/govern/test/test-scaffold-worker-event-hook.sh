#!/usr/bin/env bash
# Regression for worker-event-emit.sh actually being WIRED, not just reachable by its own
# behavioral tests (test-worker-event-emit.sh). The hook answers three events (SubagentStart,
# PreToolUse, SubagentStop), and all three registrations have to exist in settings.json or the
# fleet event log stays exactly as unreachable as it was before this hook shipped.
#
# Contract:
#   1. A FRESH scaffold's .claude/settings.json (--component settings) declares SubagentStart, adds
#      worker-event-emit.sh to the existing PreToolUse "*" matcher, and to the existing SubagentStop
#      "*" matcher (alongside agent-progress-guard.sh).
#   2. --component settings-merge into an EXISTING settings.json that predates this hook (only
#      SubagentStop, only agent-progress-guard.sh, no PreToolUse/SubagentStart keys at all) adds
#      every missing registration without touching the pre-existing SubagentStop entry's own hook.
#   3. Re-running settings-merge is idempotent: the command count for worker-event-emit.sh does not
#      grow on a second run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout: scaffold.sh + templates/ at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# == 1. Fresh scaffold wires worker-event-emit.sh on all three events ===========================
W1="$ROOT/ws1"; mkdir -p "$W1"
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W1.wt" --component settings --yes >/tmp/scaf-we-w1.log 2>&1
rc=$?
assert_eq "$rc" "0" "1. fresh --component settings exits 0"
assert_eq "$([ -f "$W1/.claude/settings.json" ] && jq -e . "$W1/.claude/settings.json" >/dev/null 2>&1 && echo yes || echo no)" "yes" \
  "1. fresh settings.json is valid JSON"
fresh="$(cat "$W1/.claude/settings.json")"
assert_contains "$fresh" '"SubagentStart"' "1. fresh settings.json declares a SubagentStart event"
start_cmd="$(jq -r '.hooks.SubagentStart[0].hooks[0].command' "$W1/.claude/settings.json")"
assert_contains "$start_cmd" "worker-event-emit.sh" "1. SubagentStart runs worker-event-emit.sh"
pretool_cmds="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="*") | .hooks[].command' "$W1/.claude/settings.json")"
assert_contains "$pretool_cmds" "worker-event-emit.sh" "1. the PreToolUse * matcher also carries worker-event-emit.sh"
assert_contains "$pretool_cmds" "agent-watchdog-guard.sh" "1. and still carries agent-watchdog-guard.sh alongside it"
stop_cmds="$(jq -r '.hooks.SubagentStop[] | select(.matcher=="*") | .hooks[].command' "$W1/.claude/settings.json")"
assert_contains "$stop_cmds" "worker-event-emit.sh" "1. the SubagentStop * matcher carries worker-event-emit.sh"
assert_contains "$stop_cmds" "agent-progress-guard.sh" "1. and still carries agent-progress-guard.sh alongside it"

# == 2. settings-merge onto a pre-fix settings.json (SubagentStop wired, nothing else) ==========
W2="$ROOT/ws2"; mkdir -p "$W2/.claude"
cat > "$W2/.claude/settings.json" <<EOF
{ "hooks": { "SubagentStop": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $W2/scripts/agent-progress-guard.sh 2>/dev/null || true", "timeout": 15 }
] } ] } }
EOF
bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W2.wt" --component settings-merge >/tmp/scaf-we-w2.log 2>&1
rc=$?
assert_eq "$rc" "0" "2. settings-merge onto a pre-fix settings.json exits 0"
merged="$(cat "$W2/.claude/settings.json")"
assert_contains "$merged" '"SubagentStart"' "2. settings-merge adds the missing SubagentStart event"
assert_contains "$merged" "worker-event-emit.sh" "2. and wires worker-event-emit.sh somewhere"
# The pre-existing SubagentStop matcher block's OWN hook is untouched: a fresh matcher block for
# the newly-missing hook is appended alongside it, never rewritten in place (never delete or
# re-order an existing entry).
orig_still_there="$(jq -r '[.hooks.SubagentStop[].hooks[].command] | map(select(contains("agent-progress-guard.sh"))) | length' "$W2/.claude/settings.json")"
assert_eq "$orig_still_there" "1" "2. the pre-existing SubagentStop -> agent-progress-guard.sh entry survives untouched"

# == 3. re-running settings-merge is idempotent: no growth in worker-event-emit.sh mentions =====
n1=$(grep -c 'worker-event-emit\.sh' "$W2/.claude/settings.json")
bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W2.wt" --component settings-merge >>/tmp/scaf-we-w2.log 2>&1
merged2="$(cat "$W2/.claude/settings.json")"
n2=$(grep -c 'worker-event-emit\.sh' <<<"$merged2")
assert_eq "$n1" "$n2" "3. re-running settings-merge does not add any more worker-event-emit.sh registrations"
assert_eq "$(jq -r '.hooks.SubagentStart | length' "$W2/.claude/settings.json")" "1" \
  "3. exactly one SubagentStart matcher block after two merges"

assert_done
