#!/usr/bin/env bash
# The statusline segment's idle marker: the oldest live worker whose own transcript (found through
# the statusline JSON's transcript_path) has not been written for GOVERN_STATUSLINE_IDLE_S gets
# " · idle <duration>" appended. A recently written transcript, a missing transcript, and
# GOVERN_STATUSLINE_IDLE_S=0 all print no marker (negative controls).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

SEG="$DIR/../statusline-segment.sh"
[[ -f "$SEG" ]] || { echo "SKIP: statusline-segment.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
WS="$T/ws"; mkdir -p "$WS/governor"
EV="$WS/governor/events.jsonl"
TS="$(date +%s)"
printf '{"ts":%s,"run_id":"r1","type":"run_started","mode":"live","target":"x","parallel":1}\n' "$((TS-900))" > "$EV"
printf '{"ts":%s,"run_id":"r1","type":"worker_spawned","agent_id":"aw1","agent_type":"worker"}\n' "$((TS-800))" >> "$EV"

SESSION="$T/sess.jsonl"; : > "$SESSION"
mkdir -p "$T/sess/subagents"
WT="$T/sess/subagents/agent-aw1.jsonl"; printf '{}\n' > "$WT"
touch_ago() { # <file> <seconds>
  local when; when="$(date -d "@$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S)"
  touch -t "$when" "$1"
}
seg() { # <transcript_path> [env...]
  local tp="$1"; shift
  printf '{"cwd":"%s","transcript_path":"%s"}' "$WS" "$tp" | env -u GOVERN_EVENTS_FILE "$@" bash "$SEG" 2>/dev/null
}

touch_ago "$WT" 700
assert_contains "$(seg "$SESSION")" "idle 11m" "a transcript untouched for 700s shows the idle marker"
touch_ago "$WT" 20
assert_not_contains "$(seg "$SESSION")" "idle" "a recently written transcript shows no marker (negative control)"
touch_ago "$WT" 700
assert_not_contains "$(seg "$SESSION" GOVERN_STATUSLINE_IDLE_S=0)" "idle" "GOVERN_STATUSLINE_IDLE_S=0 turns the marker off"
assert_not_contains "$(seg "$T/nope.jsonl")" "idle" "no transcript at the given path: no marker"
assert_contains "$(seg "$SESSION")" "1/1" "the base segment is unchanged"

assert_done
