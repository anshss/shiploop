#!/usr/bin/env bash
# lint-tickets.sh fails on TWO independent faults and TAGS each stdout line (`HEADING #N ×count`
# / `SEVERITY #N ×count`) so ticket-sweep-reminder.sh can route them: before this, ANY non-zero
# exit was reported as a duplicate heading, and the remedy that came with it (renumber the LATER
# duplicate) silently corrupts a live ticket's `**Ref:**`/`depends on #N` pointers if followed for
# a severity-dup fault that never had a duplicate heading at all.
# Negative controls: a clean file exits 0 silently, and an untagged lint line surfaces as "read the
# lint's own output" rather than a guessed remedy.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh arms -e; the lint intentionally exits 1 on a fault
LINT="$DIR/../lint-tickets.sh"
# GOVERN_HOOKS_DIR (assert.sh) resolves BOTH layouts: templates/hooks in the hub repo, <root>/scripts
# in a scaffolded workspace (hooks install flat there, so the hub-relative ../../hooks path misses).
SWEEP="$GOVERN_HOOKS_DIR/ticket-sweep-reminder.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# HEADING fault only.
printf '## #5 — one\n**Severity:** Low\n---\n## #5 — two filings collided\n**Severity:** Low\n---\n' > "$T/head.md"
out="$(bash "$LINT" "$T/head.md" 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "a duplicate heading fails the lint"
assert_contains "$out" "HEADING #5 ×2" "the heading fault is tagged HEADING"

# SEVERITY fault only: tagged SEVERITY, and NO heading line at all (this file has no dup heading).
printf '## #7 — two severity fields\n**Severity:** Medium\nbody\n**Severity:** High\n---\n' > "$T/sev.md"
out="$(bash "$LINT" "$T/sev.md" 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "a two-Severity-field ticket fails the lint"
assert_contains "$out" "SEVERITY #7 ×2" "the severity fault is tagged SEVERITY"
if printf '%s' "$out" | grep -q '^HEADING '; then
  echo "FAIL - a severity-only fault produced a HEADING line"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - a severity-only fault produces no HEADING line"
fi

# clean file: silent, exit 0 (negative control).
printf '## #8 — clean\n**Severity:** Low\n---\n## #9 — also clean\n**Severity:** High\n---\n' > "$T/clean.md"
out="$(bash "$LINT" "$T/clean.md" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "a clean file passes the lint"
assert_eq "$out" "" "a clean file prints no fault lines"

# Sweep-hook ROUTING: a severity-only fault must reach the operator under the SEVERITY remedy
# (delete the dead second copy), never under the heading remedy (renumber).
mkdir -p "$T/queue"
cp "$T/sev.md" "$T/queue/tickets.md"
hook_out="$(printf '{"session_id":"srout","stop_hook_active":false,"cwd":"%s"}' "$T" \
  | META_ROOT="$T" bash "$SWEEP" 2>/dev/null)"
assert_contains "$hook_out" "two **Severity:** fields" "the sweep hook routes a severity fault under the SEVERITY remedy"
if printf '%s' "$hook_out" | grep -q "Renumber the LATER duplicate"; then
  echo "FAIL - sweep hook offered the renumber remedy for a severity-only fault"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - sweep hook does NOT offer the renumber remedy for a severity-only fault"
fi

# And a heading fault gets the renumber remedy (negative control).
cp "$T/head.md" "$T/queue/tickets.md"
hook_out="$(printf '{"session_id":"hrout","stop_hook_active":false,"cwd":"%s"}' "$T" \
  | META_ROOT="$T" bash "$SWEEP" 2>/dev/null)"
assert_contains "$hook_out" "Renumber the LATER duplicate" "the sweep hook routes a heading fault under the renumber remedy"

assert_done
