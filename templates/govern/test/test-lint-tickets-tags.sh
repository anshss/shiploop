#!/usr/bin/env bash
# lint-tickets.sh fails on THREE independent faults and TAGS each stdout line (`HEADING #N ×count`
# / `SEVERITY #N ×count` / `FIELD #N line <n>: ...`) so ticket-sweep-reminder.sh can route them:
# before this, ANY non-zero
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

# FIELD fault only: a bullet-prefixed field marker (what a hand-edit or an older filer leaves
# behind) is invisible to the strict line-anchored extractors; the lint tags it FIELD and names
# the canonical (de-bulleted) form.
printf '## #11 — bullet field\n**Severity:** Low\nObserved: x.\n\n- **Proposed solution:** Do the thing.\n**Precision:** scoped\n\n---\n' > "$T/field.md"
out="$(bash "$LINT" "$T/field.md" 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "a bullet-prefixed field marker fails the lint"
assert_contains "$out" "FIELD #11" "the field fault is tagged FIELD"
field_line="$(printf '%s\n' "$out" | sed -n 's/^FIELD //p')"
assert_eq "$field_line" "#11 line 5: - **Proposed solution:** Do the thing. -> **Proposed solution:** Do the thing." \
  "the FIELD line names the raw line AND the canonical de-bulleted form"
if grep -q '^SEVERITY ' <<<"$out"; then
  echo "FAIL - a field-only fault produced a SEVERITY line"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - a field-only fault produces no SEVERITY line"
fi

# Negative control for the FIELD check: a bulleted **Severity:** is EXEMPT (its reader
# deliberately tolerates a leading list marker) and a bold bullet WITHOUT the colon placement is
# not a field marker at all.
printf '## #12 — bulleted severity is canonical\n- **Severity:** Low\n- **a bold bullet with no colon** stays\n---\n' > "$T/sevbullet.md"
out="$(bash "$LINT" "$T/sevbullet.md" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "a bulleted **Severity:** and a colonless bold bullet pass the lint"

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

# And a FIELD fault gets the de-bullet remedy, never the untagged fallback.
cp "$T/field.md" "$T/queue/tickets.md"
hook_out="$(printf '{"session_id":"frout","stop_hook_active":false,"cwd":"%s"}' "$T" \
  | META_ROOT="$T" bash "$SWEEP" 2>/dev/null)"
assert_contains "$hook_out" "bullet-prefixed field marker" "the sweep hook routes a field fault under the de-bullet remedy"
if grep -q "untagged fault" <<<"$hook_out"; then
  echo "FAIL - sweep hook called a FIELD fault untagged"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - sweep hook does NOT report a FIELD fault as untagged"
fi

assert_done
