#!/usr/bin/env bash
# Locks in the retry policy in spawn-worker.sh AFTER automatic tier escalation was REMOVED.
#
# The classifier still runs and still names WHY the prior attempt failed. What changed is that no
# class buys a model any more: the tier a retry dispatches at is the tier the baseline chose, full
# stop. A `judgment` class moves EFFORT (a different, cheaper knob: more reasoning per turn inside
# the same model, same per-token price, same prompt-cache key), and `judgment` plus an unrecognized
# signature additionally surface a RE-SPECIFICATION request to the operator, on the doctrine that a
# scoped item failing on capability at the floor indicts the brief rather than the tier.
#
# SIZING PRECEDENCE IS PINNED HERE ON PURPOSE. This file's subject is the RETRY CLASSIFIER: what
# moves, given a failure signature. It needs a per-ticket BASELINE it can state exactly, and the
# ticket Model:/Effort: fields are the cheapest way to fix one. Those fields are inert in normal
# dispatch now, so `run()` sets GOVERN_MEASURED_SIZING=0 to select the legacy precedence
# deliberately. Two consequences worth knowing: every baseline below is a FIXTURE, not a claim about
# default behavior; and this file doubles as the regression test for that kill switch actually
# restoring the old path, and now also for the GOVERN_WORKER_ESCALATION_MODEL CAP, which applies to
# exactly that explicit-request path.
#
#   class      | evidence                                          | asserted response
#   -----------|---------------------------------------------------|---------------------------
#   infra      | GOVERN_RETRY_CLASS=infra (driver-declared)        | SAME tier + SAME effort
#   ci         | GOVERN_FIX_CI set, or history retryClass=ci       | SAME tier + SAME effort
#   budget     | history status=budget-exceeded                    | SAME tier + SAME effort
#   judgment   | history failed/parked WITH a PR (repos non-empty) | SAME tier, effort bumped, RESPEC
#   unknown    | anything else (timeout, no PR, no history)        | SAME tier + SAME effort, RESPEC
#
# Uses GOVERN_SPAWN_DRY_RUN=1 to short-circuit BEFORE worktree creation / worker launch — the seam
# calls the SAME resolve_sizing() the live spawn uses, so this observes the real decision. No auth,
# no claude binary, no state on disk beyond the tmp workspace.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt" "$TMP/hist"

cat > "$TMP/tickets.md" <<'EOF'
## #301 — sonnet/medium ticket
**Severity:** Medium
**Model:** sonnet
**Effort:** medium
Observed: standard search+edit ticket.
Done when: PR opens.

---

## #302 — opus ticket (top tier already)
**Severity:** High
**Model:** opus
Observed: the ticket itself asked for the top tier.
Done when: PR opens.

---

## #303 — haiku ticket, no Effort field
**Severity:** Low
**Model:** haiku
Observed: cheapest tier, effort left at the session default.
Done when: PR opens.

---

## #304 — no Model: field at all (the workspace floor decides)
**Severity:** Medium
Observed: used to prove the cap applies to explicit requests only, never to the floor.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Seed one cross-run history line (the ledger record() writes after each attempt).
hist() { # file ticket status [retryClass] [repos-json]
  jq -nc --argjson t "$2" --arg st "$3" --arg rc "${4:-}" --argjson rp "${5:-[]}" \
    '{ticket:$t, run:"run-prior", status:$st, ts:1, repos:$rp}
     + (if $rc == "" then {} else {retryClass:$rc} end)' >> "$1"
}

run() { # ticket force-retry [history-file] [worker-model] [worker-effort]
  local n="$1" force="$2" h="${3:-$TMP/hist/none.jsonl}" wm="${4:-opus}" we="${5:-}"
  GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs" \
    GOVERN_HISTORY_FILE="$h" \
    GOVERN_WORKER_MODEL="$wm" \
    GOVERN_WORKER_EFFORT="$we" \
    GOVERN_MEASURED_SIZING=0 \
    GOVERN_SPAWN_DRY_RUN=1 \
    GOVERN_SPAWN_FORCE_RETRY="$force" \
    "$SPAWN" "$n"
}
f() { printf '%s' "$1" | jq -r ".$2"; }   # field from a dry-run JSON line

# ── 1. FIRST attempt: the ticket's brain-decided fields win; no classification happens ───────────
o="$(run 301 0)"
assert_eq "$(f "$o" retry_class)" "first-attempt" "first attempt → retry_class=first-attempt"
assert_eq "$(f "$o" model)"  "sonnet" "first attempt honors Model: sonnet"
assert_eq "$(f "$o" effort)" "medium" "first attempt honors Effort: medium"

# ── 2. infra: gh/network/auth outage → retry IDENTICALLY ─────────────────────────────────────────
o="$(GOVERN_RETRY_CLASS=infra run 301 1)"
assert_eq "$(f "$o" retry_class)" "infra"  "driver-declared infra → retry_class=infra"
assert_eq "$(f "$o" model)"  "sonnet" "infra retry keeps the SAME tier (no escalation)"
assert_eq "$(f "$o" effort)" "medium" "infra retry keeps the SAME effort"

# ── 3. ci: this dispatch IS the CI-fix re-dispatch → SAME tier (the failing axis is CI, not tier) ─
o="$(GOVERN_FIX_CI="alpha#7" run 301 1)"
assert_eq "$(f "$o" retry_class)" "ci"     "GOVERN_FIX_CI set → retry_class=ci"
assert_eq "$(f "$o" model)"  "sonnet" "CI-fix re-dispatch keeps the SAME tier"
assert_eq "$(f "$o" effort)" "medium" "CI-fix re-dispatch keeps the SAME effort"

# ── 4. ci from the LEDGER: the prior attempt was parked because CI stayed red (driver-tagged) ────
H="$TMP/hist/ci.jsonl"; hist "$H" 301 failed ci '["alpha"]'
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "ci"     "history retryClass=ci → retry_class=ci"
assert_eq "$(f "$o" model)" "sonnet" "red-CI (portability/env) retry re-bets the SAME tier"

# ── 5. budget: burned the token budget while still exploring → SAME sizing (a tier is not scope) ─
H="$TMP/hist/budget.jsonl"; hist "$H" 301 budget-exceeded
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "budget" "history budget-exceeded → retry_class=budget"
assert_eq "$(f "$o" model)"  "sonnet" "budget retry does NOT raise the tier (automatic escalation removed)"
assert_eq "$(f "$o" effort)" "medium" "budget retry leaves effort unchanged too"
assert_eq "$(f "$o" respec_requested)" "false" "budget is a scope signal, not a capability failure, so no re-specification request"

# ── 6. judgment: a coherent but WRONG fix (PR opened, never landed) → EFFORT only, plus a RESPEC ─
H="$TMP/hist/judgment.jsonl"; hist "$H" 301 failed "" '["alpha"]'
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "judgment" "history failed WITH a PR → retry_class=judgment"
assert_eq "$(f "$o" model)"  "sonnet" "judgment retry does NOT raise the tier"
assert_eq "$(f "$o" effort)" "high" "judgment retry bumps effort one rung (medium to high): the cheap knob still moves"
assert_eq "$(f "$o" respec_requested)" "true"     "judgment retry surfaces a re-specification request"
assert_eq "$(f "$o" respec_class)"     "judgment" "the re-specification request names the class that caused it"

# ── 7. unknown: a verdict with NO PR is an unrecognized signature → hold at the floor, RESPEC ────
# This branch used to discard the ticket's fields and jump straight to the ceiling. Absence of
# evidence now routes DOWN, exactly like every other tier decision in the resolver.
H="$TMP/hist/nopr.jsonl"; hist "$H" 301 parked
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "unknown" "parked with no PR → retry_class=unknown"
assert_eq "$(f "$o" model)"  "sonnet" "unknown signature HOLDS at the baseline tier (never buys the ceiling)"
assert_eq "$(f "$o" effort)" "medium" "unknown signature KEEPS the ticket Effort: (no longer discarded)"
assert_eq "$(f "$o" respec_requested)" "true"    "unknown signature surfaces a re-specification request"
assert_eq "$(f "$o" respec_class)"     "unknown" "the request names the unrecognized class"

# ── 8. a wall-clock timeout is deliberately NOT a recognized signature → same fallback ───────────
H="$TMP/hist/timeout.jsonl"; hist "$H" 301 timeout
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "unknown" "timeout status → retry_class=unknown (documented fallback)"
assert_eq "$(f "$o" model)" "sonnet" "timeout retry holds the tier"

# ── 9. NO history at all → unknown → hold and surface ────────────────────────────────────────────
o="$(run 301 1)"
assert_eq "$(f "$o" retry_class)" "unknown" "no recorded evidence → retry_class=unknown"
assert_eq "$(f "$o" model)" "sonnet" "no-evidence retry holds the tier"
assert_eq "$(f "$o" respec_requested)" "true" "no-evidence retry surfaces rather than spends"

# ── 10. an UNRECOGNIZED GOVERN_RETRY_CLASS is never trusted — falls through to the evidence path ─
o="$(GOVERN_RETRY_CLASS=bogus run 301 1)"
assert_eq "$(f "$o" retry_class)" "unknown" "unknown GOVERN_RETRY_CLASS value is ignored (fail-safe)"
assert_eq "$(f "$o" model)" "sonnet" "unknown GOVERN_RETRY_CLASS holds the tier"

# ── 11. an explicit ticket request survives a retry untouched (nothing raises it, nothing drops it) ─
# The old NO-DOWNGRADE invariant tested that escalation could not drop a `Model: opus` ticket below
# the tier it asked for. There is no escalation left to down-grade anything, so what this now pins is
# the weaker and still-true property: a retry does not touch the tier in either direction.
H="$TMP/hist/downgrade.jsonl"; hist "$H" 302 budget-exceeded
o="$(run 302 1 "$H" sonnet)"
assert_eq "$(f "$o" retry_class)" "budget" "opus ticket + budget history → retry_class=budget"
assert_eq "$(f "$o" model)" "opus" "a retry leaves an explicit Model: opus request exactly where it was"

# ── 11b. THE CAP: GOVERN_WORKER_ESCALATION_MODEL bounds what an explicit request may ask for ─────
# It is no longer a destination anything escalates TO. It is the ceiling on the one explicit request
# in the system (the ticket `Model:` field, live only under GOVERN_MEASURED_SIZING=0), applied at
# resolve_sizing's single clamp site, not a fifth clamp beside the four selection paths.
o="$(GOVERN_WORKER_ESCALATION_MODEL=sonnet run 302 0 "$TMP/hist/none.jsonl" haiku)"
assert_eq "$(f "$o" model)" "sonnet" "an explicit Model: opus above the cap is clamped DOWN to the cap"
assert_contains "$(f "$o" model_source)" "capped to sonnet by GOVERN_WORKER_ESCALATION_MODEL" \
  "the cap is never silent: model_source names it"
assert_eq "$(f "$o" model_cap_source)" "worker-request-cap" "the record says WHICH ceiling bit"
o="$(GOVERN_WORKER_ESCALATION_MODEL=opus run 302 0)"
assert_eq "$(f "$o" model)" "opus" "an explicit request AT the cap passes through untouched"
assert_eq "$(f "$o" model_cap_source)" "" "no cap applied → no cap source recorded"
# The cap deliberately does NOT clamp the workspace FLOOR: setting GOVERN_WORKER_MODEL is configuring
# the harness directly, not asking it for something, and having one env var silently override
# another would make the floor knob lie about what it does.
o="$(GOVERN_WORKER_ESCALATION_MODEL=haiku run 304 0 "$TMP/hist/none.jsonl" opus)"
assert_eq "$(f "$o" model)" "opus" "the cap does NOT clamp the workspace floor (only explicit requests)"

# ── 12. infra/ci keep even the cheapest tier on a retry (positively identified non-model cause) ──
o="$(GOVERN_RETRY_CLASS=infra run 303 1)"
assert_eq "$(f "$o" model)" "haiku" "infra retry keeps even the cheapest tier (positively-identified cause)"
assert_eq "$(f "$o" respec_requested)" "false" "a positively identified infra cause is NOT a capability failure"

# ── 13. judgment from an UNSET effort lands on the ladder's first explicit rung ──────────────────
H="$TMP/hist/judgment-haiku.jsonl"; hist "$H" 303 parked "" '["alpha"]'
o="$(run 303 1 "$H")"
assert_eq "$(f "$o" retry_class)" "judgment" "parked WITH a PR → retry_class=judgment"
assert_eq "$(f "$o" model)"  "haiku" "judgment does NOT raise haiku to anything"
assert_eq "$(f "$o" effort)" "high" "judgment retry from unset effort lands on the first explicit rung"

# ── 14. judgment on a ticket already at the top tier: effort still moves, tier still does not ────
H="$TMP/hist/marginal.jsonl"; hist "$H" 302 failed "" '["alpha"]'
o="$(run 302 1 "$H" opus medium)"
assert_eq "$(f "$o" model)"  "opus" "judgment at the top tier stays at that tier"
assert_eq "$(f "$o" effort)" "high" "judgment raises EFFORT (medium → high) regardless of tier"

# ── 15. kill switch: GOVERN_RETRY_CLASSIFY=0 pins every retry to `unknown` ───────────────────────
# The classifier's own kill switch survives. What it restores is no longer a ceiling purchase (there
# is none): it pins the class to `unknown`, which now holds the tier and surfaces a respec request.
o="$(GOVERN_RETRY_CLASSIFY=0 run 301 1 "$TMP/hist/budget.jsonl")"
assert_eq "$(f "$o" retry_class)" "unknown" "GOVERN_RETRY_CLASSIFY=0 → classifier disabled"
assert_eq "$(f "$o" model)"  "sonnet" "disabled classifier still never raises the tier"
assert_eq "$(f "$o" effort)" "medium" "disabled classifier keeps the ticket Effort:"
assert_eq "$(f "$o" respec_requested)" "true" "disabled classifier routes to the unknown branch → respec"
o="$(GOVERN_RETRY_CLASSIFY=0 GOVERN_FIX_CI="alpha#7" run 301 1)"
assert_eq "$(f "$o" model)" "sonnet" "disabled classifier ignores the CI-fix signal, but still holds the tier"

# ── 16. every classification carries a human-readable reason, and the live path LOGS the decision ─
o="$(run 301 1 "$TMP/hist/budget.jsonl")"
[[ -n "$(f "$o" retry_reason)" ]] && printf 'ok   - %s\n' "classifier emits a reason string" \
  || { printf 'FAIL - classifier emits a reason string\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$(cat "$SPAWN")" 'retry-class=$retry_class — $retry_reason' \
  "live spawn logs the sizing decision AND its reason"

assert_done
