#!/usr/bin/env bash
# Regression for the #87 learnings-digest TTL demotion and structure lint.
#
# Both are context-cost mechanisms whose output lands in EVERY session's window, so "emits nothing
# extra by default" and "silent when the file is healthy" are correctness properties, not niceties.
# Both ship INERT (SHIPLOOP_LEARNINGS_TTL=0 / SHIPLOOP_LEARNINGS_LINT=0) so the OFF direction is
# asserted as hard as the ON direction.
#
# Covered:
#   - TTL off (default): an ancient entry still injects its FULL body — no behaviour change
#   - TTL on: past SHIPLOOP_LEARNINGS_TTL_DAYS an entry degrades to TITLE ONLY (never deleted:
#     a still-true measurement that vanishes just gets re-derived at full cost)
#   - TTL on: an entry INSIDE the window is untouched, and an UNDATED entry is never aged out
#   - lint off (default): a malformed file produces no warning
#   - lint on: an ORPHANED HEADING (heading with no body) is reported with its line number
#   - lint on: an ORPHANED BODY (content before the first heading, after the preamble rule) is reported
#   - lint on: a HEALTHY file is SILENT, and an entry-less file is never linted
#   - every path still exits 0 (a SessionStart hook must never block a session)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Runs in BOTH layouts: the hub (templates/govern/test/ -> templates/hooks/) and a scaffolded
# workspace (scripts/govern/test/ -> scripts/), matching test-learnings-digest.sh.
HUB="$(cd "$DIR/../../.." && pwd)"
DIGEST=""
for c in "$HUB/templates/hooks/learnings-digest.sh" "$DIR/../../learnings-digest.sh"; do
  [ -f "$c" ] && { DIGEST="$c"; break; }
done
[ -n "$DIGEST" ] || { echo "SKIP: learnings-digest.sh not present"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'digest under test: %s\n' "$DIGEST"

# Isolate from THIS machine's real workspace CLAUDE.md / installed plugin (their size triggers are
# tested elsewhere and would leak lines into these assertions).
NO_CLAUDE="$T/no-claude-here.md"
NO_PLUGIN="$T/no-plugin-here"
# Pin "today" so TTL assertions never drift with the wall clock.
export SHIPLOOP_LEARNINGS_TODAY="2026-08-03"

# ── TTL ──────────────────────────────────────────────────────────────────────
cat > "$T/aged.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL

### 2026-01-05 — ancient measurement
ANCIENT_BODY_SENTINEL

### 2026-08-01 — fresh measurement
FRESH_BODY_SENTINEL
MD

out_off="$(bash "$DIGEST" "$T/aged.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out_off" "ANCIENT_BODY_SENTINEL" \
  "TTL off (default): the ancient entry still injects its full body — ships inert"
assert_contains "$out_off" "FRESH_BODY_SENTINEL" "TTL off: the fresh entry injects normally"

out_on="$(SHIPLOOP_LEARNINGS_TTL=1 SHIPLOOP_LEARNINGS_TTL_DAYS=14 \
  bash "$DIGEST" "$T/aged.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains     "$out_on" "ancient measurement"    "TTL on: the aged entry's TITLE still surfaces"
assert_not_contains "$out_on" "ANCIENT_BODY_SENTINEL"  "TTL on: the aged entry's BODY is demoted away"
assert_contains     "$out_on" "title only"             "TTL on: the demotion is disclosed, not silent"
assert_contains     "$out_on" "FRESH_BODY_SENTINEL" \
  "TTL on: an entry INSIDE the window keeps its full body"

# A wide window ages nothing out — proves the cutoff is the knob, not the code path.
out_wide="$(SHIPLOOP_LEARNINGS_TTL=1 SHIPLOOP_LEARNINGS_TTL_DAYS=3650 \
  bash "$DIGEST" "$T/aged.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out_wide" "ANCIENT_BODY_SENTINEL" "TTL on with a 10-year window: nothing is demoted"

# Undated entries have no date to age against and must never be demoted.
cat > "$T/undated.md" <<'MD'
# Workspace learnings

### an entry with no date at all
UNDATED_BODY_SENTINEL
MD
out_und="$(SHIPLOOP_LEARNINGS_TTL=1 SHIPLOOP_LEARNINGS_TTL_DAYS=1 \
  bash "$DIGEST" "$T/undated.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out_und" "UNDATED_BODY_SENTINEL" "TTL on: an UNDATED entry is never aged out"

# ── lint: orphaned heading (a heading whose body drifted away) ────────────────
# This is the observed live failure: a later entry gets appended BETWEEN a heading and its body, so
# the heading's slice is empty and a garbled fragment is injected at every SessionStart, unnoticed.
cat > "$T/orphan-heading.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL

---

### 2026-07-01 — heading whose body drifted away

### 2026-07-02 — the entry that was appended between
BODY_THAT_NOW_SITS_UNDER_THE_WRONG_HEADING
MD

assert_eq "$(bash "$DIGEST" "$T/orphan-heading.md" "$NO_CLAUDE" "$NO_PLUGIN" | grep -c 'malformed' || true)" "0" \
  "lint off (default): a malformed file produces no warning — ships inert"

out_oh="$(SHIPLOOP_LEARNINGS_LINT=1 bash "$DIGEST" "$T/orphan-heading.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out_oh" "malformed"                "lint on: an orphaned heading is reported"
assert_contains "$out_oh" "heading(s) with no body"  "lint on: the orphaned-heading shape is named"
assert_contains "$out_oh" "line 7"                   "lint on: the orphaned heading's line number is given"

# ── lint: orphaned body (content before the first heading, after the preamble) ─
cat > "$T/orphan-body.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL — instructional text above the rule.

---

ORPHANED_BODY_SENTINEL — belongs to some heading, but sits under none.

### 2026-07-02 — a well-formed entry
WELL_FORMED_BODY
MD

out_ob="$(SHIPLOOP_LEARNINGS_LINT=1 bash "$DIGEST" "$T/orphan-body.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out_ob" "malformed"           "lint on: an orphaned body is reported"
assert_contains "$out_ob" "orphaned body line"  "lint on: the orphaned-body shape is named"
assert_contains "$out_ob" "line 7"              "lint on: the orphaned body's line number is given"
assert_contains "$out_ob" "WELL_FORMED_BODY"    "lint on: the warning is additive — entries still inject"

# ── lint: SILENT when healthy ────────────────────────────────────────────────
cat > "$T/healthy.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL

---

### 2026-07-01 — first
FIRST_BODY

### 2026-07-02 — second
SECOND_BODY
MD
out_ok="$(SHIPLOOP_LEARNINGS_LINT=1 bash "$DIGEST" "$T/healthy.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_not_contains "$out_ok" "malformed" "lint on: a HEALTHY file produces no warning at all"
assert_contains     "$out_ok" "SECOND_BODY" "lint on: a healthy file still injects its entries"

# An entry-less file (the seed shape) is never linted — its placeholder is not an orphan.
printf '# Workspace learnings\n\nPREAMBLE\n\n---\n\n_(empty — append dated entries as you discover things)_\n' > "$T/entryless.md"
assert_eq "$(SHIPLOOP_LEARNINGS_LINT=1 bash "$DIGEST" "$T/entryless.md" "$NO_CLAUDE" "$NO_PLUGIN" | wc -c | tr -d ' ')" "0" \
  "lint on: an entry-less learnings.md still costs ZERO bytes"

# The shipped seed itself must stay at zero bytes with BOTH gates on (hub only).
SEED="$HUB/templates/seed/learnings.md"
if [ -f "$SEED" ]; then
  assert_eq "$(SHIPLOOP_LEARNINGS_LINT=1 SHIPLOOP_LEARNINGS_TTL=1 \
    bash "$DIGEST" "$SEED" "$NO_CLAUDE" "$NO_PLUGIN" | wc -c | tr -d ' ')" "0" \
    "the shipped seed learnings.md costs ZERO bytes even with TTL+lint enabled"
fi

# ── never block a session ────────────────────────────────────────────────────
for f in "$T/aged.md" "$T/orphan-heading.md" "$T/orphan-body.md" "$T/healthy.md" "$T/does-not-exist.md"; do
  rc=0
  SHIPLOOP_LEARNINGS_LINT=1 SHIPLOOP_LEARNINGS_TTL=1 \
    bash "$DIGEST" "$f" "$NO_CLAUDE" "$NO_PLUGIN" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "exit 0 on $(basename "$f") with both gates on (a SessionStart hook must never block)"
done

assert_done
