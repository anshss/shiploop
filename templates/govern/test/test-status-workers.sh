#!/usr/bin/env bash
# status.sh's live-worker section, read from subagent transcripts:
#
#   1. a worker that started a background task and stopped is listed PARKED, with the pending task id.
#   2. a worker that finished (nothing pending) is listed without a waiting line (negative control).
#   3. the pending-task lookup prefers govern::pending_bg_tasks_for when common.sh defines it
#      (a stub proves the call), and falls back to govern::pending_bg_tasks when it does not.
#   4. a gate log the transcript names shows its tail.
#   5. GOVERN_STATUS_WORKERS=0 prints nothing; a transcript idle past GOVERN_WORKER_STALE_S is hidden.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

ST="$DIR/../status.sh"
[[ -f "$ST" ]] || { echo "SKIP: status.sh not found"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin/lib" "$T/governor" "$T/sub"
cp "$ST" "$T/bin/status.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"
# Variant with a stubbed per-agent lookup, and a variant with the per-agent lookup removed, so both
# branches of the status call run whatever the real common.sh defines.
mkdir -p "$T/stub/lib" "$T/fall/lib"
cp "$T/bin/status.sh" "$T/stub/status.sh"; cp "$T/bin/status.sh" "$T/fall/status.sh"
cp "$T/bin/lib/"* "$T/stub/lib/"; cp "$T/bin/lib/"* "$T/fall/lib/"
printf '\ngovern::pending_bg_tasks_for() { printf "stub-%%s" "$1"; }\n' >> "$T/stub/lib/common.sh"
printf '\nunset -f govern::pending_bg_tasks_for 2>/dev/null || true\n' >> "$T/fall/lib/common.sh"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
NOW="$(date +%s)"
line() { # <type> <age-seconds> <content-json>
  printf '{"type":"%s","timestamp":"%s","message":{"role":"%s","content":%s}}\n' "$1" "$(iso $((NOW - $2)))" "$1" "$3"
}
GATELOG="$T/gate.log"
printf 'one\ntwo\nlast gate line\n' > "$GATELOG"

{
  line user 600 '"Resolve #31."'
  line assistant 500 '[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"run > '"$GATELOG"'"}}]'
  line user 480 '[{"type":"tool_result","tool_use_id":"t1","content":"Command did not complete within its timeout and was moved to the background (ID: bx1). Output is being written to /tmp/x.output"}]'
  line assistant 470 '[{"type":"text","text":"Waiting for it."}]'
} > "$T/sub/agent-a31.jsonl"
printf '{"name":"worker-31","model":"sonnet"}' > "$T/sub/agent-a31.meta.json"
{
  line user 300 '"Resolve #32."'
  line assistant 250 '[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]'
  line user 240 '[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]'
  line assistant 200 '[{"type":"text","text":"done"}]'
} > "$T/sub/agent-a32.jsonl"
printf '{"name":"worker-32","model":"opus"}' > "$T/sub/agent-a32.meta.json"
{
  line user 9000 '"old"'
  line assistant 8900 '[{"type":"text","text":"old"}]'
} > "$T/sub/agent-a33.jsonl"
printf '{"name":"worker-33","model":"haiku"}' > "$T/sub/agent-a33.meta.json"

run_st() { # <variant dir> [env...]
  local d="$1"; shift
  ( cd "$T" && env GOVERN_STATUS_SUBAGENTS_DIR="$T/sub" GOVERN_STATUS_PR=0 "$@" bash "$d/status.sh" --no-reap 2>&1 )
}

out="$(run_st "$T/fall")"
assert_contains "$out" "workers (this session):" "1. the section header is printed"
assert_contains "$out" "worker-31" "1. the parked worker is listed"
assert_contains "$out" "PARKED" "1. a worker with a pending background task is PARKED"
assert_contains "$out" "waiting on background task(s): bx1" "1. fallback lookup names the pending task"
assert_contains "$out" "worker-32" "2. the finished worker is listed"
parked_block="$(printf '%s\n' "$out" | awk '/^  worker-/{f = ($1 == "worker-32")} f')"
assert_not_contains "$parked_block" "waiting on background" "2. the finished worker has no waiting line (negative control)"
assert_contains "$out" "last gate line" "4. the gate log the transcript names shows its tail"
assert_not_contains "$out" "worker-33" "5. a transcript idle past the stale bound is hidden"

out="$(run_st "$T/stub")"
assert_contains "$out" "waiting on background task(s): stub-a31" "3. the per-agent lookup is used when defined, with the agent id"

out="$(run_st "$T/fall" GOVERN_STATUS_WORKERS=0)"
assert_not_contains "$out" "worker-31" "5. GOVERN_STATUS_WORKERS=0 prints no worker section"

assert_done
