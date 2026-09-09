#!/usr/bin/env bash
# Governor self-ROI telemetry (#272): govern-health.sh computes park rate + self-referential churn
# classification + tokens-per-ticket from ticket-history.jsonl, and resolve-ticket.sh's
# rt_history_enrich() (the loop purge moved run-loop's record()/history_enrich() here) ENRICHES each
# history entry with token spend (from the worker's log stream) + a churn flag (from the report's PR
# repos). Two parts: (A) the health computation over a synthetic history — UNCHANGED; (B) a proof
# that a real resolve-ticket.sh pass writes an enriched history row (tokens/costUsd/churn). Hermetic
# + generic (mk_ws_stub seeds a throwaway workspace; churn set pinned via GOVERN_SELFREF_REPOS).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
HEALTH="$DIR/../govern-health.sh"

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

# ── Part B: resolve-ticket.sh's rt_history_enrich() writes tokens/costUsd/churn on a green pass ──
# resolve-ticket.sh no longer spawns a worker itself — it lands a worker's ALREADY-PRODUCED report —
# so this seeds the worker's log stream directly (govern::worker_logdir's fallback: a `worker.jsonl`
# result event, read via govern::stream_usage) rather than driving a stubbed `claude` through a whole
# dispatch. #1's PR targets `harness`, pinned self-referential via GOVERN_SELFREF_REPOS below.
RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

E="$(mktemp -d)"
mk_ws_stub "$E"
export GOVERN_QUEUE_DIR="$E/queue"
mkdir -p "$E/bin/lib" "$E/queue" "$E/logs/ticket-1"
( cd "$E" && git init -q && git config user.email t@t && git config user.name t )

set +e
cp "$RT" "$E/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$E/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$E/bin/lib/"

ELANDED="$E/landed.log"
cat > "$E/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$E/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'
exit 0
STUB
cat > "$E/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$E/bin"/*.sh
export LANDED_LOG="$ELANDED"
landed_count() { [[ -f "$ELANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$ELANDED" | wc -c | tr -d ' '; }

cat > "$E/queue/tickets.md" <<'TIX'
# Tickets

## #1 — self-referential one

**Severity:** High

Done when: x.

---
TIX
( cd "$E" && git add -A && git commit -qm init )

# a result event carrying token usage + cost — what govern::stream_usage / rt_history_enrich reads
printf '{"type":"result","subtype":"success","total_cost_usd":2.5,"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":700}}\n' \
  > "$E/logs/ticket-1/worker.jsonl"

EHIST="$E/history.jsonl"
report='{"status":"resolved","pr":{"repo":"harness","number":101,"url":"http://pr/1"},"prs":[]}'
: > "$ELANDED"
out="$( cd "$E" && printf '%s' "$report" \
  | GOVERN_HISTORY_FILE="$EHIST" GOVERN_LOG_ROOT="$E/logs" GOVERN_SELFREF_REPOS="harness shiploop" \
    bash "$E/bin/resolve-ticket.sh" 1 2>&1 )"
rc=$?

assert_eq "$rc" "0" "e2e: a green, evidenced resolve exits 0"
assert_eq "$(landed_count)" "1" "e2e: the ticket lands exactly once"
row="$(jq -c 'select(.ticket==1)' "$EHIST" | tail -1)"
assert_eq "$(jq -r '.status' <<<"$row")"       "resolved" "e2e: history row records the outcome"
assert_eq "$(jq -r '.tokens.total' <<<"$row")" "6000"     "e2e: history row carries the token total (100+200+5000+700)"
assert_eq "$(jq -r '.costUsd' <<<"$row")"      "2.5"      "e2e: history row carries costUsd"
assert_eq "$(jq -r '.churn' <<<"$row")"        "true"     "e2e: history row classifies self-referential churn (harness PR)"

rm -rf "$E"
assert_done
