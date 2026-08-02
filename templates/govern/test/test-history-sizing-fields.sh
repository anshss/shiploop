#!/usr/bin/env bash
# #19 regression: the cross-run history must record the sizing DECISION next to the cost it already
# records, and a KILLED/failed attempt must record the tokens it burned instead of null.
#
# Three parts:
#   1. govern::stream_usage / govern::cumulative_tokens — the usage extractor. Covers the ROOT CAUSE of
#      the observed null rows: a worker.jsonl whose JSON lines sit behind a run of NUL bytes (a
#      re-dispatch truncating the file while the prior attempt's fd was still open at a high offset)
#      makes plain `grep` treat the stream as BINARY and print NOTHING — so a perfectly intact `result`
#      event read as "no usage". Also covers the kill-before-verdict case: no result event at all, so
#      tokens are recovered from the per-turn `.message.usage` events (cost stays null — never invented).
#   2. spawn-worker.sh's per-attempt ledger (attempts.jsonl): attempt numbering, model/effort +
#      their sources, the retry escalation, stream rotation, and a timed-out attempt recording usage.
#   3. run-loop.sh → ticket-history.jsonl rows carry model/effort/attempt/usageSource, govern-health.sh
#      still runs and reports, exposes the per-model breakdown, and pre-#19 rows (no model) don't break it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"
HEALTH="$DIR/../govern-health.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ── Part 1 — the usage extractor ────────────────────────────────────────────
U="$(mktemp -d)"; trap 'rm -rf "$U"' EXIT
mk_ws_stub "$U"
# shellcheck source=../lib/common.sh
source "$DIR/../lib/common.sh"

RESULT_LINE='{"type":"result","subtype":"success","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":300,"cache_creation_input_tokens":200},"total_cost_usd":0.0123}'

printf '%s\n' "$RESULT_LINE" > "$U/clean.jsonl"
u="$(govern::stream_usage "$U/clean.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "result"  "clean stream → usage from the result event"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "2000"   "clean stream → tokens summed across all four buckets"
assert_eq "$(jq -r '.costUsd' <<<"$u")" "0.0123"      "clean stream → cost from total_cost_usd"

# The real-world corruption: ~64KB of NUL bytes ahead of the JSON lines. Plain `grep` prints nothing
# here (binary file), which is exactly how an intact result event produced a null tokens/costUsd row.
dd if=/dev/zero of="$U/holed.jsonl" bs=1024 count=64 2>/dev/null
printf '%s\n' "$RESULT_LINE" >> "$U/holed.jsonl"
u="$(govern::stream_usage "$U/holed.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "result" "NUL-holed stream → result event still found (not silenced as binary)"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "2000"  "NUL-holed stream → tokens recovered intact"

# Same file through the live token-budget watchdog's reader — it must not read 0 forever (which would
# silently disable the GOVERN_WORKER_MAX_TOKENS kill switch).
printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$U/holed.jsonl"
assert_eq "$(govern::cumulative_tokens "$U/holed.jsonl")" "15" "NUL-holed stream → cumulative_tokens still counts per-turn usage"

# Kill-before-verdict: assistant events only, NO result event.
{
  printf '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}}}\n'
  printf '{"type":"assistant","message":{"usage":{"input_tokens":200,"output_tokens":50,"cache_read_input_tokens":700,"cache_creation_input_tokens":0}}}\n'
} > "$U/killed.jsonl"
u="$(govern::stream_usage "$U/killed.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "assistant-partial" "no result event → tokens recovered from per-turn usage"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "2000"             "killed attempt → per-turn usage summed (not null)"
assert_eq "$(jq -r '.costUsd' <<<"$u")" "null"                  "killed attempt → cost stays null (no price invented)"

u="$(govern::stream_usage "$U/does-not-exist.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "none" "missing stream → usageSource none"
assert_eq "$(jq -r '.tokens' <<<"$u")" "null"      "missing stream → tokens null (honest, not a fake zero)"

# ── Part 2 — spawn-worker.sh's per-attempt ledger ───────────────────────────
T2="$(mktemp -d)"; trap 'rm -rf "$U" "$T2"' EXIT
mk_ws_stub "$T2"
mkdir -p "$T2/governor" "$T2/wt" "$T2/bin"
cat > "$T2/tickets.md" <<'EOF'
## #7 — a ticket whose ledger row records its MEASURED sizing decision
**Severity:** Medium
**Model:** haiku

body
---
EOF
printf 'DOCTRINE\n' > "$T2/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$T2/governor/worker-prompt.md"
# Creates the worktree AT $WORKTREE_BASE/<slug> (the stub's wt/ dir) so the second spawn sees the
# PRESERVED worktree and takes the retry path, exactly as a real re-run does.
cat > "$T2/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T2/wt/\$1"; echo "$T2/wt/\$1"
EOF
chmod +x "$T2/wt.sh"
cat > "$T2/bin/claude-ok" <<'EOF'
#!/usr/bin/env bash
report='{"status":"resolved","pr":{"repo":"alpha","number":7,"url":"http://pr/7"},"lessonPatch":null,"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s,"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.02}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T2/bin/claude-ok"
# A worker that emits real per-turn usage and then hangs past the timeout → hard-killed before it can
# emit a result event. This is the row a sizing loop needs most (proof a tier was too cheap).
cat > "$T2/bin/claude-hang" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"usage":{"input_tokens":400,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
sleep 30
EOF
chmod +x "$T2/bin/claude-hang"

RUNDIR="$T2/logs/run-test"
# Sizing is a MEASUREMENT now, so the ledger's model/effort must come from the scout verdict, not
# from the ticket. Pre-seed the run-scoped cache: `--verdict` re-scores it deterministically and
# never calls a model. The scope below (<=5 files, 1 repo, tests cover it, concrete direction, no
# precedent) scores `small` → (sonnet, medium). Note the ticket ALSO carries a legacy
# `**Model:** haiku` field, which must be inert — if it ever leaks back into the ledger this test
# goes red.
mkdir -p "$RUNDIR/ticket-7"
cat > "$RUNDIR/ticket-7/scout.json" <<'EOF'
{"ticket":7,"scope":{"files":3,"repos":1,"testsCover":true,"precedent":false,"changeKind":"local","fixDirection":"concrete"},"verdict":{"model":"sonnet","effort":"medium","scopeClass":"small"},"ts":1}
EOF
spawn7() { # claude-bin [extra env assignments handled by caller]
  GOVERN_TICKETS_FILE="$T2/tickets.md" \
  GOVERN_PREFERENCES_FILE="$T2/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$T2/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$T2/logs" \
  GOVERN_RUN_DIR="$RUNDIR" \
  GOVERN_WORKTREE_CMD="$T2/wt.sh" \
  GOVERN_CLAUDE_BIN="$1" \
  GOVERN_WORKER_MODEL=opus \
  GOVERN_WORKER_TIMEOUT="${2:-60}" \
  GOVERN_SCOUT=1 \
  "$SPAWN" 7 </dev/null
}

out="$(spawn7 "$T2/bin/claude-ok")"
assert_eq "$(printf '%s' "$out" | jq -r '.status')" "resolved" "attempt 1 resolves"
LEDGER="$RUNDIR/ticket-7/attempts.jsonl"
[[ -s "$LEDGER" ]] && printf 'ok   - %s\n' "spawn-worker wrote the per-attempt ledger" \
  || { printf 'FAIL - %s\n' "spawn-worker wrote the per-attempt ledger"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
r1="$(head -1 "$LEDGER")"
assert_eq "$(jq -r '.attempt' <<<"$r1")"      "1"                  "attempt is 1-based"
assert_eq "$(jq -r '.model' <<<"$r1")"        "sonnet"             "ledger records the resolved model (the MEASURED verdict)"
assert_eq "$(jq -r '.modelSource' <<<"$r1")"  "scout (scope=small)" "ledger records WHERE the model came from — the scout, not the ticket"
assert_eq "$(jq -r '.effort' <<<"$r1")"       "medium"             "ledger records the resolved effort"
assert_eq "$(jq -r '.effortSource' <<<"$r1")" "scout (scope=small)" "ledger records WHERE the effort came from"
assert_eq "$(jq -r '.isRetry' <<<"$r1")"      "false"              "attempt 1 is not a retry"
assert_eq "$(jq -r '.status' <<<"$r1")"       "resolved"           "ledger records the attempt's outcome"
assert_eq "$(jq -r '.tokens.total' <<<"$r1")" "1500"               "ledger records the attempt's tokens"
assert_eq "$(jq -r '.costUsd' <<<"$r1")"      "0.02"               "ledger records the attempt's cost"

# Attempt 2 — the worktree from attempt 1 survives, so this is the retry path: the ticket's cheap-tier
# bet is dropped and GOVERN_WORKER_MODEL takes over. It must land as a SECOND ledger row, and attempt
# 1's stream must be rotated aside rather than truncated in place.
out2="$(spawn7 "$T2/bin/claude-hang" 1)"
assert_eq "$(printf '%s' "$out2" | jq -r '.status')" "timeout" "attempt 2 is killed before its verdict"
assert_eq "$(awk 'END{print NR}' "$LEDGER")" "2" "the ledger is append-only (one row per attempt)"
r2="$(tail -1 "$LEDGER")"
assert_eq "$(jq -r '.attempt' <<<"$r2")" "2"        "attempt number increments across spawns"
assert_eq "$(jq -r '.isRetry' <<<"$r2")" "true"     "attempt 2 is flagged as a retry"
assert_eq "$(jq -r '.model' <<<"$r2")"   "opus"     "retry escalates off the measured cheap tier"
assert_eq "$(jq -r '.status' <<<"$r2")"  "timeout"  "the killed attempt records its real outcome"
assert_eq "$(jq -r '.tokens.total' <<<"$r2")" "500" "the KILLED attempt records usage, not null (#19)"
assert_eq "$(jq -r '.usageSource' <<<"$r2")" "assistant-partial" "killed attempt's usage came from per-turn events"
[[ -f "$RUNDIR/ticket-7/worker.attempt1.jsonl" ]] \
  && printf 'ok   - %s\n' "attempt 1's stream is rotated aside, not clobbered" \
  || { printf 'FAIL - %s\n' "attempt 1's stream is rotated aside, not clobbered"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── Part 3 — end-to-end: ticket-history rows + govern-health ────────────────
T="$(mktemp -d)"; trap 'rm -rf "$U" "$T2" "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — a ticket whose history row carries its sizing decision
**Severity:** Medium

body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'DOC\n' > "$T/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"
cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)   echo '[]';;
  *"pr checks"*) echo '[{"bucket":"pass"}]';;
  *"pr merge"*)  echo 'merged'; exit 0;;
  *"pr view"*)   echo 'ticket-1'; exit 0;;
  *)             echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s,"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.0123}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

HIST="$T/logs/history.jsonl"
set +e
out="$(PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_HISTORY_FILE="$HIST" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_WORKER_MODEL=sonnet GOVERN_WORKER_EFFORT=high GOVERN_SCOUT=0 \
  GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 </dev/null 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "run exits 0"

row="$(jq -c 'select(.ticket == 1 and .kind == null)' "$HIST" | tail -1)"
assert_eq "$(jq -r '.status' <<<"$row")"       "resolved" "history row records the outcome (unchanged)"
assert_eq "$(jq -r '.tokens.total' <<<"$row")" "1500"     "history row still records tokens (unchanged consumer contract)"
assert_eq "$(jq -r '.costUsd' <<<"$row")"      "0.0123"   "history row still records costUsd (unchanged consumer contract)"
assert_eq "$(jq -r '.model' <<<"$row")"        "sonnet"   "history row records the MODEL that produced the cost (#19)"
assert_eq "$(jq -r '.effort' <<<"$row")"       "high"     "history row records the EFFORT (#19)"
assert_eq "$(jq -r '.attempt' <<<"$row")"      "1"        "history row records the 1-based ATTEMPT (#19)"
assert_eq "$(jq -r '.usageSource' <<<"$row")"  "result"   "history row records where the usage came from"

# A pre-#19 row (no model/effort/attempt) must not break any consumer.
printf '{"ticket":99,"run":"run-legacy","status":"resolved","ts":10,"tokens":{"input":1,"output":1,"cacheRead":0,"cacheCreation":0,"total":2},"costUsd":0.5,"churn":true,"repos":["harness"]}\n' >> "$HIST"

hj="$(GOVERN_HISTORY_FILE="$HIST" bash "$HEALTH" --json)"
assert_eq "$(jq -r '.allTime.tokens.withData' <<<"$hj")" "2" "govern-health still aggregates tokens across old + new rows"
assert_eq "$(jq -r '.allTime.byModel | length' <<<"$hj")" "1" "byModel groups only the rows that carry a model (legacy row excluded)"
assert_eq "$(jq -r '.allTime.byModel[0].model' <<<"$hj")" "sonnet" "byModel names the tier"
assert_eq "$(jq -r '.allTime.byModel[0].resolved' <<<"$hj")" "1" "byModel counts resolved outcomes per tier"
assert_eq "$(jq -r '.allTime.byModel[0].totalTokens' <<<"$hj")" "1500" "byModel sums tokens per tier"

ht="$(GOVERN_HISTORY_FILE="$HIST" bash "$HEALTH")"
assert_contains "$ht" "by model" "human output surfaces the per-model breakdown"
assert_contains "$ht" "sonnet"   "human output names the tier"
assert_contains "$ht" "tokens"   "human output still reports the token/cost line"

assert_done
