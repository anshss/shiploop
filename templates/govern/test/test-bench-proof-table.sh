#!/usr/bin/env bash
# bench: the published proof table cannot silently drift from the committed rows behind it.
#
# bench/results/proof-table.txt is the one exception carved out of the bench/results/ gitignore
# (#104 part 2), a committed, human-readable table in headroom's shape (conditions on line one,
# per-arm rows, per-ticket-position curve, measured/modeled tagged inline). bench/gen-proof-table.mjs
# regenerates it deterministically from bench/published-rows/replay-*.jsonl alone: no fleet, no
# network, no `claude`. This is the guard that makes the two failure modes two of the three
# category competitors have (caveman ships no committed results at all; RTK ships no dataset)
# structurally impossible here: if a row changes and nobody regenerates the table, or someone
# hand-edits the table without touching the rows, this test goes red.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
GEN="$HUB/bench/gen-proof-table.mjs"
ROWS="$HUB/bench/published-rows/replay-2026-09-05.jsonl"
COMMITTED="$HUB/bench/results/proof-table.txt"
[ -f "$GEN" ] && [ -f "$ROWS" ] && [ -f "$COMMITTED" ] || \
  { echo "SKIP: not running from a hub checkout with bench proof files ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── the drift check: regenerated output must be byte-identical to the committed table ───────────
node "$GEN" > "$T/regenerated.txt" 2>"$T/stderr"
assert_eq "$?" "0" "gen-proof-table.mjs exits 0 against the committed rows"
assert_eq "$(cat "$T/stderr")" "" "gen-proof-table.mjs writes nothing to stderr on success"

if ! diff -u "$COMMITTED" "$T/regenerated.txt" > "$T/diff.txt" 2>&1; then
  echo "bench/results/proof-table.txt has drifted from bench/gen-proof-table.mjs's output:" >&2
  cat "$T/diff.txt" >&2
  echo "Regenerate with: node bench/gen-proof-table.mjs > bench/results/proof-table.txt" >&2
fi
assert_eq "$(diff -q "$COMMITTED" "$T/regenerated.txt" >/dev/null 2>&1; echo $?)" "0" \
  "the committed proof table is exactly what the generator produces from the committed rows today"

# ── running twice from an arbitrary cwd is byte-identical (no cwd-relative path leaking in) ─────
( cd "$T" && node "$GEN" > "$T/from-tmp.txt" 2>/dev/null )
assert_eq "$(diff -q "$COMMITTED" "$T/from-tmp.txt" >/dev/null 2>&1; echo $?)" "0" \
  "the generator's output does not depend on the caller's working directory"

# ── explicit path argument reproduces the default ────────────────────────────────────────────
node "$GEN" "$ROWS" > "$T/explicit.txt" 2>/dev/null
assert_eq "$(diff -q "$COMMITTED" "$T/explicit.txt" >/dev/null 2>&1; echo $?)" "0" \
  "passing the source file explicitly reproduces the default"

# ── content sanity: the discipline the ticket asked for is actually on the page ──────────────────
content="$(cat "$COMMITTED")"
assert_contains "$content" "MEASURED" "the table tags the measured side inline"
assert_contains "$content" "MODELED" "the table tags the modeled side inline, not only in prose"
assert_contains "$content" "200k" "the 200k arm is on the page"
assert_contains "$content" "1m (1M context)" "the 1m arm is on the page"
assert_contains "$content" "uncapped" "the uncapped arm is on the page"
assert_contains "$content" "30.1%" "the unflattering 200k-default token figure is printed, not just 70.2%"
assert_contains "$content" "70.2%" "the headline 1m token figure is printed"
assert_contains "$content" "85.5%" "the uncapped ceiling figure is printed"
assert_contains "$content" "18.2%" "the 200k cost figure is printed"
assert_contains "$content" "57.3%" "the 1m cost figure is printed"
assert_contains "$content" "position  1" "the per-ticket-position curve starts at position 1"
assert_contains "$content" "0.0%" "position 1 saves 0%, printed, not rounded away"
assert_contains "$content" "by construction" "position 1's 0% is explained inline as structural, not a failure"

assert_done
