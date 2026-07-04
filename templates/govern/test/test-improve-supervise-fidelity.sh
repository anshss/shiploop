#!/usr/bin/env bash
# Regression for ticket #122: governor self-review input fidelity.
#   A. govern-improve.sh feeds PARKED tickets' worker escalation (from this run's report.json)
#      AND the HEAD of each FAILED ticket's worker.jsonl into the improve-reviewer prompt — so the
#      "why parked/failed" sections are populated from real worker context, not empty.
#   B. govern-supervise.sh ticket-bodies window is GOVERN_SUPERVISOR_BLOCKS_LINES-configurable and
#      defaults to 500 (was a hardcoded head -260 that silently truncated conflict-detection past
#      ~ticket 25).
# Both reviewers shell out to `claude` (overridable via GOVERN_CLAUDE_BIN). The mock captures the
# prompt it is handed to a file, then emits a minimal valid stream-json result event, so we can
# assert on EXACTLY what the reviewer was fed without a real model.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A prompt-capturing fake `claude`: writes the value passed to `-p` to $CAPTURE, emits a result.
MOCK="$ROOT/claude-mock"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$prompt" > "${CAPTURE:?CAPTURE required}"
# minimal valid stream-json result the reviewers parse via: grep result | jq -r .result
printf '{"type":"result","subtype":"success","result":"- govern-improve.sh: noted — because.\\n"}\n'
EOF
chmod +x "$MOCK"

# Isolated workspace dirs so we never touch the real governor/ or tickets.md. mk_ws_stub seeds a
# hermetic scripts/lib/workspace.sh (which common.sh sources) + exports GOVERN_WS_ROOT.
mk_ws_stub "$ROOT/ws"; mkdir -p "$GOVERN_WS_ROOT/governor"
export GOVERN_TICKETS_FILE="$ROOT/tickets.md"
export GOVERN_ESCALATIONS_FILE="$GOVERN_WS_ROOT/governor/escalations.md"
export GOVERN_IMPROVEMENTS_FILE="$ROOT/improvements.md"
export GOVERN_CLAUDE_BIN="$MOCK"
printf '# escalations\n\n## Open\n' > "$GOVERN_ESCALATIONS_FILE"

# ── A. govern-improve.sh: parked escalation + failed head are threaded into the prompt ──
RUN="$ROOT/run-A"; mkdir -p "$RUN/ticket-7" "$RUN/ticket-9"
# state.jsonl: a FAILED #7 and a PARKED #9 (status is all state.jsonl carries — not the WHY).
{
  printf '{"ticket":7,"status":"failed","note":"see worker.jsonl"}\n'
  printf '{"ticket":9,"status":"parked","note":"escalated"}\n'
} > "$RUN/state.jsonl"
# #7 worker.jsonl — opening events (what it attempted) + NO result event (crashed mid-run).
{
  printf '%s\n' '{"type":"system","subtype":"hook_started"}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"SENTINEL_ATTEMPT exploring the queue code"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
} > "$RUN/ticket-7/worker.jsonl"
# #9 report.json — the worker's PARKED report with a concrete escalation.
cat > "$RUN/ticket-9/report.json" <<'EOF'
{"status":"parked","pr":null,"lessonPatch":null,"newTickets":[],"crossRefs":{},
 "escalation":{"title":"prod secret rotation needed","reason":"SENTINEL_PARK_REASON needs a live prod secret","question":"rotate the secret then re-run?","options":["rotate-now","defer"]}}
EOF

OUT_A="$(bash "$DIR/../govern-improve.sh" "$RUN" 2>/dev/null || true)"
CAP_A="$ROOT/cap-A"; CAPTURE="$CAP_A" bash "$DIR/../govern-improve.sh" "$RUN" >/dev/null 2>&1 || true
PROMPT_A="$(cat "$CAP_A" 2>/dev/null || true)"

assert_contains "$PROMPT_A" "Why the parked tickets stopped" "A: prompt has a parked-context section"
assert_contains "$PROMPT_A" "SENTINEL_PARK_REASON" "A: parked #9 escalation reason is fed in (from report.json)"
assert_contains "$PROMPT_A" "rotate the secret then re-run" "A: parked #9 escalation question is fed in"
assert_contains "$PROMPT_A" "first events (what it attempted)" "A: failed-ticket head excerpt section present"
assert_contains "$PROMPT_A" "SENTINEL_ATTEMPT" "A: failed #7 worker-log HEAD is fed in (not just final result)"

# Regression: the harness listing MUST include lib/common.sh. A bare `ls "$DIR"/*.sh` misses lib/
# and the reviewer never sees the ONE file most improvement proposals need to touch — proposals
# then reference non-existent paths or duplicate helpers instead of extending common.sh.
assert_contains "$PROMPT_A" "lib/common.sh" "A: harness listing includes lib/common.sh (self-improve reviewer needs it)"

# A parked ticket whose report.json never got written must degrade gracefully (no crash).
RUN_B="$ROOT/run-B"; mkdir -p "$RUN_B/ticket-3"
printf '{"ticket":3,"status":"parked","note":"escalated"}\n' > "$RUN_B/state.jsonl"
CAP_B="$ROOT/cap-B"; CAPTURE="$CAP_B" bash "$DIR/../govern-improve.sh" "$RUN_B" >/dev/null 2>&1 || true
assert_contains "$(cat "$CAP_B" 2>/dev/null || true)" "no report.json" "A: missing report.json degrades to a clear note (no crash)"

# ── B. govern-supervise.sh: ticket-bodies window is configurable + defaults to 500 ──
# Build a backlog of 45 tickets (10 lines each ⇒ 450 lines). With the old head -260 the LAST
# tickets (#27+) are truncated; with the new default 500 the whole backlog survives.
: > "$GOVERN_TICKETS_FILE"
for n in $(seq 1 45); do
  printf '## #%s — ticket %s SENTINEL_T%s\n**Severity:** Low\n\nbody line a\nbody line b\nbody line c\n\n---\n\n' "$n" "$n" "$n" >> "$GOVERN_TICKETS_FILE"
done
cat > "$GOVERN_WS_ROOT/governor/supervisor-prompt.md" <<'EOF'
SUPERVISE. Review the backlog.
EOF
export GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_WS_ROOT/governor/supervisor-prompt.md"
RUN_S="$ROOT/run-S"; mkdir -p "$RUN_S"; printf '{"ticket":1,"status":"resolved"}\n' > "$RUN_S/state.jsonl"

# Default window (500): the last ticket #45 must be present.
CAP_S="$ROOT/cap-S"; CAPTURE="$CAP_S" bash "$DIR/../govern-supervise.sh" "$RUN_S" >/dev/null 2>&1 || true
assert_contains "$(cat "$CAP_S")" "SENTINEL_T45" "B: default window 500 covers the whole 45-ticket backlog (no silent truncation)"

# Explicit small window proves the knob is wired: #60 truncated away when capped at 30 lines.
CAP_S2="$ROOT/cap-S2"; GOVERN_SUPERVISOR_BLOCKS_LINES=30 CAPTURE="$CAP_S2" bash "$DIR/../govern-supervise.sh" "$RUN_S" >/dev/null 2>&1 || true
PROMPT_S2="$(cat "$CAP_S2")"
assert_contains "$PROMPT_S2" "SENTINEL_T1" "B: small window still includes the first ticket"
if printf '%s' "$PROMPT_S2" | grep -qF "SENTINEL_T45"; then
  printf 'FAIL - B: GOVERN_SUPERVISOR_BLOCKS_LINES=30 should truncate before #45\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - B: GOVERN_SUPERVISOR_BLOCKS_LINES knob truncates as configured\n'; fi

assert_done
