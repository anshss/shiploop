#!/usr/bin/env bash
# measure-prefix.sh — attribute a REAL govern worker spawn's request payload to its components.
#
# Why direct capture and not differential ablation: `count_tokens` cannot see what Claude Code
# assembles, and turn-1 `cache_creation_input_tokens` collapses the whole prefix into ONE number, so
# attributing it means re-spawning once per component and diffing — N spawns, N sources of noise. At
# the API boundary the assembled body is already componentised (`tools` / `system` / `messages`), so
# one spawn through a local pass-through proxy reads the split directly.
#
# Fidelity is the point. The prompt comes from spawn-worker.sh's own assembly
# (GOVERN_SPAWN_PRINT_PROMPT) and the flags from its own resolver (GOVERN_SPAWN_DRY_RUN), so this
# measures the spawn the fleet actually runs — not a hand-rolled probe whose flag set drifts.
#
# Credentials: the proxy forwards every header verbatim and logs only sizes/names — never a header
# value, never body content. Subscription/OAuth auth survives it (this is NOT the `--bare` blocker,
# which forces ANTHROPIC_API_KEY).
#
# Usage:
#   scripts/govern/measure-prefix.sh <ticket-number> [--out <dir>] [--keep-log]
#
# Emits the markdown component table on stdout and writes the raw capture + table under --out
# (default: logs/measure-prefix/<ticket>-<timestamp>/).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

N="${1:-}"
[[ -n "$N" ]] || { echo "usage: measure-prefix.sh <ticket-number> [--out <dir>] [--keep-log]" >&2; exit 2; }
shift

OUT_DIR=""
KEEP_LOG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --keep-log) KEEP_LOG=1; shift ;;
    *) echo "measure-prefix.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "measure-prefix.sh: node is required" >&2; exit 2; }

STAMP="$(date -u '+%Y%m%d-%H%M%S')"
OUT_DIR="${OUT_DIR:-$WS_ROOT/logs/measure-prefix/$N-$STAMP}"
mkdir -p "$OUT_DIR"
CAPTURE_LOG="$OUT_DIR/capture.jsonl"
PROXY_ERR="$OUT_DIR/proxy.stderr"
WORKER_JSONL="$OUT_DIR/worker.jsonl"

# 1. Resolve the REAL spawn parameters from spawn-worker.sh's own seams — never re-derive them here.
flags_json="$(GOVERN_SPAWN_DRY_RUN=1 "$DIR/spawn-worker.sh" "$N")"
model="$(printf '%s' "$flags_json" | jq -r '.model')"
effort="$(printf '%s' "$flags_json" | jq -r '.effort // ""')"
perm="$(printf '%s' "$flags_json" | jq -r '.permission_mode')"
strict_mcp="$(printf '%s' "$flags_json" | jq -r '.strict_mcp')"
exclude_dyn="$(printf '%s' "$flags_json" | jq -r '.exclude_dynamic_prompt')"
tools_flag="$(printf '%s' "$flags_json" | jq -r '.tools // ""')"
wtpath="$(printf '%s' "$flags_json" | jq -r '.worktree')"
claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
[[ -d "$wtpath" ]] || wtpath="$WS_ROOT"   # worktree not allocated yet → measure from the workspace root

prompt="$(GOVERN_SPAWN_PRINT_PROMPT=1 "$DIR/spawn-worker.sh" "$N")"
# Stop the worker after one turn. This is the ONLY deviation from a production spawn: it appends to
# the tail of the user message, so `tools` and `system` — the components under measurement — are
# untouched, and `messages` grows by exactly the bytes of this block.
prompt="$prompt

## ⚠ OVERRIDE — MEASUREMENT PROBE (supersedes every instruction above)
Do NOT work this ticket. Do NOT use any tool. Reply with the single word OK and stop."

# 2. Bring up the capture proxy on an ephemeral port and block until it is listening.
node "$DIR/lib/capture-proxy.mjs" --port 0 --log "$CAPTURE_LOG" 2>"$PROXY_ERR" &
proxy_pid=$!
cleanup() { kill "$proxy_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

port=""
for _ in $(seq 1 100); do
  port="$(awk '/^listening /{print $2; exit}' "$PROXY_ERR" 2>/dev/null || true)"
  [[ -n "$port" ]] && break
  kill -0 "$proxy_pid" 2>/dev/null || { echo "measure-prefix.sh: proxy died — see $PROXY_ERR" >&2; exit 1; }
  sleep 0.1
done
[[ -n "$port" ]] || { echo "measure-prefix.sh: proxy never reported a port — see $PROXY_ERR" >&2; exit 1; }

# 3. Run the spawn. Same command line as spawn-worker.sh's live invocation (see its `claude -p`
# block), with ANTHROPIC_BASE_URL pointed at the proxy. Unquoted flag vars are intentional: each is
# either empty or a single literal flag, exactly as the live spawn expands them.
effort_flag=""; [[ -n "$effort" && "$effort" != "null" ]] && effort_flag="--effort $effort"
disable_slash_cmds="--disable-slash-commands"
[[ "${GOVERN_WORKER_SLASH_COMMANDS:-0}" == "1" ]] && disable_slash_cmds=""
set +e
( cd "$wtpath" && exec env \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" "$claude_bin" -p "$prompt" \
    --output-format stream-json --verbose \
    --setting-sources "${GOVERN_SETTING_SOURCES:-project,local}" \
    $strict_mcp $disable_slash_cmds $exclude_dyn $tools_flag \
    --permission-mode "$perm" --model "$model" $effort_flag ) >"$WORKER_JSONL" 2>&1
rc=$?
set -e

cleanup; trap - EXIT INT TERM
# The proxy flushes its log on SIGTERM; give it a moment before reading.
for _ in $(seq 1 30); do [[ -s "$CAPTURE_LOG" ]] && break; sleep 0.1; done

if [[ ! -s "$CAPTURE_LOG" ]]; then
  echo "measure-prefix.sh: no requests captured (worker rc=$rc) — see $WORKER_JSONL and $PROXY_ERR" >&2
  exit 1
fi

# 4. Report.
node "$DIR/lib/capture-report.mjs" "$CAPTURE_LOG" | tee "$OUT_DIR/table.md"
node "$DIR/lib/capture-report.mjs" "$CAPTURE_LOG" --json > "$OUT_DIR/summary.json"
echo >&2
echo "measure-prefix: worker rc=$rc · artifacts in $OUT_DIR" >&2
[[ "$KEEP_LOG" == "1" ]] || rm -f "$PROXY_ERR"
