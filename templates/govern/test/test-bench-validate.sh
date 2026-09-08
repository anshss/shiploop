#!/usr/bin/env bash
# bench: the offline backlog validation gate (validate-backlog.sh).
#
# Builds a tiny local git repo in a temp dir. Zero network, zero claude spawns, no model calls.
#
#   commit A (ref)       src.sh answers 41. No tests dir.
#   commit B (merge_sha) src.sh answers 42, and tests/t.sh asserts 42.
#   test_patch           the test-file-only slice of B: adds tests/t.sh, touches no source.
#
# That is the fail-to-pass shape the real backlogs must have: at ref + test_patch the test FAILS
# (the source is still wrong), and at merge_sha it PASSES.
#
# Contract:
#   1. a well-formed ticket survives all three checks and is kept
#   2. a ticket whose verify_cmd ALREADY passes at ref is dropped (not fail-to-pass). This is the
#      one that matters most: those tickets are free wins handed to both arms, and a backlog of
#      them would make the whole comparison meaningless
#   3. a ticket whose test_patch does not apply at ref is dropped, with no fuzz and no 3-way
#   4. a ticket whose test content is absent at merge_sha is dropped
#   5. the per-backlog summary counts survivors, and a backlog under --min-tickets is UNUSABLE
#   6. --json emits the same verdicts machine-readably for the selection step
#   7. the gate exits non-zero when nothing is usable, so a pilot cannot proceed on an empty set
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/validate-backlog.sh" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
G="git -c user.email=bench@test -c user.name=bench"

# ── build the fixture repo ──────────────────────────────────────────────────
REPO="$T/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main
  printf 'answer() { echo 41; }\n' > src.sh
  $G add -A && $G commit -qm "A: answer is wrong"
  # The merge commit fixes the source AND adds the test, exactly like a real merged PR.
  printf 'answer() { echo 42; }\n' > src.sh
  mkdir -p tests
  printf '. ./src.sh\n[ "$(answer)" = 42 ]\n' > tests/t.sh
  $G add -A && $G commit -qm "B: fix + test"
) >/dev/null 2>&1

REF="$(cd "$REPO" && git rev-parse HEAD~1)"
MERGE="$(cd "$REPO" && git rev-parse HEAD)"

# The golden test_patch: the test-file slice of B only. Generated with git itself so it is a real
# diff, not a hand-written approximation of one.
PATCH="$(cd "$REPO" && git diff "$REF" "$MERGE" -- tests/)"
[ -n "$PATCH" ] && printf 'ok   - fixture: golden test_patch extracted (test files only)\n' || \
  { printf 'FAIL - fixture: empty test_patch\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# The patch body legitimately mentions src.sh (the test sources it). What must be absent is a
# src.sh FILE header: the golden patch may change tests and nothing else.
assert_not_contains "$PATCH" "+++ b/src.sh" "fixture: the golden patch changes no source file"
assert_contains "$PATCH" "+++ b/tests/t.sh" "fixture: it does change the test file"

mkbacklog() { # <dir> <jq-filter-applied-per-ticket> <ids...>
  local dir="$1"; shift
  local filter="$1"; shift
  mkdir -p "$dir"
  : > "$dir/backlog.jsonl"
  local id
  for id in "$@"; do
    jq -nc --arg id "$id" --arg repo "$REPO" --arg ref "$REF" --arg sha "$MERGE" \
      --arg patch "$PATCH" \
      '{id:$id, repo:$repo, ref:$ref, title:("t " + $id), body:"the answer is wrong",
        verify_cmd:"sh tests/t.sh", kind:"bug", upstream_pr:"local://pr",
        test_patch:$patch, merge_sha:$sha}' | jq -c "$filter" >> "$dir/backlog.jsonl"
  done
  return 0
}

# ── 1 + 5. a clean backlog of 6 good tickets is USABLE ──────────────────────
mkbacklog "$T/bl-good" "." a b c d e f
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-good/backlog.jsonl" 2>&1)"
rc=$?
assert_eq "$rc" "0" "1. a fully valid backlog exits 0"
assert_contains "$out" "keep - a" "1. a well-formed ticket is kept"
assert_contains "$out" "6/6 tickets survive" "5. the summary counts survivors"
assert_contains "$out" "verdict=USABLE" "5. and marks the backlog usable"
assert_not_contains "$out" "DROP" "1. nothing is dropped from a clean backlog"

# ── 2. a ticket that already passes at ref is not fail-to-pass ──────────────
# `true` passes everywhere, so it can never be evidence that any work was done.
mkbacklog "$T/bl-passing" '.verify_cmd = "true"' a b c d e f
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-passing/backlog.jsonl" 2>&1)"
rc=$?
assert_contains "$out" "already passes at ref (not fail-to-pass)" \
  "2. a test that passes at ref is dropped, with the reason named"
assert_contains "$out" "0/6 tickets survive" "2. every such ticket drops"
assert_contains "$out" "verdict=UNUSABLE" "5. a backlog under the minimum is unusable"
assert_eq "$rc" "1" "7. the gate exits non-zero when nothing is usable"

# ── 3. a patch that does not apply is dropped, never fuzzed ─────────────────
mkbacklog "$T/bl-badpatch" '.test_patch = "diff --git a/nope.txt b/nope.txt\n--- a/nope.txt\n+++ b/nope.txt\n@@ -1 +1 @@\n-was\n+now\n"' a b c d e f
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-badpatch/backlog.jsonl" 2>&1)"
assert_contains "$out" "test_patch does not apply cleanly at ref" \
  "3. an unappliable patch drops the ticket"
assert_contains "$out" "0/6 tickets survive" "3. and none survive"
# No fuzz, no 3-way, no partial application anywhere on the gate's apply path. Inspect the
# INVOCATION lines only: a file-wide grep would match the comments that say those words on purpose.
applies="$(grep -e 'git apply' "$HUB/bench/validate-backlog.sh" | grep -v -e '^ *#')"
assert_contains "$applies" "git apply -" "3. the gate does apply the golden patch"
assert_eq "$(printf '%s' "$applies" | grep -c -e '3way' -e 'apply -3' -e 'reject' -e 'unidiff-zero')" "0" \
  "3. and never 3-way merges, fuzzes, or partially applies it"

# ── 4. test content missing at merge_sha ────────────────────────────────────
# Point merge_sha at commit A, where tests/t.sh does not exist yet.
mkbacklog "$T/bl-nomerge" ".merge_sha = \"$REF\"" a b c d e f
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-nomerge/backlog.jsonl" 2>&1)"
assert_contains "$out" "test content is not present at merge_sha" \
  "4. a merge_sha without the test content drops the ticket"

# ── 6. --json carries the same verdicts ─────────────────────────────────────
j="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-good/backlog.jsonl" --json 2>/dev/null)"
assert_eq "$(printf '%s' "$j" | jq -r '.backlogs[0].kept')" "6" "6. --json reports the survivor count"
assert_eq "$(printf '%s' "$j" | jq -r '.backlogs[0].usable')" "true" "6. and the usable flag"
assert_eq "$(printf '%s' "$j" | jq -r '.usable | join(",")')" "bl-good" "6. usable list is consumable"
assert_eq "$(printf '%s' "$j" | jq -r '.backlogs[0].verdicts[0].failsAtRef')" "true" \
  "6. each verdict records the fail-to-pass evidence, not just the outcome"
assert_eq "$(printf '%s' "$j" | jq -r '.backlogs[0].verdicts[0].passesAtMerge')" "true" \
  "6. and the pass-at-merge evidence"

jbad="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-passing/backlog.jsonl" --json 2>/dev/null)"
assert_eq "$(printf '%s' "$jbad" | jq -r '.unusable | join(",")')" "bl-passing" \
  "6. --json names the unusable backlogs too"
assert_eq "$(printf '%s' "$jbad" | jq -r '.backlogs[0].verdicts[0].verdict')" "drop" \
  "6. with a per-ticket drop verdict"

# ── --min-tickets is honored ────────────────────────────────────────────────
mkbacklog "$T/bl-short" "." a b
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-short/backlog.jsonl" 2>&1)"
assert_contains "$out" "2/2 tickets survive (min 6) verdict=UNUSABLE" \
  "5. a short backlog is unusable even when every ticket is valid"
out="$(bash "$HUB/bench/validate-backlog.sh" "$T/bl-short/backlog.jsonl" --min-tickets 2 2>&1)"
assert_contains "$out" "verdict=USABLE" "5. --min-tickets lowers the bar deliberately"

# ── --backlogs <dir> discovers every backlog under it ───────────────────────
mkdir -p "$T/pool"
cp -R "$T/bl-good" "$T/pool/good"
cp -R "$T/bl-short" "$T/pool/short"
j="$(bash "$HUB/bench/validate-backlog.sh" --backlogs "$T/pool" --json 2>/dev/null)"
assert_eq "$(printf '%s' "$j" | jq -r '.backlogs | length')" "2" "--backlogs validates the whole pool"
assert_eq "$(printf '%s' "$j" | jq -r '.usable | join(",")')" "good" \
  "--backlogs separates usable from unusable across the pool"

assert_done
