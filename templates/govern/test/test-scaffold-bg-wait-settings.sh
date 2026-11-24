#!/usr/bin/env bash
# The settings the background-task wait depends on:
#   1. a fresh --component settings writes the three env keys (BASH_DEFAULT_TIMEOUT_MS=1800000,
#      BASH_MAX_TIMEOUT_MS=3600000, GOVERN_BG_WAIT_GUARD=1), wires bg-task-ledger.sh on PostToolUse
#      (Bash|Monitor) and worker-report-capture.sh on SubagentStop, and gives agent-progress-guard.sh
#      a 1800s timeout on SubagentStop and TeammateIdle only;
#   2. --component settings-merge into an existing file adds the missing env keys and NEVER
#      clobbers a key already set, wires the two new hooks, and raises the guard's 15s timeout;
#   3. a second merge changes nothing.
# Asserts on the hub's scaffold.sh, so it runs only from a hub checkout (tools/hub-context-tests.txt).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 77; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
scaf() { # <ws> <component> [--yes]
  bash "$HUB/scaffold.sh" --workspace-dir "$1" --templates "$HUB/templates" \
    --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
    --worktree-base "$1.wt" --component "$2" ${3:-} >"$ROOT/scaf.log" 2>&1
}

# ── 1. fresh ──
W1="$ROOT/ws1"; mkdir -p "$W1"
scaf "$W1" settings --yes; assert_eq "$?" "0" "1. fresh --component settings exits 0"
S1="$W1/.claude/settings.json"
assert_eq "$(jq -r '[.env.BASH_DEFAULT_TIMEOUT_MS, .env.BASH_MAX_TIMEOUT_MS, .env.GOVERN_BG_WAIT_GUARD] | join(",")' "$S1")" \
  "1800000,3600000,1" "1. the three env keys are written"
assert_eq "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Bash|Monitor") | .hooks[].command' "$S1")" \
  "bash $W1/scripts/bg-task-ledger.sh 2>/dev/null || true" "1. the ledger hook is wired on PostToolUse Bash|Monitor"
assert_contains "$(jq -r '[.hooks.SubagentStop[].hooks[].command] | join("\n")' "$S1")" "worker-report-capture.sh" \
  "1. the report capture is wired on SubagentStop"
assert_eq "$(jq -r '[.hooks.SubagentStop[].hooks[], .hooks.TeammateIdle[].hooks[] | select(.command | test("agent-progress-guard")) | .timeout] | join(",")' "$S1")" \
  "1800,1800" "1. the guard holds up to 1800s on SubagentStop and TeammateIdle"
assert_eq "$(jq -r '[.hooks[][].hooks[] | select(.timeout == 1800)] | length' "$S1")" "2" \
  "1. no other hook gets the long timeout"

# ── 2. merge into an existing file ──
W2="$ROOT/ws2"; mkdir -p "$W2/.claude"
cat > "$W2/.claude/settings.json" <<EOF
{ "env": { "BASH_DEFAULT_TIMEOUT_MS": "600000", "MY_OWN": "keep" },
  "hooks": { "SubagentStop": [ { "matcher": "*", "hooks": [
    { "type": "command", "command": "bash $W2/scripts/agent-progress-guard.sh 2>/dev/null || true", "timeout": 15 }
  ] } ] } }
EOF
scaf "$W2" settings-merge; assert_eq "$?" "0" "2. settings-merge exits 0"
S2="$W2/.claude/settings.json"
assert_eq "$(jq -r '.env.BASH_DEFAULT_TIMEOUT_MS' "$S2")" "600000" "2. an env key the operator set is not clobbered"
assert_eq "$(jq -r '.env.MY_OWN' "$S2")" "keep" "2. an unrelated env key survives"
assert_eq "$(jq -r '[.env.BASH_MAX_TIMEOUT_MS, .env.GOVERN_BG_WAIT_GUARD] | join(",")' "$S2")" "3600000,1" \
  "2. the missing env keys are added"
assert_eq "$(jq -r '[.hooks.SubagentStop[].hooks[] | select(.command | test("agent-progress-guard")) | .timeout] | join(",")' "$S2")" \
  "1800" "2. the existing guard's 15s timeout is raised to 1800"
assert_contains "$(jq -r '[.hooks.PostToolUse[]?.hooks[].command] | join("\n")' "$S2")" "bg-task-ledger.sh" "2. the ledger hook is added"
assert_contains "$(jq -r '[.hooks.SubagentStop[].hooks[].command] | join("\n")' "$S2")" "worker-report-capture.sh" \
  "2. the report capture is added"

# ── 3. idempotent ──
before="$(cat "$S2")"
scaf "$W2" settings-merge
assert_eq "$(cat "$S2")" "$before" "3. a second merge changes nothing"

assert_done
