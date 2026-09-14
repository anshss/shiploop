#!/usr/bin/env bash
# govern::stream_usage / govern::cumulative_tokens, the usage extractor. Covers the ROOT CAUSE of
# a null tokens/costUsd row: a worker.jsonl whose JSON lines sit behind a run of NUL bytes (a
# re-dispatch truncating the file while the prior attempt's fd was still open at a high offset)
# makes plain `grep` treat the stream as BINARY and print NOTHING, so a perfectly intact `result`
# event reads as "no usage". Also covers the kill-before-verdict case: no result event at all, so
# tokens are recovered from the per-turn `.message.usage` events (cost stays null, never invented).
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
