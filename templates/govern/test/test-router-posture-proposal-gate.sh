#!/usr/bin/env bash
# router-posture-guard.sh: the in-hook PROPOSAL GATE (header SEVENTH behavior) on a worker
# dispatch, specifically its multi-ticket CONTRACT clause -- the dispatch-packet prompt shape:
# "Resolve #12, #14. Read your packet at <path>/.dispatch-packet.md first and follow it."
#
# Single-number dispatch (today's behavior) is already covered incidentally by
# test-ticket-route-guard.sh's worker-branch cases; this file is scoped to what's NEW: when the
# prompt opens with the contract clause naming SEVERAL tickets, every one of them is gated, not
# just the first -- a batch worker with one proposed and one bare ticket must still refuse.
#
# Contract:
#   1. "Resolve #60." (single, contract-shaped) with a proposal on #60 -> proceeds untouched.
#   2. "Resolve #60, #61." with proposals on BOTH -> proceeds untouched.
#   3. "Resolve #60, #61." with a proposal on #60 but NOT #61 -> DENIED, naming #61.
#   4. "Resolve #60, #61." with a proposal on NEITHER -> DENIED, naming both.
#   5. A prompt that merely MENTIONS "resolve #60, #61" mid-sentence (not the anchored contract
#      clause) falls back to today's first-match-only behavior: gated on #60 alone.
#   6. GOVERN_PROPOSAL_GATE=0 bypasses the gate entirely, contract-shaped or not.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # scripts/lib/workspace.sh -> META_ROOT="$T"

mkdir -p "$T/hooks" "$T/queue" "$T/scripts/govern/lib"
cp "$GOVERN_HOOKS_DIR/router-posture-guard.sh" "$T/hooks/router-posture-guard.sh"
GUARD="$T/hooks/router-posture-guard.sh"

# The gate degrades to a silent no-op without a real ticket-proposal.sh + lib/common.sh at the
# resolved SELF_ROOT/scripts/govern/ path (SELF_ROOT = dirname($GUARD)/.. = $T here) -- copy the
# real ones in, the same dual-layout resolve as everywhere else in this suite: hub tree has
# govern/ as a SIBLING of hooks/ (templates/hooks, templates/govern); a scaffolded workspace has
# it as a CHILD (<root>/scripts, <root>/scripts/govern).
GOVERN_DIR="$(cd "$GOVERN_HOOKS_DIR/../govern" 2>/dev/null && pwd)"
[ -n "$GOVERN_DIR" ] || GOVERN_DIR="$(cd "$GOVERN_HOOKS_DIR/govern" 2>/dev/null && pwd)"
cp "$GOVERN_DIR/ticket-proposal.sh" "$T/scripts/govern/ticket-proposal.sh"
cp "$GOVERN_DIR/lib/common.sh" "$T/scripts/govern/lib/common.sh"

# #60: has a real proposal. #61: filing-time placeholder only (reads as no proposal, same as
# absent -- ticket-proposal.sh's own contract).
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — a real proposal

**Severity:** Low

Observed: something small in one file.
Done when: PR opens.

**Proposed solution:** Change the retry ladder to stop at three attempts instead of five.

**Precision:** scoped

---

## #61 — no proposal yet

**Severity:** Low

Observed: something small in another file.
Done when: PR opens.

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_
TIX

PL="$T/payload.json"
# Each case gets its own session_id: subagent_type "worker" counts against the worker fan-out
# advisory (a SEPARATE lever, header FIFTH behavior) on every call that ISN'T denied, and sharing
# one counter across cases would let that unrelated advisory bleed into this file's assertions.
payload() { # <prompt> <session_id>
  python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Agent",
    "transcript_path": "/tmp/fake-transcript.jsonl",
    "session_id": sys.argv[2],
    "tool_input": {"prompt": sys.argv[1], "description": "tickets", "subagent_type": "worker"},
}))
' "$1" "$2" > "$PL"
}

# ── 1. single-number contract clause, proposal present -> proceeds ──────────────────────────
payload "Resolve #60. Read your packet at $T/.dispatch-packet.md first and follow it." "pgate-1"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=1 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "1. single-number contract clause with a real proposal proceeds untouched"

# ── 2. multi-number contract clause, proposals on BOTH -> proceeds ──────────────────────────
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — a real proposal

**Proposed solution:** Change the retry ladder to stop at three attempts instead of five.
**Precision:** scoped

---

## #61 — also a real proposal

**Proposed solution:** Drop the retry cap on the sibling path too.
**Precision:** scoped
TIX
payload "Resolve #60, #61. Read your packet at $T/.dispatch-packet.md first and follow it." "pgate-2"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=1 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "2. multi-number contract clause with proposals on BOTH proceeds untouched"

# ── 3. multi-number contract clause, #61 has NO proposal -> DENIED, naming #61 ───────────────
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — a real proposal

**Proposed solution:** Change the retry ladder to stop at three attempts instead of five.
**Precision:** scoped

---

## #61 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_
TIX
payload "Resolve #60, #61. Read your packet at $T/.dispatch-packet.md first and follow it." "pgate-3"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=1 bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "3a. one ticket in the batch missing a proposal still DENIES the whole dispatch"
assert_contains "$out" "#61" "3b. the deny names the ticket that's actually missing a proposal"

# ── 4. multi-number contract clause, NEITHER has a proposal -> DENIED, naming both ──────────
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_

---

## #61 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_
TIX
payload "Resolve #60, #61. Read your packet at $T/.dispatch-packet.md first and follow it." "pgate-4"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=1 bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "4a. neither ticket in the batch has a proposal: DENIED"
assert_contains "$out" "#60" "4b. the deny names #60"
assert_contains "$out" "#61" "4c. the deny names #61 too"

# ── 5. NOT the anchored contract clause: mid-sentence mention gates on the first match only ──
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — a real proposal

**Proposed solution:** Change the retry ladder to stop at three attempts instead of five.
**Precision:** scoped

---

## #61 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
**Precision:** _(advisor: stated | scoped | open — filled at dispatch time)_
TIX
payload "Following up on the discussion, I'll resolve #60, #61 today; see notes." "pgate-5"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=1 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "5. a mid-sentence mention (not the anchored contract clause) gates on #60 alone, which has a proposal"

# ── 6. kill switch bypasses the gate regardless of contract shape ───────────────────────────
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #60 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_

---

## #61 — no proposal yet

**Proposed solution:** _(advisor: fill in before dispatch — filing is not specifying)_
TIX
payload "Resolve #60, #61. Read your packet at $T/.dispatch-packet.md first and follow it." "pgate-6"
out="$(env -u GOVERN_RUN GOVERN_PROPOSAL_GATE=0 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "6. GOVERN_PROPOSAL_GATE=0 bypasses the gate even on a fully-unproposed batch"

assert_done
