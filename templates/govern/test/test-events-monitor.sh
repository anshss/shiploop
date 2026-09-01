#!/usr/bin/env bash
# The plugin Monitor (tools/fleet-monitor.sh) + its manifest (monitors/monitors.json).
#
# HUB-CONTEXT TEST. The monitor ships with the PLUGIN, not with a scaffolded workspace, so there is
# nothing to test inside `scaffold-and-test`'s throwaway workspace. It resolves the hub as
# $DIR/../../.. and exits 77 when that is not a hub checkout — and is therefore listed in
# tools/hub-context-tests.txt, where a 77 is a HARD failure. (Skipping without being listed is the
# documented trap where a test runs in no job at all.)
#
# Every line this monitor prints on stdout becomes a NOTIFICATION in the driver's context. shiploop's
# whole thesis is that that context is the scarce resource, so the contract is about what it does NOT
# print:
#   1. Absolutely silent with no event log — the state of nearly every session that ever runs it.
#   2. Never replays history: it attaches at the END of the log.
#   3. Transitions only — driver_spawned/driver_reaped plumbing is not surfaced.
#   4. Deduped: the same transition twice inside the dedupe window prints once.
#   5. Rate limited: a burst is capped per minute and the overflow collapses into one line.
#   6. GOVERN_MONITOR=0 exits immediately.
#   7. The manifest is valid JSON with the keys Claude Code requires, pointing at a real script.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/tools/fleet-monitor.sh" ] && [ -f "$HUB/monitors/monitors.json" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
MON="$HUB/tools/fleet-monitor.sh"

T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
WS="$T/ws"; mkdir -p "$WS/governor" "$WS/sub/deep"
EV="$WS/governor/events.jsonl"

ev() { printf '%s\n' "$1" >> "$EV"; }
TS="$(date +%s)"

# ── 7. the manifest ─────────────────────────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  jq -e . "$HUB/monitors/monitors.json" >/dev/null 2>&1
  assert_eq "$?" "0" "manifest: monitors.json is valid JSON"
  assert_eq "$(jq -r 'type' "$HUB/monitors/monitors.json")" "array" "manifest: monitors.json is an array of entries"
  assert_eq "$(jq -r '[.[] | select((.name|type)=="string" and (.command|type)=="string" and (.description|type)=="string")] | length' "$HUB/monitors/monitors.json")" \
    "$(jq -r 'length' "$HUB/monitors/monitors.json")" \
    "manifest: every entry has the required name/command/description strings"
  assert_contains "$(jq -r '.[0].command' "$HUB/monitors/monitors.json")" 'CLAUDE_PLUGIN_ROOT' \
    "manifest: the command is anchored on \${CLAUDE_PLUGIN_ROOT}, never a relative path"
  assert_contains "$(jq -r '.[0].command' "$HUB/monitors/monitors.json")" 'tools/fleet-monitor.sh' \
    "manifest: the command points at the monitor script that actually exists"
fi

# ── 6. kill switch ──────────────────────────────────────────────────────────────────────────────
# The CONTRIBUTING background+wait idiom, NOT `timeout`: coreutils' `timeout` is absent from a stock
# macOS (it is a homebrew binary there) while present on the Ubuntu runner — exactly the
# local-pass/CI-only-truth split the contributing guide warns about, in reverse.
GOVERN_MONITOR=0 bash "$MON" </dev/null >"$T/off.log" 2>&1 &
wait $!
rc=$?
assert_eq "$rc" "0" "monitor: GOVERN_MONITOR=0 exits immediately and cleanly"
assert_eq "$(wc -c < "$T/off.log" | tr -d ' ')" "0" "monitor: the kill switch prints nothing"

# ── 1. silent with no fleet ─────────────────────────────────────────────────────────────────────
# A directory with no governor/ anywhere above it. The monitor must poll quietly, not exit noisily.
NOWS="$T/nofleet"; mkdir -p "$NOWS"
( cd "$NOWS" && env -u GOVERN_EVENTS_FILE -u CLAUDE_PROJECT_DIR GOVERN_MONITOR_POLL_S=1 \
    bash "$MON" </dev/null >"$T/silent.log" 2>&1 ) & SILENT=$!
sleep 3
kill "$SILENT" 2>/dev/null; wait "$SILENT" 2>/dev/null
assert_eq "$(wc -c < "$T/silent.log" | tr -d ' ')" "0" \
  "monitor: prints absolutely nothing when there is no event log (the normal session)"

# ── 2. never replays history ────────────────────────────────────────────────────────────────────
ev "{\"ts\":$((TS-900)),\"run_id\":\"r0\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\",\"parallel\":2}"
ev "{\"ts\":$((TS-800)),\"run_id\":\"r0\",\"type\":\"worker_spawned\",\"ticket\":1,\"model\":\"sonnet\",\"pid\":1}"
ev "{\"ts\":$((TS-700)),\"run_id\":\"r0\",\"type\":\"worker_done\",\"ticket\":1,\"status\":\"resolved\",\"model\":\"sonnet\",\"elapsed\":100}"

LOG="$T/mon.log"
( cd "$WS/sub/deep" && env -u GOVERN_EVENTS_FILE -u CLAUDE_PROJECT_DIR \
    GOVERN_MONITOR_POLL_S=1 GOVERN_MONITOR_DEDUPE_S=120 GOVERN_MONITOR_MAX_PER_MIN=6 \
    bash "$MON" </dev/null >"$LOG" 2>&1 ) & MPID=$!
sleep 2
assert_eq "$(wc -c < "$LOG" | tr -d ' ')" "0" \
  "monitor: attaches at the END of the log — pre-existing events are never replayed"

# ── 3/4. transitions only, deduped ──────────────────────────────────────────────────────────────
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"driver_spawned\",\"label\":\"#94\",\"pid\":222,\"running\":1,\"cap\":4}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":94,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":333}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":94,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":334}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_escalated\",\"ticket\":94,\"from\":\"sonnet\",\"to\":\"opus\",\"reason\":\"budget\"}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_done\",\"ticket\":94,\"status\":\"resolved\",\"model\":\"opus\",\"elapsed\":812}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_done\",\"ticket\":95,\"status\":\"stale\",\"pid\":9,\"reapedBy\":\"status.sh\"}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"ticket_parked\",\"ticket\":96,\"note\":\"needs a human\"}"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"driver_reaped\",\"label\":\"#94\",\"pid\":222,\"tickets\":1,\"ok\":true}"
sleep 3

out="$(cat "$LOG")"
assert_contains "$out" "#94" "monitor: surfaces the worker_spawned transition"
assert_contains "$out" "opus" "monitor: surfaces the escalation"
assert_contains "$out" "resolved" "monitor: surfaces the completion"
assert_contains "$out" "PARKED" "monitor: surfaces a park, which is the one outcome needing a human"
assert_not_contains "$out" "driver" "monitor: driver fan-out plumbing is NOT surfaced"
assert_not_contains "$out" "#95" "monitor: a status.sh bookkeeping reap (status=stale) is not reported as a worker outcome"
assert_eq "$(grep -c 'worker started on #94' "$LOG" | tr -d ' ')" "1" \
  "monitor: the duplicate spawn of #94 is deduped to one line"

# ── 5. rate limit ───────────────────────────────────────────────────────────────────────────────
# 20 distinct transitions in a burst against a cap of 6/min. The window already holds ~4 lines from
# above, so the cap must bite well before 20 and the excess must collapse into ONE suppression line.
before="$(wc -l < "$LOG" | tr -d ' ')"
for i in $(seq 200 219); do
  ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":$i,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":$((1000+i))}"
done
sleep 3
after="$(wc -l < "$LOG" | tr -d ' ')"
printed=$((after - before))
assert_eq "$([[ "$printed" -lt 20 ]] && echo capped || echo flooded)" "capped" \
  "monitor: a 20-event burst does NOT produce 20 notifications (rate limit bites)"
assert_eq "$([[ "$printed" -le 6 ]] && echo within || echo over)" "within" \
  "monitor: the burst stays within the ${GOVERN_MONITOR_MAX_PER_MIN:-6}/min cap"

kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
assert_done
