#!/usr/bin/env bash
# govern::ticket_proposal / govern::ticket_precision (lib/common.sh) and their CLI wrapper
# ticket-proposal.sh — .specs/2026-09-11-advisor-worker-design.md D2/D6.
#
# Cases:
#   1. A real, multi-paragraph **Proposed solution:** is extracted in full (blank lines inside it
#      do NOT truncate it — this is the section-bounded shape gotchas_in_file uses, not the
#      blank-line-terminated shape the single-line Model:/Effort:/Flow: latches use).
#   2. A trailing **Precision:** line does not leak into the captured proposal body.
#   3. The filing-time placeholder reads as EMPTY/absent, never as a real proposal.
#   4. A ticket with no Proposed solution section at all -> empty.
#   5. **Precision:** is read case-insensitively and normalized to lowercase.
#   6. An unrecognized or placeholder **Precision:** value -> empty (callers resolve that to
#      "scoped" themselves; the function never guesses).
#   7. ticket-proposal.sh (the interactive lane's own entry point, gotchas-for-paths.sh's sibling)
#      prints nothing for a ticket with no real proposal, and prints both fields, formatted, when
#      one exists.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
mk_ws_stub "$(mktemp -d)"  # hermetic workspace stub — seed before common.sh is sourced
source "$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$T/tickets.md"
cat > "$F" <<'TIX'
## #70 — a real multi-paragraph proposal

**Severity:** Low
Observed: something.
Done when: PR opens.

**Proposed solution:** Change X to Y in retry.sh.

A second paragraph with more detail, including a blank line above it.

**Precision:** OPEN

---

## #71 — filing-time placeholder only

**Severity:** Low
Observed: something.

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_

---

## #72 — no proposal section at all

**Severity:** Low
Observed: something.
Done when: PR opens.

---

## #73 — a proposal with an unrecognized precision value

**Severity:** Low
Observed: something.

**Proposed solution:** Do the thing.
**Precision:** urgent

---
TIX

# ── 1 & 2: multi-paragraph extraction, Precision does not leak in ──────────────────────────────
p70="$(govern::ticket_proposal 70 "$F")"
assert_contains "$p70" "Change X to Y in retry.sh." "1. the proposal's first line is captured"
assert_contains "$p70" "A second paragraph with more detail" \
  "1. a blank line INSIDE the proposal does not truncate it"
assert_not_contains "$p70" "**Precision:**" "2. the trailing Precision line is not part of the proposal body"
assert_not_contains "$p70" "OPEN" "2. Precision's value does not leak into the proposal body"

# ── 3: filing-time placeholder -> empty ─────────────────────────────────────────────────────────
p71="$(govern::ticket_proposal 71 "$F")"
assert_eq "$p71" "" "3. the filing-time placeholder reads as no proposal"

# ── 4: no section at all -> empty ───────────────────────────────────────────────────────────────
p72="$(govern::ticket_proposal 72 "$F")"
assert_eq "$p72" "" "4. a ticket with no Proposed solution section at all -> empty"

# ── 5: Precision read case-insensitively, normalized lowercase ─────────────────────────────────
prec70="$(govern::ticket_precision 70 "$F")"
assert_eq "$prec70" "open" "5. **Precision:** OPEN normalizes to lowercase 'open'"

# ── 6: placeholder / unrecognized Precision -> empty ────────────────────────────────────────────
prec71="$(govern::ticket_precision 71 "$F")"
assert_eq "$prec71" "" "6a. the filing-time Precision placeholder -> empty, not a value"
prec73="$(govern::ticket_precision 73 "$F")"
assert_eq "$prec73" "" "6b. an unrecognized Precision value ('urgent') -> empty, never guessed"

# ── 7: the CLI wrapper ──────────────────────────────────────────────────────────────────────────
CLI="$DIR/../ticket-proposal.sh"
[[ -f "$CLI" ]] || { echo "SKIP: ticket-proposal.sh not found"; exit 77; }

cli70="$("$CLI" 70 "$F")"
assert_contains "$cli70" "Change X to Y in retry.sh." "7a. the CLI prints the proposal body"
assert_contains "$cli70" "**Precision:** open" "7b. the CLI prints the resolved precision"

cli72="$("$CLI" 72 "$F")"
assert_eq "$cli72" "" "7c. the CLI prints nothing for a ticket with no real proposal"

cli73="$("$CLI" 73 "$F")"
assert_contains "$cli73" "**Precision:** scoped (default" \
  "7d. an unrecognized Precision on a ticket that DOES have a real proposal still resolves to the scoped default, named as such"

assert_done
