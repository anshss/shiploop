#!/usr/bin/env bash
# Regression: the cross-run history must record the sizing DECISION next to the cost it already
# records, and a KILLED/failed attempt must record the tokens it burned instead of null.
#
# Two parts:
#   1. govern::stream_usage / govern::cumulative_tokens — the usage extractor. Covers the ROOT CAUSE of
#      the observed null rows: a worker.jsonl whose JSON lines sit behind a run of NUL bytes (a
#      re-dispatch truncating the file while the prior attempt's fd was still open at a high offset)
#      makes plain `grep` treat the stream as BINARY and print NOTHING — so a perfectly intact `result`
#      event read as "no usage". Also covers the kill-before-verdict case: no result event at all, so
#      tokens are recovered from the per-turn `.message.usage` events (cost stays null — never invented).
#   2. resolve-ticket.sh's rt_history_enrich() (the loop purge moved run-loop's record()/
#      history_enrich() here) → ticket-history.jsonl rows carry model/effort/attempt/usageSource when
#      a per-attempt ledger (attempts.jsonl) exists in the worker log dir; govern-health.sh still
#      runs and reports, exposes the per-model breakdown, and rows from before this change (no model)
#      don't break it. The per-attempt ledger itself (attempts.jsonl) was written by the headless
#      dispatch launcher, retired along with it; seeded directly here, the same shape it used to write.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
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

# ── Part 2, resolve-ticket.sh: ticket-history rows carry sizing fields, + govern-health ─────────
# rt_history_enrich() prefers a per-attempt ledger (attempts.jsonl) in the worker log dir when one
# exists over the govern::stream_usage fallback over worker.jsonl (that fallback is Part 1's own
# subject); seed attempts.jsonl directly here in that ledger's documented shape.
RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$U" "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue" "$T/logs/ticket-1"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

set +e
cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"

TLANDED="$T/landed.log"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$TLANDED"
landed_count() { [[ -f "$TLANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$TLANDED" | wc -c | tr -d ' '; }

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #1 — a ticket whose history row carries its sizing decision

**Severity:** Medium

body1

---
TIX
( cd "$T" && git add -A && git commit -qm init )

cat > "$T/logs/ticket-1/attempts.jsonl" <<'EOF'
{"attempt":1,"isRetry":false,"model":"sonnet","modelSource":"GOVERN_WORKER_MODEL","effort":"high","effortSource":"GOVERN_WORKER_EFFORT","status":"resolved","tokens":{"input":1000,"output":500,"cacheRead":0,"cacheCreation":0,"total":1500},"costUsd":0.0123,"usageSource":"result"}
EOF

HIST="$T/logs/history.jsonl"
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"prs":[]}'
: > "$TLANDED"
out="$( cd "$T" && printf '%s' "$report" \
  | GOVERN_HISTORY_FILE="$HIST" GOVERN_LOG_ROOT="$T/logs" bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc=$?
assert_eq "$rc" "0" "run exits 0"
assert_eq "$(landed_count)" "1" "the ticket lands exactly once"

row="$(jq -c 'select(.ticket == 1 and .kind == null)' "$HIST" | tail -1)"
assert_eq "$(jq -r '.status' <<<"$row")"       "resolved" "history row records the outcome (unchanged)"
assert_eq "$(jq -r '.tokens.total' <<<"$row")" "1500"     "history row still records tokens (unchanged consumer contract)"
assert_eq "$(jq -r '.costUsd' <<<"$row")"      "0.0123"   "history row still records costUsd (unchanged consumer contract)"
assert_eq "$(jq -r '.model' <<<"$row")"        "sonnet"   "history row records the MODEL that produced the cost"
assert_eq "$(jq -r '.effort' <<<"$row")"       "high"     "history row records the EFFORT"
assert_eq "$(jq -r '.attempt' <<<"$row")"      "1"        "history row records the 1-based ATTEMPT"
assert_eq "$(jq -r '.usageSource' <<<"$row")"  "result"   "history row records where the usage came from"

# A row from before this change (no model/effort/attempt) must not break any consumer.
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
