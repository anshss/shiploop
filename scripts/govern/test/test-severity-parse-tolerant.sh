#!/usr/bin/env bash
# Proves select-ticket.sh parses ALL three common Severity forms:
#   `**Severity:** High`     (existing baseline — colon INSIDE the bold span)
#   `**Severity**: High`     (colon OUTSIDE the bold span — a common markdown-formatter drift)
#   `- **Severity:** High`   (list form — the way many ticket templates render)
# Previously only the first was recognized. The other two silently fell through to sev=4
# (unknown), deprioritizing High tickets below unrelated Mediums.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SEL="$DIR/../select-ticket.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# Three High tickets — each using one of the three severity forms — and one Medium baseline.
# If ANY of the three High forms parses as sev=4, that ticket goes to the bottom of the priority
# order and #4 (Medium) would win. With tolerant parsing all three are sev=1 (High), and
# highest number-then-severity picks the LOWEST-numbered High (which is #1).
cat > "$T/tickets.md" <<'EOF'
## #1 — colon-inside-bold form (baseline)
**Severity:** High
body1
---
## #2 — colon-outside-bold form
**Severity**: High
body2
---
## #3 — list form
- **Severity:** High
body3
---
## #4 — a Medium that should NOT win over the Highs above
**Severity:** Medium
body4
---
EOF
: > "$T/none.md"

out="$(GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/none.md" "$SEL")"
assert_eq "$out" "1" "all three High forms parse as High → lowest-numbered High #1 wins over Medium #4"

# With #1 excluded, the next High wins. If #2's colon-outside form silently downgraded to
# unknown, #3 would win (or #4 would beat it if #3's list form also downgraded).
out2="$(GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/none.md" "$SEL" "1")"
assert_eq "$out2" "2" "#2 (colon-outside-bold) parses as High and wins over Medium #4"

# With #1 and #2 excluded, #3 must win (list form parses as High).
out3="$(GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/none.md" "$SEL" "1,2")"
assert_eq "$out3" "3" "#3 (list form) parses as High and wins over Medium #4"

# Finally, all Highs excluded → Medium #4 wins.
out4="$(GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/none.md" "$SEL" "1,2,3")"
assert_eq "$out4" "4" "with all Highs excluded, Medium #4 wins normally"

assert_done
