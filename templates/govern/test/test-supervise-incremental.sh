#!/usr/bin/env bash
# Regression: govern-supervise.sh must feed the supervisor INCREMENTAL run
# history (only state.jsonl entries added since ITS OWN previous pass this run, plus its own
# previous verdict as a carried-forward compressed summary) instead of re-sending the whole,
# steadily-growing state.jsonl on every pass. Must stay lossless: nothing dropped by a window,
# only not re-sent once already reviewed (the #56 regression this must not reintroduce).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

SUP="$DIR/../govern-supervise.sh"

# A prompt-capturing fake `claude`: writes the -p prompt to $CAPTURE, emits a minimal valid
# stream-json result whose .result is whatever $FAKE_SUPERVISOR_RESULT holds (defaults to a
# neutral ok verdict) so we can assert on exactly what the reviewer was fed each pass.
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
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
result="${FAKE_SUPERVISOR_RESULT:-{\"verdict\":\"ok\",\"concerns\":[]}}"
printf '{"type":"result","subtype":"success","result":%s}\n' "$(printf '%s' "$result" | jq -Rs .)"
EOF
chmod +x "$MOCK"

mk_ws_stub "$ROOT/ws"; mkdir -p "$GOVERN_WS_ROOT/governor"
export GOVERN_TICKETS_FILE="$ROOT/tickets.md"
export GOVERN_ESCALATIONS_FILE="$GOVERN_WS_ROOT/governor/escalations.md"
export GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_WS_ROOT/governor/supervisor-prompt.md"
export GOVERN_CLAUDE_BIN="$MOCK"
printf '# escalations\n\n## Open\n' > "$GOVERN_ESCALATIONS_FILE"
printf '# tickets\n---\n' > "$GOVERN_TICKETS_FILE"
printf 'SUPERVISE.\n' > "$GOVERN_SUPERVISOR_PROMPT_FILE"

RUN="$ROOT/run-1"; mkdir -p "$RUN"
printf '{"ticket":1,"status":"resolved","note":"SENTINEL_T1_DONE"}\n' > "$RUN/state.jsonl"

# ── Pass 1: no prior cursor/verdict — sees ticket 1, and an explicit "first pass" marker ──
CAP1="$ROOT/cap-1"
FAKE_SUPERVISOR_RESULT='{"verdict":"ok","concerns":["SENTINEL_CONCERN_PASS1"]}' \
  CAPTURE="$CAP1" bash "$SUP" "$RUN" >/dev/null 2>&1
P1="$(cat "$CAP1")"
assert_contains "$P1" "SENTINEL_T1_DONE" "pass 1: sees ticket #1's outcome (nothing reviewed yet)"
assert_contains "$P1" "first supervisor pass this run" "pass 1: no prior verdict — marked as the first pass"

assert_eq "$(cat "$RUN/.supervisor-cursor" 2>/dev/null || echo MISSING)" "1" \
  "pass 1: cursor advances to state.jsonl's line count (1)"
assert_contains "$(cat "$RUN/.supervisor-last-verdict.json" 2>/dev/null || echo MISSING)" "SENTINEL_CONCERN_PASS1" \
  "pass 1: this pass's own verdict is persisted for the next pass to carry forward"

# ── Pass 2: ticket #2 lands. Must see ONLY #2 as "new" plus pass 1's verdict — NOT #1's raw note ──
printf '{"ticket":2,"status":"failed","note":"SENTINEL_T2_FAILED"}\n' >> "$RUN/state.jsonl"
CAP2="$ROOT/cap-2"
FAKE_SUPERVISOR_RESULT='{"verdict":"concerns","concerns":["SENTINEL_CONCERN_PASS2"]}' \
  CAPTURE="$CAP2" bash "$SUP" "$RUN" >/dev/null 2>&1
P2="$(cat "$CAP2")"
assert_contains "$P2" "SENTINEL_T2_FAILED" "pass 2: sees the NEW ticket #2 outcome"
assert_contains "$P2" "SENTINEL_CONCERN_PASS1" "pass 2: carries forward pass 1's own verdict (compressed prior context)"
if grep -qF "SENTINEL_T1_DONE" <<<"$P2"; then
  printf 'FAIL - pass 2: must NOT re-send ticket #1'"'"'s raw note (already reviewed in pass 1)\n'
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - pass 2: does not re-send ticket #1'"'"'s raw note (already reviewed in pass 1)\n'
fi

assert_eq "$(cat "$RUN/.supervisor-cursor")" "2" "pass 2: cursor advances to 2"
assert_contains "$(cat "$RUN/.supervisor-last-verdict.json")" "SENTINEL_CONCERN_PASS2" \
  "pass 2: verdict file updated to this pass's own verdict"

# ── Pass 3: no new tickets since pass 2 — "since last pass" section must say so explicitly ──
CAP3="$ROOT/cap-3"
CAPTURE="$CAP3" bash "$SUP" "$RUN" >/dev/null 2>&1
P3="$(cat "$CAP3")"
assert_contains "$P3" "no ticket has resolved/parked/failed since your last pass" \
  "pass 3: explicit none-new marker when nothing landed since the last pass"
assert_contains "$P3" "SENTINEL_CONCERN_PASS2" "pass 3: still carries forward the latest verdict"

# ── Full history is still reachable across the run's own state.jsonl — nothing was deleted ──
assert_contains "$(cat "$RUN/state.jsonl")" "SENTINEL_T1_DONE" \
  "state.jsonl itself is untouched — ticket #1's outcome is still there, just not re-sent"

assert_done
