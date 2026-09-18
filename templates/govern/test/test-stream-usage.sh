#!/usr/bin/env bash
# govern::stream_usage / govern::cumulative_tokens, the usage extractor. Covers the ROOT CAUSE of
# a null tokens/costUsd row: a worker.jsonl whose JSON lines sit behind a run of NUL bytes (a
# re-dispatch truncating the file while the prior attempt's fd was still open at a high offset)
# makes plain `grep` treat the stream as BINARY and print NOTHING, so a perfectly intact `result`
# event reads as "no usage". Also covers the kill-before-verdict case: no result event at all, so
# tokens are recovered from the per-turn `.message.usage` events (cost stays null, never invented);
# and the subagent case: a session's `usage` field counts its own turns only, so a session that
# spawns subagents through the Agent tool needs the SUM across every `modelUsage` entry to get a
# complete token total, while a stream with no `modelUsage` at all still reads `usage` directly.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

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

# Subagent tokens: a session that spawns subagents through the Agent tool bills them on the SAME
# session, so the terminal event's plain `usage` field (this session's own turns only) undercounts,
# while `modelUsage` (every model the billing period touched, keyed by model) does not. Built so the
# two genuinely diverge: `usage` reflects only the advisor's own turns; `modelUsage` adds a second
# model entry standing in for a subagent's, and its own per-model `costUSD` sums to `total_cost_usd`
# exactly, the invariant that makes a summed-modelUsage total checkable rather than merely assumed.
SUBAGENT_RESULT_LINE='{"type":"result","subtype":"success","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":300,"cache_creation_input_tokens":200},"total_cost_usd":0.0623,"modelUsage":{"claude-opus-5":{"inputTokens":1000,"outputTokens":500,"cacheReadInputTokens":300,"cacheCreationInputTokens":200,"costUSD":0.0123},"claude-sonnet-5":{"inputTokens":4000,"outputTokens":1000,"cacheReadInputTokens":2000,"cacheCreationInputTokens":500,"costUSD":0.0500}}}'

printf '%s\n' "$SUBAGENT_RESULT_LINE" > "$U/subagent.jsonl"
u="$(govern::stream_usage "$U/subagent.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "result" "subagent stream → still sourced from the result event"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "9500" "subagent stream → tokens are the modelUsage SUM (the bare usage total of 2000 would drop the second model entirely)"
assert_eq "$(jq -r '.tokens.input' <<<"$u")" "5000" "subagent stream → input summed across every model entry"
assert_eq "$(jq -r '.tokens.output' <<<"$u")" "1500" "subagent stream → output summed across every model entry"
assert_eq "$(jq -r '.tokens.cacheRead' <<<"$u")" "2300" "subagent stream → cacheRead summed across every model entry"
assert_eq "$(jq -r '.tokens.cacheCreation' <<<"$u")" "700" "subagent stream → cacheCreation summed across every model entry"
assert_eq "$(jq -r '.costUsd' <<<"$u")" "0.0623" "subagent stream → cost is still total_cost_usd directly, untouched by the token fix"
# The self-checking invariant this fix relies on: a fixture whose summed per-model costUSD does not
# equal its own total_cost_usd would not be evidence that modelUsage is the complete figure.
assert_eq "$(jq -r '.modelUsage | [.[].costUSD] | add' <<<"$SUBAGENT_RESULT_LINE")" \
  "$(jq -r '.total_cost_usd' <<<"$SUBAGENT_RESULT_LINE")" \
  "subagent fixture → summed per-model costUSD equals total_cost_usd, the invariant that makes the token sum trustworthy"

# A result event whose modelUsage is present but EMPTY must fall back to `.usage`, never read a zero.
EMPTY_MODELUSAGE_LINE='{"type":"result","subtype":"success","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":300,"cache_creation_input_tokens":200},"total_cost_usd":0.0123,"modelUsage":{}}'
printf '%s\n' "$EMPTY_MODELUSAGE_LINE" > "$U/empty-modelusage.jsonl"
u="$(govern::stream_usage "$U/empty-modelusage.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "result" "empty modelUsage map → still sourced from the result event"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "2000" "empty modelUsage map → falls back to usage, not a zero"

# The real-world corruption: ~64KB of NUL bytes ahead of the JSON lines. Plain `grep` prints nothing
# here (binary file), which is exactly how an intact result event produced a null tokens/costUsd row.
dd if=/dev/zero of="$U/holed.jsonl" bs=1024 count=64 2>/dev/null
printf '%s\n' "$RESULT_LINE" >> "$U/holed.jsonl"
u="$(govern::stream_usage "$U/holed.jsonl")"
assert_eq "$(jq -r '.usageSource' <<<"$u")" "result" "NUL-holed stream → result event still found (not silenced as binary)"
assert_eq "$(jq -r '.tokens.total' <<<"$u")" "2000"  "NUL-holed stream → tokens recovered intact"

# Same file through the live token-budget watchdog's reader: it must not read 0 forever (which would
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

assert_done
