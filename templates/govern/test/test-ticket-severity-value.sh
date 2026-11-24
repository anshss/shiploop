#!/usr/bin/env bash
# Severity is ranked by its VALUE, never by substring over the whole line: the old matcher sorted
# `**Severity:** Medium — downgraded from High` as High because "high" appeared in the annotation.
# value-first-word matching makes everything after the level inert. Also proves the duplicate
# `**Severity:**` field detector: a ticket carrying two fields is flagged, a clean queue passes.
# Negative controls: every tolerant field form still ranks correctly, and a clean file returns rc 0.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"
set +e   # rc-expecting calls below (duplicate_severity_fields returns 1 on a hit) need -e off

# severity_rank: first-word-of-value matching.
assert_eq "$(govern::severity_rank "**Severity:** High")" "2" "High ranks 2"
assert_eq "$(govern::severity_rank "**Severity:** Medium")" "3" "Medium ranks 3"
assert_eq "$(govern::severity_rank "**Severity:** Low")" "4" "Low ranks 4"
assert_eq "$(govern::severity_rank "**Severity**: Severe")" "1" "colon-outside-bold Severe ranks 1"
assert_eq "$(govern::severity_rank "- **Severity:** Medium")" "3" "list form ranks 3"
assert_eq "$(govern::severity_rank "**Severity:** Catastrophic")" "5" "unknown level ranks 5"

# THE regression: an annotation naming another level must not outrank the field's own value.
assert_eq "$(govern::severity_rank "**Severity:** Medium — downgraded from High")" "3" \
  "annotated Medium ranks 3, not High (old substring matcher said High)"
assert_eq "$(govern::severity_rank "**Severity:** High (was Low, escalated)")" "2" \
  "annotated High ranks 2, not Low"

# A prose or backticked mention of the field marker is NOT a field (a LINE STARTING with the bare
# marker is one — the anchor matches the line, not the markdown).
if [[ '`**Severity:**`' =~ $GOVERN_SEVERITY_FIELD_RE ]]; then
  echo "FAIL - backticked field mention matched the anchored regex"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - backticked mention does not match the anchored regex"
fi
if printf '%s\n' "prose mentions **Severity:** mid-line" | grep -E "$GOVERN_SEVERITY_FIELD_RE" -q; then
  echo "FAIL - mid-line mention matched the LINE-ANCHORED regex"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - mid-line mention does not match the anchored regex"
fi

# duplicate_severity_fields: two fields in one block → flagged `#N ×count`, rc 1; clean → rc 0.
cat > "$T/tickets.md" <<'EOF'
## #700 — clean ticket
**Severity:** High
body
---
## #701 — body carries its own Severity copy
**Severity:** Medium

**Severity:** High — a caller restated it in the body

---
EOF
out="$(govern::duplicate_severity_fields "$T/tickets.md")"
rc=$?
assert_eq "$rc" "1" "a two-field ticket fails the duplicate-severity check"
assert_contains "$out" "#701 ×2" "the offending ticket number is named with its count"
assert_not_contains "$out" "#700" "the clean ticket is not flagged"
assert_eq "$(govern::duplicate_severity_fields "$T/nope.md")" "" "missing file is silently clean"

# select-ticket end-to-end: #2's annotated `Medium — downgraded from High` must rank MEDIUM, so the
# plain High ticket wins. On the old substring matcher this file sorted #2 first (it read "high").
cat > "$T/sel.md" <<'EOF'
## #1 — plain High
**Severity:** High
body1
---
## #2 — annotated Medium that the substring matcher read as High
**Severity:** Medium — downgraded from High
body2
---
## #3 — plain Medium baseline
**Severity:** Medium
body3
---
EOF
: > "$T/none.md"
win="$(GOVERN_TICKETS_FILE="$T/sel.md" GOVERN_ESCALATIONS_FILE="$T/none.md" "$DIR/../select-ticket.sh" "" "1,2,3" 2>/dev/null | head -1)"
assert_eq "$win" "1" "annotated Medium no longer outranks a plain High (was sorted first before)"

assert_done
