#!/usr/bin/env bash
# Locks govern::is_validation_ticket to the FOUR tells worker-prompt.md gives the worker
# ("Validation / test / 'does X actually work' tickets"). The recognizer and the prompt had
# drifted: the gate's inline grep matched tells 1-2 and only the "live-verif" half of tell 3, so
# an informally-worded validation ticket was validation-required BY THE WORKER but invisible to
# the #67/#73 safety net — a worker resolving it on static analysis sailed straight through the
# gate that exists to stop exactly that. A silent fail-OPEN.
#
# The recognizer is deliberately fail-CLOSED, so this file asserts BOTH directions: every tell is
# recognized, and ordinary code tickets are not swept up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"

yes_v() { if govern::is_validation_ticket "$1"; then echo yes; else echo no; fi; }

# ── Tell 1: heading says VALIDATION / SPIKE.
assert_eq "$(yes_v '## #12 — VALIDATION: deploy path')" "yes" "tell 1: VALIDATION in heading"
assert_eq "$(yes_v '## #12 — SPIKE: does the proxy hold')" "yes" "tell 1: SPIKE in heading"

# ── Tell 2: an explicit **Type:** line.
assert_eq "$(yes_v '## #12 — check the thing
**Type:** Validation spike')" "yes" "tell 2: **Type:** Validation spike line"

# ── Tell 3a: the "live-verify" phrasing (the half the old regex already caught).
assert_eq "$(yes_v '## #12 — check it
**Observed:** we should live-verify this end to end')" "yes" "tell 3a: live-verify"

# ── Tell 3b: "does X actually work" — REGRESSION. The old gate regex missed this entirely.
assert_eq "$(yes_v '## #50 — Confirm the payment webhook actually works')" "yes" \
  "tell 3b: 'actually works' heading (old gate missed this)"
assert_eq "$(yes_v '## #50 — webhook check
**Observed:** nobody knows if it does the retry actually work in prod')" "yes" \
  "tell 3b: 'does … actually work' in the body"

# ── Tell 4: "Done when" asks for a PASS/FAIL from a real run — REGRESSION, also missed before.
assert_eq "$(yes_v '## #50 — Confirm the sandbox path
**Done when:** a PASS/FAIL table from an actual run against the sandbox')" "yes" \
  "tell 4: PASS/FAIL from an actual run (old gate missed this)"

# ── The exact ticket from the drift report: no VALIDATION/SPIKE, no **Type:**, no "live-verif".
assert_eq "$(yes_v '## #50 — Confirm the payment webhook actually works
**Severity:** High
**Done when:** a PASS/FAIL table from an actual run against the sandbox')" "yes" \
  "the reported fail-open ticket is now recognized"

# ── Negative direction: ordinary code tickets must NOT be swept into the validation gate,
# or every routine fix would park + escalate. These are the shapes most at risk.
assert_eq "$(yes_v '## #13 — Fix the null deref in the parser
**Severity:** Low
**Observed:** parser crashes on empty input.
**Done when:** it no longer crashes; a unit test covers it.')" "no" \
  "ordinary bugfix ticket is not a validation ticket"
assert_eq "$(yes_v '## #14 — Document the GOVERN_* knobs
**Done when:** every knob has a README entry.')" "no" \
  "ordinary docs ticket is not a validation ticket"
assert_eq "$(yes_v '## #15 — Refactor spawn-worker sizing
**Observed:** resolve_sizing is hard to follow; tests pass but the branches are tangled.')" "no" \
  "a ticket merely mentioning tests passing is not a validation ticket"

# ── Empty / absent block must not crash and must not match.
assert_eq "$(yes_v '')" "no" "empty ticket block does not match"

assert_done
