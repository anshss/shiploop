#!/usr/bin/env bash
# bench: the proof-table generator.
#
# There is no committed proof table and no committed rows file any more: nothing is published from
# this repository until the harness is instrumented (bench/published-rows/SCHEMA.md,
# bench/results/README.md). So the drift guard this test used to be, regenerating the committed
# table from the committed rows and failing on a one-byte difference, has no subject. It comes back
# with the first published corpus, and it is the reason the generator is kept working meanwhile.
#
# What is still testable without a corpus, and is tested here: the generator itself, against a rows
# file this test emits from the synthetic fixture fleet into a temp directory. Determinism,
# independence from the caller's working directory, explicit-path handling, and the inline
# measured/modeled tagging that is the whole point of the table's shape.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
GEN="$HUB/bench/gen-proof-table.mjs"
[ -f "$GEN" ] && [ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Rows from the synthetic fixture, not from any real corpus. Every number downstream of here is an
# arithmetic property of invented data and is not a claim about anything.
node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-fleet" --arm all \
  --baseline same-mix --partials drop --rows > "$T/rows.jsonl" 2>"$T/rows.err"
assert_eq "$?" "0" "the fixture fleet emits a rows file for the generator to read"
assert_eq "$(wc -l < "$T/rows.jsonl" | tr -d ' ')" "12" "3 arms x 4 counted tickets"

# ── the generator runs, and says nothing on stderr when it succeeds ──────────
node "$GEN" "$T/rows.jsonl" > "$T/table.txt" 2>"$T/stderr"
assert_eq "$?" "0" "gen-proof-table.mjs exits 0 against a rows file"
assert_eq "$(cat "$T/stderr")" "" "and writes nothing to stderr on success"

# ── deterministic: same input, same bytes, twice ─────────────────────────────
node "$GEN" "$T/rows.jsonl" > "$T/table2.txt" 2>/dev/null
assert_eq "$(diff -q "$T/table.txt" "$T/table2.txt" >/dev/null 2>&1; echo $?)" "0" \
  "two runs over the same rows produce byte-identical output"

# ── no cwd-relative path leaks into the output ───────────────────────────────
( cd "$T" && node "$GEN" "$T/rows.jsonl" > "$T/from-tmp.txt" 2>/dev/null )
assert_eq "$(diff -q "$T/table.txt" "$T/from-tmp.txt" >/dev/null 2>&1; echo $?)" "0" \
  "the generator's output does not depend on the caller's working directory"

# ── a missing or empty rows file fails loudly rather than printing a table ───
node "$GEN" "$T/no-such-rows.jsonl" > "$T/missing.txt" 2>"$T/missing.err"
assert_eq "$?" "1" "a rows file that does not exist is a hard error"
assert_eq "$(cat "$T/missing.txt")" "" "and prints no table at all"
assert_contains "$(cat "$T/missing.err")" "cannot read" "and says what it could not read"

# ── content: the discipline the table exists to carry is on the page ─────────
content="$(cat "$T/table.txt")"
assert_contains "$content" "MEASURED" "the table tags the measured side inline"
assert_contains "$content" "MODELED" "the table tags the modeled side inline, not only in prose"
assert_contains "$content" "200k" "the 200k arm is on the page"
assert_contains "$content" "1m (1M context)" "the 1m arm is on the page"
assert_contains "$content" "uncapped" "the uncapped arm is on the page"
# The fixture has one row per position, and the generator refuses to draw a median from fewer than
# 10 rows. That refusal IS the discipline worth testing here: a curve drawn from one row per point
# would be the kind of number this directory exists to not print.
assert_contains "$content" "positions with fewer than 10 rows omitted" \
  "a position with too few rows is omitted with the reason, not plotted as a one-row median"
assert_contains "$content" "not supplied" \
  "provenance the rows cannot carry renders as not-supplied rather than a stale hard-coded corpus"

# The table must report what its rows actually say, so a hand-edited table cannot pass. Checked by
# recomputing one arm's figure from the same rows with jq and finding it on the page.
tok_1m="$(jq -s '
  [.[] | select(.arm == "1m")] |
  ((([.[] | .vanillaTokens] | add) - ([.[] | .shipTokens] | add)) / ([.[] | .vanillaTokens] | add) * 100)
' "$T/rows.jsonl" | awk '{printf "%.1f%%", $1}')"
assert_contains "$content" "$tok_1m" "the 1m token figure on the page is what the rows imply, not a literal"

assert_done
