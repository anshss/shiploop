#!/usr/bin/env bash
# GOVERN_FIELD_MARKER_BULLET_RE covers exactly the labels a STRICT line-anchored reader consumes
# (GOVERN_STRICT_FIELD_LABELS), sized by the readers themselves, never by hand:
#   1. Coverage: every literal label in a `^\*\*<Label>` reader across the governor scripts has its
#      bullet form (`- **<Label>:** x`) matched, so a new strict reader that forgets to register
#      its label fails here instead of leaving that field invisible behind a list marker.
#   2. The readers with a looser anchor (`\*{0,2}`, `\*?\*?`, leading whitespace) are pinned by
#      name, since the scan in 1 cannot see their shape.
# Negative controls: a bold label on a prose bullet (`- **Live sitemap:**`) and a near-miss of a
# real label (`Test plan`, `Where it breaks`) do NOT match: before this, the regex matched ANY bold
# label, flagged evidence lists in a live queue, and de-bulleted them at file time, which truncates
# a proposal (govern::ticket_proposal ends its capture at the next line-anchored bold label).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"

matches() { [[ "$1" =~ $GOVERN_FIELD_MARKER_BULLET_RE ]]; }

check_match() { # <line> <want: 1|0> <label>
  local got=0
  if matches "$1"; then got=1; fi
  assert_eq "$got" "$2" "$3"
}

# Exempt on purpose: Severity's reader tolerates the bullet (GOVERN_SEVERITY_FIELD_RE), and Paths'
# reader parses `### ` sections of a non-ticket file.
EXEMPT=" Severity Paths "

scan="$(grep -ohE '\^\\\*\\\*[A-Za-z][A-Za-z -]*' "$DIR"/../*.sh "$DIR"/../lib/*.sh 2>/dev/null \
  | sed -E 's/^\^\\\*\\\*//; s/[[:space:]]+$//' | sort -u)"

# Positive control on the scan itself: it must see the readers we know exist, or an empty scan
# (a moved file, a changed quoting style) would pass every coverage check below vacuously.
assert_contains "$scan" "Proposed solution" "the reader scan finds the Proposed solution reader"
assert_contains "$scan" "Where" "the reader scan finds a Where reader"

while IFS= read -r label; do
  [[ -n "$label" ]] || continue
  case "$EXEMPT" in *" $label "*) continue ;; esac
  check_match "- **$label:** x" 1 "bullet form of strict reader label '$label' is caught"
done <<<"$scan"

# 2. Loose-anchor readers the scan cannot see (common.sh depends/blocks/Fix-Files-Contain,
#    flows.sh Flow/Flow-op).
for label in "Fix-Files-Contain" "Flow" "flow" "Flow-op" "Depends on" "depends on" "Blocks" "blocks"; do
  check_match "- **$label:** x" 1 "bullet form of loose-anchor reader label '$label' is caught"
done

# Both colon placements and both list markers.
check_match "* **Precision**: stated" 1 "the \`**Label**:\` placement under a \`*\` marker is caught"
# A reader that accepts a trailing qualifier keeps accepting it in bullet form.
check_match "- **Proposed solution (v2):** x" 1 "a qualified Proposed solution label is caught"

# Negative controls.
for line in "- **Live sitemap:** 2242 entries" "- **Spend hazard:** not free" "- **Code:** pure functions" \
            "- **Evidence:** ids captured" "- **Test plan:** run twice" "- **Where it breaks:** return path" \
            "- **Type of fix:** narrow" "- **Reference:** x" "- **Severity:** Low" "**Proposed solution:** x"; do
  check_match "$line" 0 "not a bullet-prefixed strict field: $line"
done

assert_done
