#!/usr/bin/env bash
# #139 - dispatch-time overlap nudge, zero model calls. Named dispatch (post-#137) batches overlap
# WITHIN the named set (govern::locality_groups), but has no visibility into a ticket the operator
# did not name. Measured: 81% of dispatched tickets touched files an earlier ticket touched, and 45%
# of overlapping pairs were both ALREADY QUEUED at dispatch - batchable if the operator had known.
# govern::overlap_nudge is a non-blocking hint only: it never changes DISPATCH_GROUPS, never touches
# the queue, and never blocks. Proves:
#   (A) an exact shared file between a queued (non-named) ticket and a named one prints a nudge.
#   (B) no shared path anywhere -> silence.
#   (C) a ticket in the CURRENT named set is excluded even if it shares a file with another named
#       ticket (the whole point is surfacing what is NOT already in the dispatch).
#   (D) a 5-line cap even when more than 5 tickets overlap.
#   (E) GOVERN_OVERLAP_NUDGE=0 silences the feature entirely.
#   (F) a directory-only overlap (depth >= 2, no exact file) is labeled distinctly (`[overlap-dir]`)
#       and never conflated with an exact-file (`[overlap]`) nudge.
#   (G) `file:line` in a queued ticket's body counts as its file.
# Sandboxed: temp tickets.md, hermetic workspace stub, GOVERN_SCOUT=0 (assert.sh default) so path
# extraction is 100% the backticked/body fallback - no model call anywhere in this test.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT/ws"
source "$DIR/../lib/common.sh"

TF="$ROOT/tickets.md"

# ── A/B/G - exact overlap nudges, no overlap is silent, file:line counts as its file ───────────────
cat > "$TF" <<'EOF'
## #61 - primary named ticket
**Severity:** High

**Files:** templates/govern/run-loop.sh
---
## #72 - queued, references the same file in prose with a line number
**Severity:** Medium

References `templates/govern/run-loop.sh:1027` for the fix.
---
## #90 - queued, shares nothing
**Severity:** Low

Touches `README.md` only.
---
EOF

out="$(GOVERN_OVERLAP_NUDGE=1 govern::overlap_nudge "61" "$TF")"
assert_contains "$out" "[overlap] queued #72 references templates/govern/run-loop.sh, also targeted by #61" \
  "A1: exact shared file (via file:line) between queued #72 and named #61 is nudged"
assert_contains "$out" "npm run govern -- 61 72" "A2: the nudge names the batch command"
if printf '%s\n' "$out" | grep -q '#90'; then f=1; else f=0; fi
assert_eq "$f" "0" "B1: #90 (no shared path at all) produces no nudge line"

# ── C - a ticket already in the CURRENT named set is excluded ──────────────────────────────────────
cat > "$TF" <<'EOF'
## #61 - primary named ticket
**Severity:** High

**Files:** templates/govern/run-loop.sh
---
## #62 - ALSO named this dispatch, shares the same file
**Severity:** High

**Files:** templates/govern/run-loop.sh
---
EOF
out="$(GOVERN_OVERLAP_NUDGE=1 govern::overlap_nudge "61,62" "$TF")"
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "C1: a ticket in the current named set is never nudged about itself"

# ── D - 5-line cap ───────────────────────────────────────────────────────────────────────────────
{
  cat <<'EOF'
## #1 - primary named ticket
**Severity:** High

**Files:** templates/govern/run-loop.sh
---
EOF
  for i in 2 3 4 5 6 7 8; do
    cat <<EOF
## #$i - queued, shares the same file
**Severity:** Medium

**Files:** templates/govern/run-loop.sh
---
EOF
  done
} > "$TF"
out="$(GOVERN_OVERLAP_NUDGE=1 govern::overlap_nudge "1" "$TF")"
lines="$(printf '%s\n' "$out" | grep -c '^\[overlap' || true)"
assert_eq "$lines" "5" "D1: at most 5 overlap lines are ever printed, even with 7 candidates"

# ── E - GOVERN_OVERLAP_NUDGE=0 silences the feature entirely ───────────────────────────────────────
out="$(GOVERN_OVERLAP_NUDGE=0 govern::overlap_nudge "1" "$TF")"
assert_eq "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0" "E1: GOVERN_OVERLAP_NUDGE=0 prints nothing at all"

# ── F - directory-only overlap is labeled distinctly, never conflated with exact ────────────────────
cat > "$TF" <<'EOF'
## #61 - primary named ticket
**Severity:** High

**Files:** templates/govern/run-loop.sh
---
## #80 - queued, same directory, different file
**Severity:** Medium

Touches `templates/govern/lib/common.sh` for a shared helper.
---
EOF
out="$(GOVERN_OVERLAP_NUDGE=1 govern::overlap_nudge "61" "$TF")"
assert_contains "$out" "[overlap-dir]" "F1: a directory-only overlap is labeled with the weak-tier marker"
if printf '%s\n' "$out" | grep -q '^\[overlap\] '; then f=1; else f=0; fi
assert_eq "$f" "0" "F2: a directory-only overlap is never printed as an exact-file [overlap] line"
assert_contains "$out" "#80" "F3: the queued ticket number is named"
assert_contains "$out" "#61" "F4: the named ticket it overlaps is named"

assert_done
