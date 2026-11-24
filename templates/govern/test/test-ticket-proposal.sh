#!/usr/bin/env bash
# govern::ticket_proposal / govern::ticket_precision (lib/common.sh) and their CLI wrapper
# ticket-proposal.sh.
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
#   8. A STALE caller copy (a worktree queue file predating main's proposal append) yields the
#      distinct rc 3 + stderr signal from govern::_tickets_field_stale, for both proposal and
#      precision, through the function AND the CLI (exit 4); a genuinely-absent field and a
#      missing main copy keep the old plain rc 0.
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

# ── 8: a STALE caller copy (worktree queue file predating main's proposal append) ───────────────
# A worker worktree's tickets.md can lack a proposal the MAIN checkout already carries; that must
# come back as a distinct STALE signal (rc 3, message on stderr, stdout empty), never the same
# plain-empty as a genuinely-absent proposal. Fixture: a real git repo ("main") plus one linked
# worktree whose uncommitted queue copy is stale.
MT="$T/main"; WTD="$T/wtree"
mkdir -p "$MT/queue"
( cd "$MT" && git init -q && git config user.email t@t && git config user.name t )
MF="$MT/queue/tickets.md"; WF="$WTD/queue/tickets.md"
cat > "$MF" <<'TIX'
## #80 - proposal + precision on main

**Proposed solution:** Flip the stale guard in sync.sh.

**Precision:** stated

---

## #81 - absent everywhere

**Severity:** Low

---

## #82 - proposal on both, precision only on main

**Proposed solution:** Widen the retry cap.

**Precision:** open

---
TIX
( cd "$MT" && git add -A && git commit -q -m tix && git worktree add -q --detach "$WTD" )
# The worktree starts from the committed main copy; make ITS copy stale: #80 loses its proposal
# entirely, #82 keeps the proposal but loses the precision line.
cat > "$WF" <<'TIX'
## #80 - proposal + precision on main

**Severity:** Low

---

## #81 - absent everywhere

**Severity:** Low

---

## #82 - proposal on both, precision only on main

**Proposed solution:** Widen the retry cap.

---
TIX

rc=0; p80="$(govern::ticket_proposal 80 "$WF" 2>"$T/err80")" || rc=$?
assert_eq "$rc" "3" "8a. a proposal present on MAIN but absent in the caller copy is STALE (rc 3), not empty"
assert_eq "$p80" "" "8a. the STALE signal leaves stdout EMPTY so every empty-output backstop still fires"
assert_contains "$(cat "$T/err80")" "STALE" "8a. the STALE message names the staleness on stderr"

rc=0; pr82="$(govern::ticket_precision 82 "$WF" 2>"$T/err82")" || rc=$?
assert_eq "$rc" "3" "8b. a precision present on MAIN but absent in the caller copy is STALE too"

p82="$(govern::ticket_proposal 82 "$WF")"
assert_contains "$p82" "Widen the retry cap." "8b. a field present in BOTH copies still reads normally, no probe"

rc=0; p81="$(govern::ticket_proposal 81 "$WF" 2>"$T/err81")" || rc=$?
assert_eq "$rc" "0" "8c. a ticket absent in BOTH copies is the old plain rc 0"
assert_eq "$p81" "" "8c. ...and genuinely-absent still reads as empty"
assert_eq "$(cat "$T/err81")" "" "8c. genuinely-absent emits NO stale message on stderr"

mv "$MF" "$T/main-saved"
rc=0; p80m="$(govern::ticket_proposal 80 "$WF" 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "8d. a missing main copy degrades to the old plain rc 0 (no stale probe)"
assert_eq "$p80m" "" "8d. ...and still reads as empty"
mv "$T/main-saved" "$MF"

rc=0; p84="$(govern::ticket_proposal 84 "$MF" 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "8e. the caller file IS the main checkout's copy: absent reads plain rc 0, no stale probe"

cli80_rc=0; cli80="$("$CLI" 80 "$WF" 2>"$T/err80cli")" || cli80_rc=$?
assert_eq "$cli80_rc" "4" "8f. the CLI wrapper exits 4 on a stale copy (3 is taken by ambiguous)"
assert_eq "$cli80" "" "8f. the CLI prints nothing on stdout for a stale copy"
assert_contains "$(cat "$T/err80cli")" "Re-sync" "8f. the CLI's stale message says to re-sync, not to rewrite"

assert_done
