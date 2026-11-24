#!/usr/bin/env bash
# resolve-labs-select.sh maps a merged sha's changed-path list to the test files that cover it, for
# the post-merge gate's GOVERN_POST_MERGE_LABS_SELECT seam. The five map rows, each verified against
# the LIVE suite directory (over-selection is the safe direction, so assertions are "covers", not
# "equals" except where the mapping is exact):
#   1. a changed govern test selects itself;
#   2. a changed lib selects the tests referencing it plus the shared mechanism-hash suite;
#   3. a changed hook selects the tests referencing that hook;
#   4. wrap.sh selects test-wrap-in-place;
#   5. docs select the vocab and hub-context suites;
#   6. anything unrecognized over-selects the FULL list, and so does nothing recognized.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
SELECTOR="$HUB/tools/resolve-labs-select.sh"
if [ ! -f "$SELECTOR" ]; then
  echo "SKIP: hub selector not found at $SELECTOR"
  exit 77
fi
bash -n "$SELECTOR" || { echo "FAIL: resolve-labs-select.sh does not parse"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

select_for() { # <changed paths...>; -> stdout of the selector
  : > "$T/changed.txt"
  for p in "$@"; do printf '%s\n' "$p" >> "$T/changed.txt"; done
  bash "$SELECTOR" --changed "$T/changed.txt" 2> "$T/sel.err"
}

# ── row 1: a changed govern test selects itself ──────────────────────────────
assert_contains "$(select_for templates/govern/test/test-govern-ship.sh)" "test-govern-ship" \
  "a changed govern test selects itself (by the name run-suite consumes)"
assert_eq "$(select_for templates/govern/test/test-govern-ship.sh | grep -c '^test-')" "1" \
  "a changed govern test selects ONLY itself"

# ── row 2: a changed lib selects its referencing tests + the mechanism-hash suite ────────────────
libsel="$(select_for templates/lib/run-probe.sh)"
assert_contains "$libsel" "test-sync-run-probe" \
  "a changed lib selects a test referencing lib/run-probe.sh"
assert_contains "$libsel" "test-mechanism-local-edits" \
  "a changed lib selects the shared mechanism-hash suite"
wrapsel="$(select_for templates/lib/wrap.sh)"
assert_contains "$wrapsel" "test-wrap-in-place" "wrap.sh selects test-wrap-in-place"
assert_contains "$wrapsel" "test-mechanism-local-edits" \
  "wrap.sh (a mechanism lib) selects the shared mechanism-hash suite"

# ── row 3: a changed hook selects the tests referencing it ───────────────────
assert_contains "$(select_for templates/hooks/router-posture-guard.sh)" "test-router-posture-guard" \
  "a changed hook selects the tests referencing that hook"
assert_contains "$(select_for templates/githooks/pre-commit)" "test-pre-commit-hook" \
  "a changed githook selects the tests referencing it"

# ── row 5: docs select the vocab and hub-context suites ──────────────────────
# The first vocab suite name comes from the hub-context list rather than a literal here: the
# vocabulary lint (a sibling test) greps every templates/ file, and its banned phrase's first
# half is a substring of that suite's own name.
VOCAB1="$(grep '^test-vocab' "$HUB/tools/hub-context-tests.txt" | sed -n '1p')"
docsel="$(select_for README.md)"
assert_contains "$docsel" "$VOCAB1" "docs select the vocab suite"
assert_contains "$docsel" "test-vocab-worker-pairing" "docs select the pairing vocab suite"
assert_contains "$docsel" "test-hub-context-pre-push" "docs select the hub-context suite"

# ── unrecognized: the FULL list, over-selected ───────────────────────────────
full="$(select_for tools/some-unknown-tool.sh)"
assert_contains "$full" "test-post-merge-check" \
  "an unrecognized path over-selects the full list (govern tests included)"
assert_contains "$full" "test-wrap-in-place" \
  "an unrecognized path over-selects the full list (hub-context tests included)"
assert_eq "$(select_for tools/some-unknown-tool.sh | grep -c '^test-')" \
          "$(ls "$HUB"/templates/govern/test/test-*.sh | wc -l | tr -d ' ')" \
  "an unrecognized path selects EVERY test file exactly once"
assert_eq "$(select_for | sort -u | wc -l | tr -d ' ')" \
          "$(ls "$HUB"/templates/govern/test/test-*.sh | wc -l | tr -d ' ')" \
  "an empty changed list also falls back to the full list"

# ── argv contract ────────────────────────────────────────────────────────────
bash "$SELECTOR" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL: the selector accepted a missing --changed argument"
  exit 1
fi
echo "ok - a missing --changed argument is a usage error (exit 2)"

assert_done
