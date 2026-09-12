#!/usr/bin/env bash
# Regression for interactive-lane idle supervision actually being WIRED, not just
# reachable by agent-progress-guard.sh's own tests. The hook was taught to handle a
# `TeammateIdle` event, but nothing ever registered that event with the CLI — SubagentStop is the
# ONLY place either lane's supervision gets wired (test-worker-agent-doctrine.sh's own case 6i:
# "SubagentStop supervision is owned once, at settings.json"), so a TeammateIdle branch with no
# matching settings.json entry was dead code in production even though it was green in CI.
#
# Contract:
#   1. A FRESH scaffold's .claude/settings.json (--component settings) carries a TeammateIdle
#      entry pointing at agent-progress-guard.sh — the same hook SubagentStop already carries.
#   2. --component settings-merge into an EXISTING settings.json that predates this fix (has
#      SubagentStop wired, no TeammateIdle key at all) APPENDS the TeammateIdle stanza without
#      touching the pre-existing SubagentStop entry.
#   3. Re-running settings-merge is idempotent — no duplicate TeammateIdle stanza.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout — scaffold.sh + templates/ at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── 1. Fresh scaffold wires TeammateIdle alongside SubagentStop ────────────
W1="$ROOT/ws1"; mkdir -p "$W1"
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W1.wt" --component settings --yes >/tmp/scaf-ti-w1.log 2>&1
rc=$?
assert_eq "$rc" "0" "1. fresh --component settings exits 0"
fresh="$(cat "$W1/.claude/settings.json" 2>/dev/null)"
assert_contains "$fresh" '"TeammateIdle"' "1. fresh settings.json declares a TeammateIdle event"
teammate_cmd="$(jq -r '.hooks.TeammateIdle[0].hooks[0].command' "$W1/.claude/settings.json" 2>/dev/null)"
subagent_cmd="$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$W1/.claude/settings.json" 2>/dev/null)"
assert_contains "$teammate_cmd" "agent-progress-guard.sh" "1. TeammateIdle hook runs agent-progress-guard.sh"
assert_eq "$teammate_cmd" "$subagent_cmd" "1. TeammateIdle points at the SAME command as SubagentStop"

# ── 2. settings-merge onto a pre-fix settings.json (SubagentStop wired, no TeammateIdle) ──
W2="$ROOT/ws2"; mkdir -p "$W2/.claude"
cat > "$W2/.claude/settings.json" <<EOF
{ "hooks": { "SubagentStop": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $W2/scripts/agent-progress-guard.sh 2>/dev/null || true", "timeout": 15 }
] } ] } }
EOF
bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W2.wt" --component settings-merge >/tmp/scaf-ti-w2.log 2>&1
rc=$?
assert_eq "$rc" "0" "2. settings-merge onto a pre-fix settings.json exits 0"
merged="$(cat "$W2/.claude/settings.json")"
assert_contains "$merged" '"TeammateIdle"' "2. settings-merge adds the missing TeammateIdle event"
assert_eq "$(jq -r '.hooks.TeammateIdle[0].hooks[0].command' "$W2/.claude/settings.json")" \
  "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$W2/.claude/settings.json")" \
  "2. merged TeammateIdle hook matches the existing SubagentStop command"
assert_eq "$(jq -r '.hooks.SubagentStop | length' "$W2/.claude/settings.json")" "1" \
  "2. the pre-existing SubagentStop entry is untouched (still exactly one matcher block)"

# ── 3. re-running settings-merge is idempotent — no duplicate TeammateIdle stanza ──
bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W2.wt" --component settings-merge >>/tmp/scaf-ti-w2.log 2>&1
merged2="$(cat "$W2/.claude/settings.json")"
n1=$(grep -c 'TeammateIdle' <<<"$merged")
n2=$(grep -c 'TeammateIdle' <<<"$merged2")
assert_eq "$n1" "$n2" "3. re-running settings-merge does not duplicate the TeammateIdle stanza"
assert_eq "$(jq -r '.hooks.TeammateIdle | length' "$W2/.claude/settings.json")" "1" \
  "3. exactly one TeammateIdle matcher block after two merges"

assert_done
