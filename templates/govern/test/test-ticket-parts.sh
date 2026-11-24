#!/usr/bin/env bash
# Multi-part tickets: a sub-ticket like #900B must read its OWN proposal, and a folded ticket
# called by bare number must REFUSE (rc 2) rather than silently return the earliest part's
# proposal — the old first-match code handed part B's worker part A's instructions, and because
# it always returned SOMETHING, the "empty output -> STOP" backstop stayed green on a plausible
# wrong answer.
# Negative controls: a single-proposal ticket still returns rc 0 with its body, and a two-proposal
# ticket (a real ambiguity, folded or not) still refuses.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"
set +e   # common.sh's own `set -euo pipefail` re-armed -e on sourcing; rc-expecting calls below need it off

cat > "$T/tickets.md" <<'EOF'
## #900 — parent folded ticket

**Severity:** High

### A. first part

**Proposed solution:** do the A thing

### B. second part

**Proposed solution:** do the B thing

---
## #901 — single-proposal ticket

**Proposed solution:** the one true plan

---
## #902 — ambiguous: two real proposals

**Proposed solution:** plan one

**Proposed solution:** plan two

---
EOF

# ref parsing: `900.B`, `900B`, `900-b` all mean part B; a bare number carries no part.
read -r n p <<<"$(govern::ticket_ref_part "900.B")"
assert_eq "${n}/${p}" "900/B" "900.B parses to number 900 part B"
read -r n p <<<"$(govern::ticket_ref_part "900b")"
assert_eq "${n}/${p}" "900/B" "900b parses to number 900 part B (case-insensitive)"
read -r n p <<<"$(govern::ticket_ref_part "901")"
assert_eq "${n}/${p}" "901/" "bare 901 parses to number 901, no part"

# part slice: B's slice holds B's proposal and not A's.
slice="$(printf '%s\n' "$(govern::ticket_block 900 "$T/tickets.md")" | govern::ticket_part_slice B)"
assert_contains "$slice" "do the B thing" "part slice B carries B's proposal"
if printf '%s' "$slice" | grep -q "do the A thing"; then
  echo "FAIL - part slice B leaked part A's body"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - part slice B does not contain part A's proposal"
fi
assert_contains "$(govern::ticket_block 900 "$T/tickets.md" | govern::ticket_part_slice A)" "do the A thing" "part slice A carries A's proposal"

# has_parts
block="$(govern::ticket_block 900 "$T/tickets.md")"
if govern::ticket_has_parts "$block"; then
  echo "ok   - folded block detected by ticket_has_parts"
else
  echo "FAIL - folded block NOT detected"; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
if govern::ticket_has_parts "$(govern::ticket_block 901 "$T/tickets.md")"; then
  echo "FAIL - unfolded block wrongly detected as folded"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - unfolded block NOT detected as folded"
fi

# folded + bare number → rc 2, empty output (ambiguous).
out="$(govern::ticket_proposal 900 "$T/tickets.md")"
rc=$?
assert_eq "$rc" "2" "folded ticket by bare number returns rc 2"
assert_eq "$out" "" "folded ticket by bare number prints nothing"

# named part → that part's proposal, rc 0.
out="$(govern::ticket_proposal 900B "$T/tickets.md")"
rc=$?
assert_eq "$rc" "0" "part-named proposal returns rc 0"
assert_contains "$out" "do the B thing" "part B proposal is B's own"

# GOVERN_TICKET_PART is the headless lane's way in with a bare number.
out="$(GOVERN_TICKET_PART=b govern::ticket_proposal 900 "$T/tickets.md")"
rc=$?
assert_eq "$rc" "0" "GOVERN_TICKET_PART routes a bare number to its part"
assert_contains "$out" "do the B thing" "GOVERN_TICKET_PART=b reads part B"

# negative controls.
out="$(govern::ticket_proposal 901 "$T/tickets.md")"
rc=$?
assert_eq "$rc" "0" "single-proposal ticket still returns rc 0 (negative control)"
assert_contains "$out" "the one true plan" "single-proposal ticket body intact"
out="$(govern::ticket_proposal 902 "$T/tickets.md")"
rc=$?
assert_eq "$rc" "2" "two-proposal unfolded ticket refuses with rc 2"
assert_eq "$out" "" "two-proposal unfolded ticket prints nothing"

# precision: same part-awareness, same refusal on conflicting grades.
assert_eq "$(govern::ticket_precision 900A "$T/tickets.md")" "" "precision placeholder reads absent"
cat >> "$T/tickets.md" <<'EOF'
## #903 — graded folded ticket

### A. part A

**Proposed solution:** A plan
**Precision:** stated

### B. part B

**Proposed solution:** B plan
**Precision:** scoped

---
EOF
assert_eq "$(govern::ticket_precision 903A "$T/tickets.md")" "stated" "precision part slice reads A's grade"
out="$(govern::ticket_precision 903 "$T/tickets.md")"
assert_eq "$?" "2" "precision on folded ticket by bare number refuses rc 2"

# a missing part slice reads as absent, not as the parent's proposal.
out="$(govern::ticket_proposal 900Z "$T/tickets.md")"
assert_eq "$?" "0" "a named part that does not exist reads as absent (rc 0)"
assert_eq "$out" "" "missing part prints nothing"

assert_done
