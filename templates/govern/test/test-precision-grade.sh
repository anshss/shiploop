#!/usr/bin/env bash
# Design Layer 2 (.specs/2026-09-09-model-orchestration-design.md): "tier is chosen by how
# well-specified the work is, not how hard it looks." `govern::warm_assertion` already implemented
# the top of that scale (a parent that STATED the change gets the haiku shortcut) but it was a
# single binary with nothing between "fully specified" and "ordinary dispatch". This locks in the
# generalisation into the design's three grades: stated | scoped | open.
#
# Cases:
#   1. No GOVERN_WARM, no GOVERN_PRECISION -> "scoped" (the ordinary, unasserted case), tier
#      unchanged from the floor.
#   2. GOVERN_WARM matching the ticket -> "stated", haiku (already covered by test-warm-dispatch.sh
#      for the tier; this asserts the recorded GRADE too).
#   3. GOVERN_PRECISION="<N>|open" matching the ticket -> "open", but the SAME tier as scoped today
#      (the advisor-budget half of "open" is layer 3, not built yet): the grade is what changes,
#      not the sizing.
#   4. GOVERN_PRECISION="<N>|scoped" explicit -> "scoped", same tier, source names the assertion.
#   5. GOVERN_PRECISION naming a DIFFERENT ticket -> not applied; falls back to the "scoped" default.
#   6. Malformed GOVERN_PRECISION (no pipe / non-numeric ticket / unrecognized grade) -> ignored.
#   7. GOVERN_WARM beats a GOVERN_PRECISION=open on the SAME ticket: "stated" is the strongest
#      signal and wins regardless of what else is asserted.
#   8. The live path: the per-attempt ledger (attempts.jsonl) and the fleet event log both carry
#      precisionGrade/precisionSource (rail 11: every input to the decision is recorded at the
#      moment the decision is made).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #701: the ticket under test
**Severity:** Medium
Observed: something small in one file.
Done when: PR opens.

---

## #702: an unrelated ticket
**Severity:** Medium
Observed: something else entirely.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

BRIEF='I read templates/govern/spawn-worker.sh this session. Change X to Y.'

_base() { # <logtag>
  BASE_ENV=(
    "GOVERN_TICKETS_FILE=$TMP/tickets.md"
    "GOVERN_PREFERENCES_FILE=$TMP/governor/preferences.md"
    "GOVERN_WORKER_PROMPT_FILE=$TMP/governor/worker-prompt.md"
    "GOVERN_LOG_ROOT=$TMP/logs-$1"
    "GOVERN_WORKER_MODEL=sonnet"
  )
}
dry() { # <ticket> <logtag> [extra env assignments...]
  local n="$1"; _base "$2"; shift 2
  env "${BASE_ENV[@]}" "$@" GOVERN_SPAWN_DRY_RUN=1 "$SPAWN" "$n"
}

# ── 1. no assertion at all -> "scoped", tier unchanged ──────────────────────────────────────────
d1="$(dry 701 no-assert)"
assert_eq "$(printf '%s' "$d1" | jq -r '.precision_grade')" "scoped" \
  "no GOVERN_WARM / GOVERN_PRECISION -> the ordinary 'scoped' grade"
assert_contains "$(printf '%s' "$d1" | jq -r '.precision_source')" "default" \
  "the recorded source names the default, not an assertion"
assert_eq "$(printf '%s' "$d1" | jq -r '.model')" "sonnet" "scoped -> the floor tier, unchanged"

# ── 2. GOVERN_WARM -> "stated" ───────────────────────────────────────────────────────────────────
d2="$(dry 701 warm "GOVERN_WARM=701|$BRIEF")"
assert_eq "$(printf '%s' "$d2" | jq -r '.precision_grade')" "stated" \
  "a matching GOVERN_WARM assertion -> the 'stated' grade"
assert_contains "$(printf '%s' "$d2" | jq -r '.precision_source')" "GOVERN_WARM" \
  "the recorded source names GOVERN_WARM"
assert_eq "$(printf '%s' "$d2" | jq -r '.model')" "haiku" "stated -> the cheapest existing tier"

# ── 3. GOVERN_PRECISION=open -> "open", SAME tier as scoped (advisor budget is layer 3, not built) ─
d3="$(dry 701 open "GOVERN_PRECISION=701|open")"
assert_eq "$(printf '%s' "$d3" | jq -r '.precision_grade')" "open" \
  "a matching GOVERN_PRECISION=open assertion -> the 'open' grade"
assert_contains "$(printf '%s' "$d3" | jq -r '.precision_source')" "GOVERN_PRECISION" \
  "the recorded source names GOVERN_PRECISION"
assert_eq "$(printf '%s' "$d3" | jq -r '.model')" "sonnet" \
  "open buys NO tier change today, the design's table puts scoped and open at the same tier"

# ── 4. GOVERN_PRECISION=scoped explicit -> "scoped", source names the assertion ──────────────────
d4="$(dry 701 scoped-explicit "GOVERN_PRECISION=701|scoped")"
assert_eq "$(printf '%s' "$d4" | jq -r '.precision_grade')" "scoped" \
  "an explicit GOVERN_PRECISION=scoped -> still 'scoped'"
assert_contains "$(printf '%s' "$d4" | jq -r '.precision_source')" "GOVERN_PRECISION" \
  "but the source now names the explicit assertion, not the silent default"

# ── 5. GOVERN_PRECISION scoped to a DIFFERENT ticket -> not applied ──────────────────────────────
d5="$(dry 702 other-ticket "GOVERN_PRECISION=701|open")"
assert_eq "$(printf '%s' "$d5" | jq -r '.precision_grade')" "scoped" \
  "an assertion naming #701 does NOT apply to #702 -> falls back to the default"

# ── 6. malformed values are ignored, not guessed at ──────────────────────────────────────────────
d6a="$(dry 701 malformed-nopipe "GOVERN_PRECISION=just some prose with no pipe")"
assert_eq "$(printf '%s' "$d6a" | jq -r '.precision_grade')" "scoped" \
  "GOVERN_PRECISION with no '|' separator -> ignored, default grade"
d6b="$(dry 701 malformed-noticket "GOVERN_PRECISION=notanumber|open")"
assert_eq "$(printf '%s' "$d6b" | jq -r '.precision_grade')" "scoped" \
  "GOVERN_PRECISION with a non-numeric ticket -> ignored"
d6c="$(dry 701 malformed-grade "GOVERN_PRECISION=701|wideopen")"
assert_eq "$(printf '%s' "$d6c" | jq -r '.precision_grade')" "scoped" \
  "GOVERN_PRECISION naming an unrecognized grade -> ignored (absence of evidence routes down)"

# ── 7. GOVERN_WARM beats GOVERN_PRECISION=open on the same ticket ────────────────────────────────
d7="$(dry 701 both "GOVERN_WARM=701|$BRIEF" "GOVERN_PRECISION=701|open")"
assert_eq "$(printf '%s' "$d7" | jq -r '.precision_grade')" "stated" \
  "'stated' is the strongest signal and wins over an 'open' assertion on the same ticket"
assert_eq "$(printf '%s' "$d7" | jq -r '.model')" "haiku" "and it still buys the cheapest tier"

# ── 8. the live path: the ledger and the event log both carry the grade ──────────────────────────
cat > "$TMP/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/wt.sh"
cat > "$TMP/claude-ok" <<'EOF'
#!/usr/bin/env bash
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.05}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/claude-ok"

EVLOG="$TMP/events.jsonl"
env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs-live" \
    GOVERN_WORKTREE_CMD="$TMP/wt.sh" \
    GOVERN_CLAUDE_BIN="$TMP/claude-ok" \
    GOVERN_WORKER_MODEL=sonnet \
    GOVERN_WORKER_TIMEOUT=60 \
    GOVERN_PRECISION="701|open" \
    GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$EVLOG" \
    "$SPAWN" 701 </dev/null >/dev/null

LEDGER="$TMP/logs-live/ticket-701/attempts.jsonl"
[[ -s "$LEDGER" ]] || { echo "FAIL - ledger written"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
row="$(head -1 "$LEDGER" 2>/dev/null || true)"
assert_eq "$(jq -r '.precisionGrade' <<<"$row")" "open" \
  "the ledger row records the precision grade the dispatch was decided from"
assert_contains "$(jq -r '.precisionSource' <<<"$row")" "GOVERN_PRECISION" \
  "and where that grade came from"

assert_contains "$(cat "$EVLOG" 2>/dev/null || true)" '"precision":"open"' \
  "the fleet event log's worker_spawned/worker_done rows carry the precision grade too"
assert_contains "$(cat "$EVLOG" 2>/dev/null || true)" '"modelSource":"GOVERN_WORKER_MODEL"' \
  "and the model_source, so a per-session summary can group by it without opening attempts.jsonl"
assert_contains "$(cat "$EVLOG" 2>/dev/null || true)" '"costUsd":"0.05"' \
  "and the cost, once the attempt is done"

assert_done
