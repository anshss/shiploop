#!/usr/bin/env bash
# pre-dispatch-check.sh's proposed-solution gate (.specs/2026-09-11-advisor-worker-design.md D2,
# queue #130's full text recoverable at `git show 912e4be:queue/tickets.md`). Ships ON by default —
# unlike every other knob in test/assert.sh, this one's SHIPPED default genuinely diverges from the
# suite default, so assert.sh forces it off for every OTHER test and this file opts back in.
#
# Cases:
#   1. A ticket with no **Proposed solution:** section at all -> refuse.
#   2. A ticket carrying only the filing-time placeholder (file-ticket.sh's own template) -> refuse,
#      same as absent — filing is not specifying, so an untouched placeholder must never read as a
#      real proposal.
#   3. A ticket with a real, multi-paragraph proposal (and no **Precision:**) -> proceed.
#   4. GOVERN_PROPOSAL_GATE=0 -> proceed even on the no-proposal ticket (the documented kill switch).
#   5. Exactly one verdict line on stdout, the same posture every other gate holds.
#   6. D9 (.specs/2026-09-11-advisor-worker-design.md, corrected 2026-09-11): this gate is scoped to
#      a TICKET-NUMBER dispatch and can never become a prompt-shape check — that distinction is
#      router-posture-guard.sh's job (D4), not this script's. Pinned here so a later "improvement"
#      cannot quietly widen this gate into the #126 false positive from a second direction: a
#      non-numeric (prompt-shaped) argument is a usage error, not a verdict, and the gate's decision
#      comes ONLY from the ticket file for that number — there is no second argument for a prompt
#      or an agent type to travel through.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

PDC="$DIR/../pre-dispatch-check.sh"
[[ -f "$PDC" ]] || { echo "SKIP: pre-dispatch-check.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/queue"
export GOVERN_QUEUE_DIR="$T/queue"   # TICKETS_FILE is $GOVERN_QUEUE_DIR/tickets.md
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/queue/tickets.md" <<'TIX'
## #60 — no proposed solution at all

**Severity:** Low

Observed: something small in one file.
Done when: PR opens.

---

## #61 — still the filing-time placeholder

**Severity:** Low

Observed: something small in one file.
Done when: PR opens.

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_

---

## #62 — a real proposal

**Severity:** Low

Observed: something small in one file.
Done when: PR opens.

**Proposed solution:** Change the retry ladder to stop at three attempts instead of five.

A second paragraph of detail: the current cap lives in retry.sh:40, change the literal there.

**Precision:** scoped

---
TIX

# ── 1. no proposal at all -> refuse ────────────────────────────────────────────────────────────
out="$(GOVERN_PROPOSAL_GATE=1 "$PDC" 60)"
assert_eq "$out" "refuse: no proposed solution - the driver must specify before dispatch" \
  "1. a ticket with no Proposed solution section refuses to dispatch"

# ── 2. filing-time placeholder only -> refuse, exactly like absent ─────────────────────────────
out="$(GOVERN_PROPOSAL_GATE=1 "$PDC" 61)"
assert_eq "$out" "refuse: no proposed solution - the driver must specify before dispatch" \
  "2. an untouched filing-time placeholder reads as NO proposal, not as one"

# ── 3. a real proposal -> proceed ───────────────────────────────────────────────────────────────
out="$(GOVERN_PROPOSAL_GATE=1 "$PDC" 62)"
assert_eq "$out" "proceed" "3. a real, multi-paragraph proposal lets the dispatch proceed"

# ── 4. GOVERN_PROPOSAL_GATE=0 -> proceed even with no proposal (kill switch) ────────────────────
out="$(GOVERN_PROPOSAL_GATE=0 "$PDC" 60)"
assert_eq "$out" "proceed" "4. GOVERN_PROPOSAL_GATE=0 bypasses the gate entirely"

# ── 5. exactly one verdict line, always ─────────────────────────────────────────────────────────
lines="$(GOVERN_PROPOSAL_GATE=1 "$PDC" 60 | wc -l | tr -d ' ')"
assert_eq "$lines" "1" "5. exactly one line of verdict on stdout"

# ── 6. D9: scoped to a ticket-number dispatch, never a prompt shape ─────────────────────────────
# A prompt-shaped (non-numeric) "argument" is a usage error -- there is no path from an arbitrary
# string to a verdict. This is what keeps the read-only-child exemption entirely OUT of this
# script: nothing here ever receives a prompt to classify in the first place.
out="$("$PDC" "investigate ticket 60 read-only, produce no edits" 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "6a. a non-numeric (prompt-shaped) argument is a usage error, not a verdict"
assert_not_contains "$out" "proceed" "6b. ...and specifically never resolves to a silent 'proceed'"
assert_not_contains "$out" "refuse" "6c. ...nor to a 'refuse' -- it never reaches the gate logic at all"

# The gate's ONLY input is the ticket number; a second argument (were one ever passed) has nowhere
# to feed a prompt into the decision -- the script reads exactly one thing, the ticket file, keyed
# on that number. Grep-pin the call site so a future edit can't quietly add a prompt/type argument
# to govern::ticket_proposal without this test having to be told to look.
call_site="$(grep -n 'govern::ticket_proposal "\$N" "\$TICKETS_FILE"' "$PDC")"
assert_eq "$([ -n "$call_site" ] && echo yes || echo no)" "yes" \
  "6d. the gate's decision is keyed on \$N + \$TICKETS_FILE only -- no prompt/type argument exists to widen"

assert_done
