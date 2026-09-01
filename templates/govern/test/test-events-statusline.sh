#!/usr/bin/env bash
# The statusline surface: segment producer, chain wrapper, and the install/uninstall mechanics.
#
# THE contract, the one that matters more than the feature: installing must NEVER clobber an
# existing statusLine.command. Plenty of people run ccusage or a custom HUD there, and
# statusLine.command is a single string — writing our own value would destroy theirs silently.
#
# Contract:
#   1. Segment is SILENT with no event log, with no run, and after a run finishes.
#   2. Segment renders live/total, the oldest live worker's ticket + tier + elapsed.
#   3. Segment verifies liveness with kill -0 — a dead pid is not counted.
#   4. Segment finds the log by walking UP from the stdin cwd (sessions live in sub-repos).
#   5. Install records the ENTIRE previous statusLine object verbatim before writing.
#   6. The wrapper runs the original command with the same stdin and its output comes FIRST.
#   7. Uninstall restores the recorded object byte for byte — including restoring its ABSENCE.
#   8. A second install refuses rather than recording our own wrapper as "the original".
#   9. Malformed settings.json is refused, never rewritten.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v jq >/dev/null 2>&1 || { echo "SKIP: statusline install needs jq" >&2; exit 0; }

T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
SEG="$DIR/../statusline-segment.sh"
CHAIN="$DIR/../statusline-chain.sh"
INSTALL="$DIR/../statusline-install.sh"

# A workspace two levels deep, so the walk-up is actually exercised.
WS="$T/ws"; DEEP="$WS/backend/src"; mkdir -p "$DEEP" "$WS/governor"
EV="$WS/governor/events.jsonl"

seg() { # stdin JSON is built from the cwd we pass
  printf '{"cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"x"}}' "$1" "$1" "$WS" \
    | env -u GOVERN_EVENTS_FILE bash "$SEG" 2>/dev/null
}

# ── 1a. no log at all ───────────────────────────────────────────────────────────────────────────
assert_eq "$(seg "$DEEP")" "" "segment: silent when there is no event log anywhere above the cwd"

sleep 60 & LIVE_PID=$!
sleep 60 & LIVE_PID2=$!
sleep 0.1 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null

ev() { printf '%s\n' "$1" >> "$EV"; }
TS="$(date +%s)"
ev "{\"ts\":$((TS-3000)),\"run_id\":\"r1\",\"type\":\"run_started\",\"mode\":\"live\",\"target\":\"backlog\",\"parallel\":4}"
ev "{\"ts\":$((TS-2000)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":94,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":$LIVE_PID}"
ev "{\"ts\":$((TS-1990)),\"run_id\":\"r1\",\"type\":\"worker_escalated\",\"ticket\":94,\"from\":\"sonnet\",\"to\":\"opus\",\"reason\":\"budget\"}"
ev "{\"ts\":$((TS-600)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":97,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":$LIVE_PID2}"
# A phantom: spawned, pid long dead, no done event. Must NOT be counted.
ev "{\"ts\":$((TS-500)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":98,\"model\":\"haiku\",\"effort\":\"low\",\"pid\":$DEAD_PID}"
# Two finished tickets.
ev "{\"ts\":$((TS-400)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":95,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":$DEAD_PID}"
ev "{\"ts\":$((TS-300)),\"run_id\":\"r1\",\"type\":\"worker_done\",\"ticket\":95,\"status\":\"resolved\",\"model\":\"sonnet\",\"elapsed\":100}"
ev "{\"ts\":$((TS-290)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":96,\"model\":\"sonnet\",\"effort\":\"medium\",\"pid\":$DEAD_PID}"
ev "{\"ts\":$((TS-280)),\"run_id\":\"r1\",\"type\":\"worker_done\",\"ticket\":96,\"status\":\"parked\",\"model\":\"sonnet\",\"elapsed\":10}"

# ── 2/3/4. renders from a deep cwd ──────────────────────────────────────────────────────────────
out="$(seg "$DEEP")"
assert_contains "$out" "2/4" "segment: 2 live workers of 4 tickets answered-or-running (the dead pid is excluded)"
assert_contains "$out" "#94" "segment: names the OLDEST live worker"
assert_contains "$out" "opus" "segment: the escalated tier is what it reports"
assert_contains "$out" "33m" "segment: elapsed for the oldest live worker (~2000s)"
assert_not_contains "$out" "#98" "segment: the dead-pid phantom is not reported"

# ── 4b. same result from the workspace root ─────────────────────────────────────────────────────
assert_contains "$(seg "$WS")" "2/4" "segment: same output when the session cwd IS the workspace root"

# ── 1b. finished run ────────────────────────────────────────────────────────────────────────────
cp "$EV" "$T/ev.bak"
ev "{\"ts\":$TS,\"run_id\":\"r1\",\"type\":\"run_done\",\"resolved\":1,\"parked\":1,\"failed\":0,\"timeout\":0,\"processed\":2}"
assert_eq "$(seg "$DEEP")" "" "segment: silent once the run has finished, even with live pids in the log"
cp "$T/ev.bak" "$EV"

# ── 1c. every worker dead ───────────────────────────────────────────────────────────────────────
kill "$LIVE_PID" "$LIVE_PID2" 2>/dev/null; wait "$LIVE_PID" "$LIVE_PID2" 2>/dev/null
assert_eq "$(seg "$DEEP")" "" "segment: silent when every claimed-live pid is gone (never a stale count)"
# Put a live worker back for the chain tests below.
sleep 60 & LIVE_PID=$!
ev "{\"ts\":$((TS-2000)),\"run_id\":\"r1\",\"type\":\"worker_spawned\",\"ticket\":94,\"model\":\"opus\",\"effort\":\"high\",\"pid\":$LIVE_PID}"

# ── 5/6/7/8/9. install mechanics ────────────────────────────────────────────────────────────────
SETTINGS="$T/settings.json"
STATE="$T/shiploop-statusline.json"
inst() { GOVERN_STATUSLINE_SETTINGS="$SETTINGS" GOVERN_STATUSLINE_STATE="$STATE" bash "$INSTALL" "$@" </dev/null 2>&1; }

# The user's pre-existing statusline: a script of their own plus a padding setting they set.
USERSCRIPT="$T/my-hud.sh"
cat > "$USERSCRIPT" <<'EOS'
#!/usr/bin/env bash
in="$(cat)"
printf 'MYHUD[%s]' "$(printf '%s' "$in" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
EOS
ORIG_CMD="bash $USERSCRIPT"
jq -n --arg c "$ORIG_CMD" '{theme:"dark", statusLine:{type:"command", command:$c, padding:2}}' > "$SETTINGS"
ORIG_SETTINGS="$(cat "$SETTINGS")"

out="$(inst status)"
assert_contains "$out" "not installed" "install/status: reports not-installed before any install"
assert_contains "$out" "my-hud.sh" "install/status: shows the user's current command"

out="$(inst install)"
assert_contains "$out" "recorded verbatim" "install: says it recorded the existing command"
assert_contains "$out" "my-hud.sh" "install: names the command it wrapped"

# 5. the recording is the WHOLE previous object, verbatim.
assert_eq "$(jq -c '.originalStatusLine' "$STATE")" \
  "$(printf '%s' "$ORIG_SETTINGS" | jq -c '.statusLine')" \
  "install: the recording holds the entire previous statusLine object, verbatim"
assert_eq "$(jq -r '.originalCommand' "$STATE")" "$ORIG_CMD" "install: originalCommand is the user's command"

# settings now point at OUR wrapper, with refreshInterval, and nothing else was disturbed.
assert_contains "$(jq -r '.statusLine.command' "$SETTINGS")" "statusline-chain.sh" \
  "install: statusLine.command now runs the chain wrapper"
assert_eq "$(jq -r '.statusLine.refreshInterval' "$SETTINGS")" "5" "install: refreshInterval defaults to 5s"
assert_eq "$(jq -r '.statusLine.padding' "$SETTINGS")" "2" "install: an unrelated statusLine key is preserved"
assert_eq "$(jq -r '.theme' "$SETTINGS")" "dark" "install: unrelated top-level settings are untouched"

# 6. the wrapper actually runs the original with the same stdin, ITS output first.
payload="$(printf '{"cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"opus-5"}}' "$DEEP" "$DEEP" "$WS")"
chained="$(printf '%s' "$payload" | env -u GOVERN_EVENTS_FILE GOVERN_STATUSLINE_STATE="$STATE" bash "$CHAIN" 2>/dev/null)"
assert_contains "$chained" "MYHUD[opus-5]" "chain: the original command ran, and got the SAME stdin payload"
assert_contains "$chained" "#94" "chain: our fleet segment is appended"
assert_eq "$(printf '%s' "$chained" | sed -n 's/^\(MYHUD\).*/\1/p')" "MYHUD" \
  "chain: the user's output comes FIRST — ours is appended, never a replacement"
# `printf '%s\n'`, not `printf '%s'`: the command substitution above already stripped the trailing
# newline, so counting the bare string always yields 0 and the assertion would test nothing.
assert_eq "$(printf '%s\n' "$chained" | wc -l | tr -d ' ')" "1" "chain: emits a single line — the two halves are joined, not stacked"

# 8. a second install refuses.
out="$(inst install)"
assert_contains "$out" "already installed" "install: a second install is a no-op, not a re-record"

# Even with settings tampered back to a non-shiploop command, the EXISTING recording blocks a
# re-record — the failure mode that would make restore impossible.
jq --arg c "bash $USERSCRIPT" '.statusLine.command = $c' "$SETTINGS" > "$SETTINGS.t" && mv "$SETTINGS.t" "$SETTINGS"
out="$(inst install)"; rc=$?
assert_eq "$rc" "1" "install: refuses when a recording already exists"
assert_contains "$out" "uninstall" "install: the refusal tells the operator what to do instead"
jq --arg c "bash $CHAIN" '.statusLine.command = $c' "$SETTINGS" > "$SETTINGS.t" && mv "$SETTINGS.t" "$SETTINGS"

# 7. uninstall restores byte for byte.
out="$(inst uninstall)"
assert_contains "$out" "restored verbatim" "uninstall: reports a verbatim restore"
assert_eq "$(jq -cS '.statusLine' "$SETTINGS")" "$(printf '%s' "$ORIG_SETTINGS" | jq -cS '.statusLine')" \
  "uninstall: the statusLine object is byte-for-byte the user's original"
assert_eq "$(jq -r '.theme' "$SETTINGS")" "dark" "uninstall: unrelated settings survive the restore"
assert_eq "$([[ -f "$STATE" ]] && echo yes || echo no)" "no" "uninstall: the recording is cleaned up"

# 7b. restoring an ABSENCE — no statusLine before us means no statusLine after uninstall.
jq -n '{theme:"light"}' > "$SETTINGS"
inst install >/dev/null
assert_contains "$(jq -r '.statusLine.command' "$SETTINGS")" "statusline-chain.sh" "install: works with no previous statusLine"
assert_eq "$(jq -r '.originalStatusLine' "$STATE")" "null" "install: records null when there was no statusLine"
inst uninstall >/dev/null
assert_eq "$(jq -r 'has("statusLine")' "$SETTINGS")" "false" \
  "uninstall: restoring an absence REMOVES the key rather than leaving an empty object"

# The wrapper with nothing recorded to chain still emits our segment alone.
printf '{}' > "$STATE"
solo="$(printf '%s' "$payload" | env -u GOVERN_EVENTS_FILE GOVERN_STATUSLINE_STATE="$STATE" bash "$CHAIN" 2>/dev/null)"
assert_eq "$solo" "" "chain: with no recorded segment path it prints nothing rather than erroring"

# 9. malformed settings are refused, not rewritten.
printf 'not json at all' > "$SETTINGS"; rm -f "$STATE"
before="$(cat "$SETTINGS")"
out="$(inst install)"; rc=$?
assert_eq "$rc" "1" "install: refuses a settings.json that is not valid JSON"
assert_eq "$(cat "$SETTINGS")" "$before" "install: a refused install leaves settings.json untouched"
assert_eq "$([[ -f "$STATE" ]] && echo yes || echo no)" "no" "install: a refused install writes no recording"

kill "$LIVE_PID" 2>/dev/null; wait 2>/dev/null
assert_done
