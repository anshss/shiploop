#!/usr/bin/env bash
# Work item 8: neither status.sh nor statusline-segment.sh may present FOREVER-STALE governor state
# as current. events.jsonl's only writers are the dispatch path; a crashed driver never writes
# run_done, so without a staleness guard status.sh's "running ... up 30d" line never expires, and a
# statusline's `kill -0` liveness check can't tell a genuinely-live pid from one REUSED long after
# the worker that originally held it died.
#
# Contract:
#   1. status.sh: an old, never-finished run renders an explicit "no recent dispatch activity" state
#      (not "running ... up Nd") once the log's newest event exceeds GOVERN_EVENTS_STALE_DAYS.
#   2. status.sh --json: carries staleLog:true instead of the normal active/counts shape.
#   3. status.sh: GOVERN_EVENTS_STALE_CHECK=0 restores the old (forever-stale) behavior.
#   4. status.sh: a RECENT log (within the window) is completely unaffected.
#   5. statusline-segment.sh: a claimed-live pid whose OWN spawn event is older than
#      GOVERN_EVENTS_STALE_DAYS is treated as dead (segment stays silent, its own contract),
#      even though `kill -0` on the pid still succeeds (simulating pid reuse).
#   6. statusline-segment.sh: GOVERN_STATUSLINE_STALE_CHECK=0 restores the old behavior (reports the
#      stale claim as live).
#   7. statusline-segment.sh: a RECENT log is completely unaffected.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

STATUS="$DIR/../status.sh"
SEG="$DIR/../statusline-segment.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
EV="$T/governor/events.jsonl"

NOW_TS="$(date +%s)"
TS_OLD=$(( NOW_TS - (10 * 86400) ))   # 10 days ago: over the default 7-day window
TS_RECENT=$(( NOW_TS - 600 ))          # 10 minutes ago: well inside the window

sleep 60 & OLD_PID=$!
trap 'kill "$OLD_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"' EXIT

run_status() { GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" "$@" bash "$STATUS" --no-reap 2>&1; }

# ── 1/2/3. status.sh: an old, never-finished run ─────────────────────────────────────────────────
: > "$EV"
printf '{"ts":%s,"run_id":"r-old","type":"run_started","mode":"live","target":"backlog","parallel":2}\n' "$TS_OLD" >> "$EV"
printf '{"ts":%s,"run_id":"r-old","type":"worker_spawned","ticket":5,"model":"sonnet","effort":"medium","pid":%s}\n' "$((TS_OLD+10))" "$OLD_PID" >> "$EV"

out="$(run_status)"
assert_contains "$out" "no recent dispatch activity" "1. status: old never-finished run reads as no recent activity"
assert_not_contains "$out" "(running" "1. status: never claims the stale run's state is 'running'"

js="$(GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" bash "$STATUS" --json --no-reap 2>&1)"
if command -v jq >/dev/null 2>&1; then
  assert_eq "$(printf '%s' "$js" | jq -r '.staleLog')" "true" "2. status --json: staleLog is true"
  assert_eq "$(printf '%s' "$js" | jq -r '.active | length')" "0" "2. status --json: active is empty on a stale log"
fi

out_off="$(GOVERN_EVENTS_STALE_CHECK=0 run_status)"
assert_contains "$out_off" "running" "3. kill switch GOVERN_EVENTS_STALE_CHECK=0 restores the old 'running' text"
assert_not_contains "$out_off" "no recent dispatch activity" "3. kill switch: no staleness framing"

# ── 4. status.sh: a RECENT log is unaffected ─────────────────────────────────────────────────────
: > "$EV"
printf '{"ts":%s,"run_id":"r-new","type":"run_started","mode":"live","target":"backlog","parallel":2}\n' "$TS_RECENT" >> "$EV"
printf '{"ts":%s,"run_id":"r-new","type":"worker_spawned","ticket":6,"model":"sonnet","effort":"medium","pid":%s}\n' "$((TS_RECENT+5))" "$OLD_PID" >> "$EV"
out_recent="$(run_status)"
assert_contains "$out_recent" "1 active" "4. status: a recent log still reports the live worker normally"
assert_not_contains "$out_recent" "no recent dispatch activity" "4. status: a recent log never renders the stale framing"

# ── 5/6/7. statusline-segment.sh ─────────────────────────────────────────────────────────────────
WS="$T/segws"; DEEP="$WS/backend/src"; mkdir -p "$DEEP" "$WS/governor"
EV2="$WS/governor/events.jsonl"
seg() { printf '{"cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"x"}}' "$1" "$1" "$WS" \
  | env -u GOVERN_EVENTS_FILE "${@:2}" bash "$SEG" 2>/dev/null; }

printf '{"ts":%s,"run_id":"r-old","type":"worker_spawned","ticket":77,"model":"sonnet","effort":"medium","pid":%s}\n' "$TS_OLD" "$OLD_PID" > "$EV2"
out_seg="$(seg "$DEEP")"
assert_eq "$out_seg" "" "5. segment: a claimed-live pid whose spawn event is 10d old is treated as dead (silent)"

out_seg_off="$(seg "$DEEP" GOVERN_STATUSLINE_STALE_CHECK=0)"
assert_contains "$out_seg_off" "#77" "6. kill switch GOVERN_STATUSLINE_STALE_CHECK=0 reports the stale claim as live"

printf '{"ts":%s,"run_id":"r-new","type":"worker_spawned","ticket":88,"model":"sonnet","effort":"medium","pid":%s}\n' "$TS_RECENT" "$OLD_PID" > "$EV2"
out_seg_recent="$(seg "$DEEP")"
assert_contains "$out_seg_recent" "#88" "7. segment: a recent spawn is reported normally"

assert_done
