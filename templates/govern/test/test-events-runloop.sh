#!/usr/bin/env bash
# End-to-end proof that the EMIT POINTS are wired, not just that the emitter works.
#
# test-events-emitter.sh proves govern::event; this proves run-loop.sh and spawn-worker.sh actually
# call it, at the right moments, with the fields govern:status folds — the failure this catches is a
# refactor that moves `cpid=$!` or `record_attempt` and silently orphans the instrumentation.
#
# Contract:
#   1. GOVERN_EVENTS unset (the default, forced to 0 by assert.sh) → a full run writes NO log at all.
#   2. GOVERN_EVENTS=1 → run_started … worker_spawned … worker_done … run_done, all valid JSON.
#   3. run_id is the SAME on every line of one run, and it is the TokenJam run id (so events join
#      against the OTel data the workers are tagged with).
#   4. worker_spawned carries a real, live-at-the-time pid and the resolved model.
#   5. worker_done carries the status the run actually recorded, plus elapsed.
#   6. A ticket the run PARKS emits ticket_parked.
#   7. status.sh folds the real log and reports the run as finished with the right counts.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"
STATUS="$DIR/../status.sh"

# Each of the two runs below gets its OWN workspace root. Re-running the governor in one root does
# not work: the first run consumes #1 out of tickets.md and leaves per-run state (ticket history, the
# already-answered ledger) that makes the second run skip the ticket entirely — the second run then
# proves nothing about the emit points.
setup_ws() { # <root>
  local T="$1"
  mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

  cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — resolves cleanly
**Severity:** High — x.
body1
---
## #2 — parks
**Severity:** Medium — y.
body2
---
EOF
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

  cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
  chmod +x "$T/wt.sh"

  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$T/bin/gh"

  # #1 resolves, #2 parks with an escalation.
  cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
if [[ "$n" == "2" ]]; then
  report='{"status":"parked","pr":null,"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"escalation":{"reason":"needs a product call","question":"which way?","options":["a","b"]}}'
else
  report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
fi
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
  return 0
}

# `--serial`: the parallel default spawns a child driver, so run_started/run_done appear TWICE (the
# orchestrator's and the child's) under one run id. That is correct behavior, but it makes every
# "exactly one run_done" assertion below ambiguous for reasons unrelated to the emit points.
run_governor() { # <root>
  local T="$1"
  PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_EVENTS_FILE="$T/governor/events.jsonl" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=0 GOVERN_IMPROVE=0 \
  GOVERN_MIGRATE_CMD="true" GOVERN_VERIFY_CMD="true" \
  bash "$RL" --serial 2>&1
}

TOFF="$(mktemp -d)"; TON="$(mktemp -d)"
trap 'rm -rf "$TOFF" "$TON"' EXIT
setup_ws "$TOFF"; mk_ws_stub "$TOFF"
setup_ws "$TON"
EV="$TON/governor/events.jsonl"

# ── 1. off by default: a REAL run writes nothing ────────────────────────────────────────────────
out="$(run_governor "$TOFF")"
assert_contains "$out" "DONE" "baseline: the run completed"
assert_eq "$([[ -e "$TOFF/governor/events.jsonl" ]] && echo yes || echo no)" "no" \
  "wiring: a full governor run with GOVERN_EVENTS off (assert.sh default) writes NO event log"

# ── 2-6. enabled ────────────────────────────────────────────────────────────────────────────────
mk_ws_stub "$TON"
out="$(GOVERN_EVENTS=1 run_governor "$TON")"
assert_contains "$out" "DONE" "enabled: the run completed"
assert_eq "$([[ -s "$EV" ]] && echo yes || echo no)" "yes" "wiring: GOVERN_EVENTS=1 produced an event log"

jq -e . "$EV" >/dev/null 2>&1
assert_eq "$?" "0" "wiring: every emitted line is valid JSON"

types="$(jq -r '.type' "$EV" | sort -u | tr '\n' ' ')"
assert_contains "$types" "run_started"    "wiring: run-loop emits run_started"
assert_contains "$types" "worker_spawned" "wiring: spawn-worker emits worker_spawned"
assert_contains "$types" "worker_done"    "wiring: spawn-worker emits worker_done from record_attempt"
assert_contains "$types" "ticket_parked"  "wiring: run-loop emits ticket_parked for the parked ticket"
assert_contains "$types" "run_done"       "wiring: run-loop emits run_done"

# 3. one run id everywhere, and it is the TokenJam id (gov-<utc>-<pid>).
assert_eq "$(jq -r '.run_id' "$EV" | sort -u | wc -l | tr -d ' ')" "1" \
  "wiring: every line of one run carries the SAME run_id"
assert_contains "$(jq -r '.run_id' "$EV" | head -1)" "gov-" \
  "wiring: run_id is the TokenJam run id, so events join against the workers' OTel tag"

# 4. worker_spawned fields.
assert_eq "$(jq -rs 'map(select(.type=="worker_spawned")) | length' "$EV")" "2" \
  "wiring: one worker_spawned per dispatched ticket"
assert_eq "$(jq -r 'select(.type=="worker_spawned" and .ticket==1) | .pid | type' "$EV")" "number" \
  "wiring: worker_spawned records the worker pid as a number"
assert_eq "$([[ "$(jq -r 'select(.type=="worker_spawned" and .ticket==1) | .pid' "$EV")" -gt 0 ]] && echo yes || echo no)" "yes" \
  "wiring: the recorded pid is a real pid, not 0"
assert_eq "$(jq -r 'select(.type=="worker_spawned" and .ticket==1) | (.model|length>0)' "$EV")" "true" \
  "wiring: worker_spawned records the resolved model tier"
assert_contains "$(jq -r 'select(.type=="worker_spawned" and .ticket==1) | .worktree' "$EV")" "ticket-1" \
  "wiring: worker_spawned records the worktree the worker runs in"

# 5. worker_done fields match what the run actually recorded.
assert_eq "$(jq -r 'select(.type=="worker_done" and .ticket==1) | .status' "$EV")" "resolved" \
  "wiring: worker_done carries the real outcome for the resolved ticket"
assert_eq "$(jq -r 'select(.type=="worker_done" and .ticket==2) | .status' "$EV")" "parked" \
  "wiring: worker_done carries the real outcome for the parked ticket"
assert_eq "$(jq -r 'select(.type=="worker_done" and .ticket==1) | .elapsed | type' "$EV")" "number" \
  "wiring: worker_done carries a numeric elapsed"
assert_eq "$(jq -r 'select(.type=="worker_done" and .ticket==1) | .attempt' "$EV")" "1" \
  "wiring: worker_done carries the attempt number from the per-attempt ledger"

# 6. the park.
assert_eq "$(jq -r 'select(.type=="ticket_parked") | .ticket' "$EV")" "2" \
  "wiring: ticket_parked names the parked ticket"
assert_eq "$(jq -rs 'map(select(.type=="ticket_parked")) | length' "$EV")" "1" \
  "wiring: only the parked ticket emits ticket_parked — resolved tickets do not"

# run_done tallies.
assert_eq "$(jq -r 'select(.type=="run_done") | .resolved' "$EV")" "1" "wiring: run_done resolved tally"
assert_eq "$(jq -r 'select(.type=="run_done") | .parked' "$EV")" "1" "wiring: run_done parked tally"

# ── 7. status.sh over the REAL log ──────────────────────────────────────────────────────────────
st="$(GOVERN_WS_ROOT="$TON" GOVERN_EVENTS_FILE="$EV" bash "$STATUS" --json --no-reap </dev/null 2>&1)"
printf '%s' "$st" | jq empty >/dev/null 2>&1
assert_eq "$?" "0" "status: --json over a real run's log is valid JSON"
assert_eq "$(printf '%s' "$st" | jq -r '.runDone')" "true" "status: the finished run reads as finished"
assert_eq "$(printf '%s' "$st" | jq -r '.active | length')" "0" "status: no workers are active after the run ends"
assert_eq "$(printf '%s' "$st" | jq -r '.counts.resolved')" "1" "status: folds the real log's resolved count"
assert_eq "$(printf '%s' "$st" | jq -r '.counts.parked')" "1" "status: folds the real log's parked count"

assert_done
