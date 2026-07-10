#!/usr/bin/env bash
# Governor self-ROI telemetry (#272): govern-health.sh computes park rate + self-referential churn
# classification + tokens-per-ticket from ticket-history.jsonl, and run-loop's record() ENRICHES
# each history entry with token spend (from the worker's stream-json result) + a churn flag (from
# the report's PR repos). Two parts: (A) the health computation over a synthetic history; (B) an
# end-to-end proof that a real run writes enriched entries and surfaces the ROI block at run-end.
# Hermetic + generic (mk_ws_stub seeds a throwaway workspace; churn set pinned via GOVERN_SELFREF_REPOS).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
HEALTH="$DIR/../govern-health.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Seed a hermetic workspace.sh + GOVERN_WS_ROOT up front so govern-health.sh's common.sh can source a
# workspace.sh in BOTH layouts (template repo + a scaffolded workspace), independent of CWD (#255).
mk_ws_stub "$T"

# ── Part A: computation over a hand-built history ─────────────────────────────
# 4 resolved (2 self-ref harness/templates, 1 product, 1 mixed→product), 1 parked, 1 failed, plus a
# validation-evidence POINTER row that must NOT be counted as an outcome (#252 double-count guard).
H="$T/hist.jsonl"
cat > "$H" <<'EOF'
{"ticket":1,"run":"run-A","status":"resolved","ts":1000,"tokens":{"input":100,"output":200,"cacheRead":5000,"cacheCreation":700,"total":6000},"costUsd":1.50,"churn":true,"repos":["harness"]}
{"ticket":2,"run":"run-A","status":"resolved","ts":1010,"tokens":{"input":100,"output":200,"cacheRead":9000,"cacheCreation":700,"total":10000},"costUsd":3.00,"churn":false,"repos":["backend"]}
{"ticket":3,"run":"run-A","status":"parked","ts":1020,"tokens":{"input":50,"output":50,"cacheRead":900,"cacheCreation":0,"total":1000},"costUsd":0.25,"churn":null,"repos":[]}
{"ticket":4,"run":"run-A","status":"resolved","ts":1030,"tokens":{"input":10,"output":10,"cacheRead":1980,"cacheCreation":0,"total":2000},"costUsd":0.50,"churn":true,"repos":["shiploop"]}
{"ticket":5,"run":"run-B","status":"resolved","ts":2000,"tokens":{"input":100,"output":100,"cacheRead":800,"cacheCreation":0,"total":1000},"costUsd":0.30,"churn":false,"repos":["api","backend"]}
{"ticket":6,"run":"run-B","status":"failed","ts":2010}
{"ticket":2,"run":"run-B","status":"resolved","ts":2020,"kind":"validation-evidence","validationDoc":"x.md","prs":[]}
EOF

j="$(GOVERN_HISTORY_FILE="$H" bash "$HEALTH" --json)"
# all-time outcome counts (validation-evidence row excluded → 6 outcomes, not 7)
assert_eq "$(jq -r '.allTime.total' <<<"$j")"           "6"  "validation-evidence pointer NOT counted as an outcome"
assert_eq "$(jq -r '.allTime.status.resolved' <<<"$j")" "4"  "4 resolved outcomes all-time"
assert_eq "$(jq -r '.allTime.status.parked' <<<"$j")"   "1"  "1 parked outcome all-time"
assert_eq "$(jq -r '.allTime.status.failed' <<<"$j")"   "1"  "1 failed outcome all-time"
# park rate = 1/6 = 16.67%
assert_eq "$(jq -r '.allTime.parkRatePct|.*100|round' <<<"$j")" "1667" "park rate = 16.67%"
# churn: harness + shiploop = self-ref (2); backend + mixed[api,backend] = product (2)
assert_eq "$(jq -r '.allTime.churn.classified' <<<"$j")" "4" "4 PR-shipping tickets classified"
assert_eq "$(jq -r '.allTime.churn.selfRef' <<<"$j")"    "2" "2 self-referential (harness/templates)"
assert_eq "$(jq -r '.allTime.churn.product' <<<"$j")"    "2" "2 product (incl. mixed repos → product)"
assert_eq "$(jq -r '.allTime.churn.selfRefPct' <<<"$j")" "50" "self-ref churn = 50%"
# tokens: 6000+10000+1000+2000+1000 = 20000 over 5 rows with token data
assert_eq "$(jq -r '.allTime.tokens.withData' <<<"$j")"    "5"     "5 rows carry token data"
assert_eq "$(jq -r '.allTime.tokens.totalTokens' <<<"$j")" "20000" "total tokens = 20000"
assert_eq "$(jq -r '.allTime.tokens.avgTokens' <<<"$j")"   "4000"  "avg tokens/ticket = 4000"
assert_eq "$(jq -r '.allTime.tokens.selfRefAvgTokens' <<<"$j")" "4000" "self-ref avg tokens = (6000+2000)/2"
assert_eq "$(jq -r '.allTime.tokens.productAvgTokens' <<<"$j")" "5500" "product avg tokens = (10000+1000)/2"

# scoping: --run run-A sees only run-A's 4 rows
jA="$(GOVERN_HISTORY_FILE="$H" bash "$HEALTH" --json --run run-A)"
assert_eq "$(jq -r '.run.total' <<<"$jA")"          "4" "--run run-A scopes to run-A outcomes"
assert_eq "$(jq -r '.run.churn.selfRefPct|round' <<<"$jA")" "67" "run-A is 2/3 self-ref churn (#115 shape)"
# default run-block = most recent run (run-B)
jd="$(GOVERN_HISTORY_FILE="$H" bash "$HEALTH" --json)"
assert_eq "$(jq -r '.run.total' <<<"$jd")" "2" "default run-block = most recent run (run-B)"

# human render surfaces the three headline signals
htxt="$(GOVERN_HISTORY_FILE="$H" bash "$HEALTH")"
assert_contains "$htxt" "park rate"        "human output surfaces park rate"
assert_contains "$htxt" "self-referential" "human output surfaces churn class"
assert_contains "$htxt" "per ticket"       "human output surfaces tokens-per-ticket"

# empty / missing history degrades cleanly
assert_contains "$(GOVERN_HISTORY_FILE="$T/none.jsonl" bash "$HEALTH")" "no history yet" "missing history degrades cleanly"

# ── Part B: end-to-end — run-loop enriches history + emits ROI block at run-end ───────────────
E="$(mktemp -d)"; mk_ws_stub "$E"
mkdir -p "$E/bin" "$E/governor" "$E/logs" "$E/wt"
( cd "$E" && git init -q && git config user.email t@t && git config user.name t )
cat > "$E/tickets.md" <<'EOF'
# Tickets
---
## #1 — self-referential one
**Severity:** High — x.
body1
---
## #2 — product one
**Severity:** Medium — y.
body2
---
EOF
printf '## Open\n\n## Resolved\n' > "$E/governor/escalations.md"
cat > "$E/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$E/wt/\$1"; echo "$E/wt/\$1"
EOF
chmod +x "$E/wt.sh"
cat > "$E/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$E/bin/gh"
# stub claude: supervisor → ok; worker → resolved report + a result event carrying token USAGE, and
# a PR whose repo makes #1 self-referential (harness) and #2 product (backend).
cat > "$E/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
repo="backend"; [[ "$n" == "1" ]] && repo="harness"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"$repo\",\"number\":${n}01,\"url\":\"http://pr/$n\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
# a stream-json result event carrying token usage + cost (what history_enrich reads)
printf '{"type":"result","subtype":"success","total_cost_usd":2.5,"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":700},"result":%s}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$E/bin/claude"

HIST="$E/governor/ticket-history.jsonl"; : > "$HIST"
out="$(PATH="$E/bin:$PATH" \
  ROOT_PM=npm \
  GOVERN_SELFREF_REPOS="harness shiploop" \
  GOVERN_TICKETS_FILE="$E/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$E/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$E/logs" \
  GOVERN_HISTORY_FILE="$HIST" \
  GOVERN_TICKET_SEQ_FILE="$E/.ticket-seq" \
  GOVERN_LOCK="$E/lock" \
  GOVERN_WORKTREE_CMD="$E/wt.sh" \
  GOVERN_CLAUDE_BIN="$E/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 2>&1)"

assert_contains "$out" "resolved=2"                 "e2e: both tickets resolved"
assert_contains "$out" "health |"                   "e2e: ROI health logged at run-end"
# the enriched history entries carry token spend + churn classification
t1="$(jq -sc '[.[]|select(.ticket==1 and .status=="resolved")]|last' "$HIST")"
t2="$(jq -sc '[.[]|select(.ticket==2 and .status=="resolved")]|last' "$HIST")"
assert_eq "$(jq -r '.tokens.total' <<<"$t1")" "6000" "e2e: #1 history entry carries total token spend (100+200+5000+700)"
assert_eq "$(jq -r '.costUsd' <<<"$t1")"      "2.5"  "e2e: #1 history entry carries costUsd"
assert_eq "$(jq -r '.churn' <<<"$t1")"        "true" "e2e: #1 (harness PR) classified self-referential churn"
assert_eq "$(jq -r '.churn' <<<"$t2")"        "false" "e2e: #2 (backend PR) classified product"

# the run summary.md carries the ROI block
summ="$(cat "$E/logs"/run-*/summary.md 2>/dev/null || true)"
assert_contains "$summ" "Governor ROI (self-telemetry" "e2e: summary.md carries the ROI section"

rm -rf "$E"
assert_done
