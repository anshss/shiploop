#!/usr/bin/env bash
# Locks in EVIDENCE-BASED retry escalation (retry-class) in spawn-worker.sh: a retry classifies the PRIOR
# attempt's failure signature and escalates the axis that actually failed, instead of always
# jumping to GOVERN_WORKER_MODEL and discarding the ticket's brain-decided Model:/Effort: fields.
#
#   class      | evidence                                          | asserted response
#   -----------|---------------------------------------------------|---------------------------
#   infra      | GOVERN_RETRY_CLASS=infra (driver-declared)        | SAME tier + SAME effort
#   ci         | GOVERN_FIX_CI set, or history retryClass=ci       | SAME tier + SAME effort
#   budget     | history status=budget-exceeded (#16)              | tier raised, effort unchanged
#   judgment   | history failed/parked WITH a PR (repos non-empty) | tier raised AND effort bumped
#   unknown    | anything else (timeout, no PR, no history)        | pre-classifier behavior, unchanged
#
# Plus the two safety invariants: an escalation never DOWN-grades below the tier the first attempt
# used, and an unrecognized GOVERN_RETRY_CLASS value is ignored (falls through to the evidence path).
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

# ── 2. infra: gh/network/auth outage → retry IDENTICALLY, do NOT escalate at all ─────────────────
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

# ── 5. budget: burned the token budget while still exploring → scope underestimated, raise TIER ──
H="$TMP/hist/budget.jsonl"; hist "$H" 301 budget-exceeded
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "budget" "history budget-exceeded → retry_class=budget"
assert_eq "$(f "$o" model)"  "opus"   "budget retry RAISES the tier"
assert_eq "$(f "$o" effort)" "medium" "budget retry leaves effort unchanged (tier is the failed axis)"

# ── 6. judgment: a coherent but WRONG fix (PR opened, never landed) → raise EFFORT and TIER ──────
H="$TMP/hist/judgment.jsonl"; hist "$H" 301 failed "" '["alpha"]'
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "judgment" "history failed WITH a PR → retry_class=judgment"
assert_eq "$(f "$o" model)"  "opus" "judgment retry raises the tier"
assert_eq "$(f "$o" effort)" "high" "judgment retry bumps effort one rung (medium → high)"

# ── 7. unknown: a verdict with NO PR is an unrecognized signature → pre-classifier behavior, unchanged ──
H="$TMP/hist/nopr.jsonl"; hist "$H" 301 parked
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "unknown" "parked with no PR → retry_class=unknown"
assert_eq "$(f "$o" model)"  "opus" "unknown signature escalates to GOVERN_WORKER_MODEL (as before the classifier)"
assert_eq "$(f "$o" effort)" ""     "unknown signature discards the ticket Effort: (as before the classifier)"

# ── 8. a wall-clock timeout is deliberately NOT a recognized signature → same fallback ───────────
H="$TMP/hist/timeout.jsonl"; hist "$H" 301 timeout
o="$(run 301 1 "$H")"
assert_eq "$(f "$o" retry_class)" "unknown" "timeout status → retry_class=unknown (documented fallback)"
assert_eq "$(f "$o" model)" "opus" "timeout retry escalates exactly as it did before the classifier"

# ── 9. NO history at all → unknown → today's escalate-to-GOVERN_WORKER_MODEL ─────────────────────
o="$(run 301 1)"
assert_eq "$(f "$o" retry_class)" "unknown" "no recorded evidence → retry_class=unknown"
assert_eq "$(f "$o" model)" "opus" "no-evidence retry escalates (regression guard for the pre-classifier rail)"

# ── 10. an UNRECOGNIZED GOVERN_RETRY_CLASS is never trusted — falls through to the evidence path ─
o="$(GOVERN_RETRY_CLASS=bogus run 301 1)"
assert_eq "$(f "$o" retry_class)" "unknown" "unknown GOVERN_RETRY_CLASS value is ignored (fail-safe)"
assert_eq "$(f "$o" model)" "opus" "unknown GOVERN_RETRY_CLASS still escalates as before"

# ── 11. NO-DOWNGRADE invariant: escalating never drops below the tier the first attempt used ─────
H="$TMP/hist/downgrade.jsonl"; hist "$H" 302 budget-exceeded
o="$(run 302 1 "$H" sonnet)"
assert_eq "$(f "$o" retry_class)" "budget" "opus ticket + budget history → retry_class=budget"
assert_eq "$(f "$o" model)" "opus" "escalation never down-grades a Model: opus ticket to a lower floor"

# ── 12. infra/ci are the ONLY classes allowed to keep a sub-floor tier on a retry ────────────────
o="$(GOVERN_RETRY_CLASS=infra run 303 1)"
assert_eq "$(f "$o" model)" "haiku" "infra retry keeps even the cheapest tier (positively-identified cause)"

# ── 13. judgment from an UNSET effort lands on the ladder's first explicit rung ──────────────────
H="$TMP/hist/judgment-haiku.jsonl"; hist "$H" 303 parked "" '["alpha"]'
o="$(run 303 1 "$H")"
assert_eq "$(f "$o" retry_class)" "judgment" "parked WITH a PR → retry_class=judgment"
assert_eq "$(f "$o" model)"  "opus" "judgment retry raises haiku → GOVERN_WORKER_MODEL"
assert_eq "$(f "$o" effort)" "high" "judgment retry from unset effort lands on the first explicit rung"

# ── 14. already at the floor tier: judgment escalates EFFORT (the cheaper knob) — tier can't move ─
H="$TMP/hist/marginal.jsonl"; hist "$H" 302 failed "" '["alpha"]'
o="$(run 302 1 "$H" opus medium)"
assert_eq "$(f "$o" model)"  "opus" "judgment at the floor tier stays at that tier"
assert_eq "$(f "$o" effort)" "high" "judgment at the floor tier raises EFFORT instead (medium → high)"

# ── 15. kill switch: GOVERN_RETRY_CLASSIFY=0 pins every retry back to the pre-classifier rail ──────────
o="$(GOVERN_RETRY_CLASSIFY=0 run 301 1 "$TMP/hist/budget.jsonl")"
assert_eq "$(f "$o" retry_class)" "unknown" "GOVERN_RETRY_CLASSIFY=0 → classifier disabled"
assert_eq "$(f "$o" model)"  "opus" "disabled classifier escalates to GOVERN_WORKER_MODEL"
assert_eq "$(f "$o" effort)" ""     "disabled classifier discards the ticket Effort: (pre-classifier rail)"
o="$(GOVERN_RETRY_CLASSIFY=0 GOVERN_FIX_CI="alpha#7" run 301 1)"
assert_eq "$(f "$o" model)" "opus" "disabled classifier ignores even the CI-fix signal"

# ── 16. every classification carries a human-readable reason, and the live path LOGS the decision ─
o="$(run 301 1 "$TMP/hist/budget.jsonl")"
[[ -n "$(f "$o" retry_reason)" ]] && printf 'ok   - %s\n' "classifier emits a reason string" \
  || { printf 'FAIL - classifier emits a reason string\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$(cat "$SPAWN")" 'retry-class=$retry_class — $retry_reason' \
  "live spawn logs the sizing decision AND its reason"

assert_done
