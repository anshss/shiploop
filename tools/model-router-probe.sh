#!/usr/bin/env bash
# model-router-probe.sh: prove the model router against the REAL Claude Code engine, with no model.
#
# The plugin's test kit and the suite's Node stub both fire agent.spawn with a stand-in `$`. This
# probe instead runs a real `claude -p` session with the router mod loaded and points it at a
# loopback stand-in for a model endpoint (tools/model-router-probe-server.mjs), which records the
# model every request carried on the wire. The stub answers the session with one Agent tool call,
# so a subagent really spawns, and the model its FIRST request carried is what the router chose.
# Nothing leaves the machine: the base URL is 127.0.0.1, the auth token and the launcher's alias
# map are removed from the environment, and a private config dir keeps user settings out of it.
#
# It exists because the engine's event shape is not fully written down: the type of an agent a
# plugin provides arrives namespaced ("<plugin>:<type>"), which neither stand-in could show.
#
# Usage:
#   tools/model-router-probe.sh [--profile <family>] [--role <lookup|worker|worker-retry|investigator>]
#                              [--session-model <id>] [--keep]
#
#   --profile <family>   route through templates/lib/model-profiles/<family>.conf (default glm);
#                        `--profile -` runs the control: no profile, the definition's model applies.
#   --role <type>        the agent type to spawn (default lookup).
#   --session-model <id> what --model gets (default: the profile's SESSION_MODEL, else glm-5.4[1m]).
#   --keep               leave the scratch directory behind for inspection.
#
# Prints the wire model of every request, the subagent's transcript model, and a PASS/FAIL line.
# Under a profile PASS means the subagent's first request carried the profile's model for the role
# (the `[1m]` context suffix is the CLI's own marker and is dropped on the wire, so it is dropped
# on both sides before comparing). The control run has nothing to prove and reports only.
# Exit 0 on PASS or on a completed control, 1 on FAIL, 2 when the claude CLI or node is missing.
set -uo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE=glm
ROLE=lookup
SESSION_MODEL=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#--profile=}"; shift ;;
    --role) ROLE="$2"; shift 2 ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    --session-model) SESSION_MODEL="$2"; shift 2 ;;
    --session-model=*) SESSION_MODEL="${1#--session-model=}"; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v claude >/dev/null 2>&1 || { echo "model-router-probe: the claude CLI is not on PATH" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "model-router-probe: node is required for the loopback stand-in" >&2; exit 2; }
[ -f "$HUB/hooks/model-router.js" ] && [ -f "$HUB/hooks/hooks.json" ] || { echo "model-router-probe: run from a hub checkout" >&2; exit 2; }
[ -f "$HUB/templates/.claude/agents/$ROLE.md" ] || { echo "model-router-probe: no agent definition for role '$ROLE'" >&2; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/model-router-probe.XXXXXXXX")"
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  [ "$KEEP" -eq 1 ] && { echo "model-router-probe: scratch kept at $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# ── the scratch plugin: the real router mod, one agent definition, one profile ─────────────────
# A plugin loaded with --plugin-dir must be a directory of its own, so the mod is copied byte for
# byte rather than linked. The agent definition sits in the plugin's default agents/ directory,
# which makes its spawn type "<plugin>:<type>": the namespaced form a plugin-provided role has.
PLUGIN="$SCRATCH/plugin"
mkdir -p "$PLUGIN/.claude-plugin" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/templates/lib/model-profiles" \
         "$SCRATCH/ws" "$SCRATCH/config" "$SCRATCH/home"
printf '{"name":"shiploop-probe","version":"0.0.0","description":"loopback probe of the shiploop model router"}\n' > "$PLUGIN/.claude-plugin/plugin.json"
cp "$HUB/hooks/hooks.json" "$PLUGIN/hooks/hooks.json"
cp "$HUB/hooks/model-router.js" "$PLUGIN/hooks/model-router.js"
cp "$HUB/templates/.claude/agents/$ROLE.md" "$PLUGIN/agents/$ROLE.md"
if [ "$PROFILE" != "-" ]; then
  [ -f "$HUB/templates/lib/model-profiles/$PROFILE.conf" ] || { echo "model-router-probe: no profile '$PROFILE' under templates/lib/model-profiles/" >&2; exit 2; }
  cp "$HUB/templates/lib/model-profiles/$PROFILE.conf" "$PLUGIN/templates/lib/model-profiles/$PROFILE.conf"
fi
# The marker tells the stand-in which requests are the subagent's: the first line of its definition.
MARKER="$(awk 'BEGIN { fm = 0 } /^---$/ { fm++; next } fm >= 2 && NF { print; exit }' "$PLUGIN/agents/$ROLE.md")"
[ -n "$MARKER" ] || { echo "model-router-probe: the $ROLE definition has no body to mark its requests by" >&2; exit 2; }
[ -n "$SESSION_MODEL" ] || SESSION_MODEL="glm-5.4[1m]"
[ "$PROFILE" = "-" ] || SESSION_MODEL="$(sed -n -E 's/^SESSION_MODEL="?([^"]*)"?$/\1/p' "$PLUGIN/templates/lib/model-profiles/$PROFILE.conf")"
EXPECTED=""
[ "$PROFILE" = "-" ] || EXPECTED="$(sed -n -E "s/^ROLE_${ROLE//-/_}=\"?([^\"]*)\"?\$/\1/p" "$PLUGIN/templates/lib/model-profiles/$PROFILE.conf")"
[ -n "$EXPECTED" ] || [ "$PROFILE" = "-" ] || { echo "model-router-probe: the $PROFILE profile holds no model for the role $ROLE" >&2; exit 2; }

# ── the stand-in ───────────────────────────────────────────────────────────────────────────────
LOG="$SCRATCH/wire.jsonl"; : > "$LOG"
PROBE_SPAWN_TYPE="shiploop-probe:$ROLE" node "$HUB/tools/model-router-probe-server.mjs" 0 "$LOG" "$MARKER" \
  > "$SCRATCH/port" 2>"$SCRATCH/server.err" &
SERVER_PID=$!
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$SCRATCH/port" ] && break; sleep 0.3; done
PORT="$(cat "$SCRATCH/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "model-router-probe: the loopback stand-in did not start: $(cat "$SCRATCH/server.err")" >&2; exit 2; }

# ── the session ───────────────────────────────────────────────────────────────────────────────
PROFILE_ENV=()
[ "$PROFILE" = "-" ] || PROFILE_ENV=(SHIPLOOP_MODEL_PROFILE="$PROFILE")
( cd "$SCRATCH/ws" && git init -q 2>/dev/null
  env -u SHIPLOOP_MODEL_PROFILE -u ANTHROPIC_AUTH_TOKEN \
      -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
      -u ANTHROPIC_MODEL -u CLAUDE_CODE_SESSION_ID \
      HOME="$SCRATCH/home" CLAUDE_CONFIG_DIR="$SCRATCH/config" \
      CLAUDE_CODE_ENABLE_TELEMETRY=0 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY="sk-ant-loopback-probe" \
      "${PROFILE_ENV[@]+${PROFILE_ENV[@]}}" \
      perl -e 'alarm shift; exec @ARGV' 120 \
      command claude -p "Use the Agent tool to spawn the named subagent to answer: what is the value of X? Then report its answer in one line." \
        --model "$SESSION_MODEL" --plugin-dir "$PLUGIN" --permission-mode bypassPermissions \
        --strict-mcp-config --max-turns 4 --output-format json < /dev/null > "$SCRATCH/run.out" 2> "$SCRATCH/run.err" )
RC=$?
[ "$RC" -eq 0 ] || echo "model-router-probe: claude exited $RC: $(tail -3 "$SCRATCH/run.err" | tr '\n' ' ')"

# ── what went on the wire ─────────────────────────────────────────────────────────────────────
printf 'session model: %s   profile: %s   spawn type: shiploop-probe:%s\n' "$SESSION_MODEL" "$PROFILE" "$ROLE"
node --input-type=module - "$LOG" <<'EOF'
import fs from 'node:fs'
for (const line of fs.readFileSync(process.argv[2], 'utf8').split('\n')) {
  if (!line) continue
  const r = JSON.parse(line)
  console.log(`  request ${String(r.n).padStart(2)}  model=${r.model}  ${r.subagent ? '<- the spawned subagent' : ''}`)
}
EOF
TRANSCRIPT="$(find "$SCRATCH/config/projects" -name 'agent-*.jsonl' 2>/dev/null | head -1)"
if [ -n "$TRANSCRIPT" ]; then
  printf 'subagent transcript: %s\n' "$(jq -r 'select(.type == "assistant") | "message.model=\(.message.model) requestedModel=\(.requestedModel)"' "$TRANSCRIPT" 2>/dev/null | head -1)"
else
  echo "subagent transcript: none (no subagent spawned)"
fi
WIRE="$(jq -r 'select(.subagent) | .model' "$LOG" 2>/dev/null | head -1)"
strip() { printf '%s' "${1%%\[*}"; }
if [ "$PROFILE" = "-" ]; then
  echo "RESULT: control run, nothing to prove (the subagent ran on its definition's model)"
  exit 0
fi
if [ -n "$WIRE" ] && [ "$(strip "$WIRE")" = "$(strip "$EXPECTED")" ]; then
  echo "RESULT: PASS (the subagent's request carried the profile's model for $ROLE)"
  exit 0
fi
echo "RESULT: FAIL (expected the $ROLE request to carry '$EXPECTED', the wire carried '${WIRE:-nothing}')"
exit 1
