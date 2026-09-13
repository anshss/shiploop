#!/usr/bin/env bash
# A sonnet worker that reaches a decision it cannot make spawns ONE opus Agent with a scoped
# question... continues at sonnet. advisor-consult.sh is the thin CLI wrapper both worker lanes
# call into govern::advisor_* (lib/common.sh), same shape as
# gotchas-for-paths.sh/test-gotchas-for-paths.sh.
#
# Cases:
#   1. GOVERN_ADVISOR unset (default OFF) -> claim denies "disabled" and writes NOTHING: a true
#      no-op, not merely a denial.
#   2. GOVERN_ADVISOR=1, brand-new ticket, no pre-existing ledger -> claim ALLOWS (a missing ledger
#      file means zero used so far, never read as zero budget / an automatic deny).
#   3. Per-WORKER cap: GOVERN_ADVISOR_PER_WORKER=1 -> the 2nd claim on the SAME ticket denies
#      "worker-budget-exhausted", and the ledger (accumulated across both calls) proves it.
#   4. Per-SESSION cap: two DIFFERENT tickets sharing one GOVERN_ADVISOR_SESSION_KEY exhaust the
#      session cap before either hits its own per-worker cap.
#   5. No session key available -> degrades the per-session check to the per-worker cap (logged),
#      never silently unbounded.
#   6. GOVERN_ADVISOR_BUDGET (the worker's own precision-grade export) overrides
#      GOVERN_ADVISOR_PER_WORKER for that dispatch; set to 0 it denies immediately, and
#      when UNSET entirely (the interactive lane, which has no launcher and no grade) falls back to
#      the plain per-worker default rather than being permanently zero-budgeted.
#   7. An `allow` names NO model. Nothing ever spawns an advisor, so the response carries no model
#      field for anything to spawn FROM: an allow authorises asking the advisor session that wrote
#      the proposal; an unresolvable fork is an honest escalation instead. This case is a
#      REGRESSION test: it asserts the field's ABSENCE, so re-introducing it turns this red.
#   8. GOVERN_ADVISOR_MAX_TOKENS controls the returned per-consult token ceiling.
#   9. `record` closes the entry: the ledger's closing row carries the model/tokens/answer and the
#      budget state after.
#  10. Usage errors (no verb, bad ticket number, bad consultId) -> exit 2.
#
# `set -e` note: every call below that is EXPECTED to return nonzero (a deny, a usage error) is
# guarded as `rc=0; out="$(...)" || rc=$?`: a bare `cmd; rc=$?` would let the script's OWN
# `set -e` abort right there, since a failing command substitution assignment is NOT one of the
# errexit-exempt positions (that exemption only covers a command that is part of an && / || list,
# other than the one following the final operator).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SCRIPT="$DIR/../advisor-consult.sh"
[ -f "$SCRIPT" ] || { echo "SKIP: advisor-consult.sh not found at $SCRIPT" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP" "alpha"
ERR="$TMP/stderr.log"

run() { # <env=val ...> -- <script args...>. GOVERN_ADVISOR/GOVERN_ADVISOR_SESSION_KEY/
        # GOVERN_ADVISOR_BUDGET/CLAUDE_CODE_SESSION_ID unset by default for a hermetic per-call slate
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  # BSD `env` (macOS) stops parsing options at the first NAME=VALUE: every `-u` MUST precede all
  # assignments, unlike GNU env which tolerates either order.
  env -u CLAUDE_CODE_SESSION_ID -u GOVERN_ADVISOR_SESSION_KEY -u GOVERN_ADVISOR -u GOVERN_ADVISOR_BUDGET \
      GOVERN_WS_ROOT="$TMP" GOVERN_LOG_ROOT="$TMP/logs" \
      ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" 2>"$ERR"
}

LEDGER_701="$TMP/logs/ticket-701/advisor.jsonl"

# ── 1. kill switch default OFF -> deny "disabled", writes NOTHING ────────────────────────────────
rc=0; out="$(run -- claim 701)" || rc=$?
assert_eq "$rc" "1" "1a. claim denies (rc 1) when GOVERN_ADVISOR is unset"
assert_contains "$out" '"decision":"deny"' "1b. the decision is deny"
assert_contains "$out" '"reason":"disabled"' "1c. the reason names the kill switch"
if [[ ! -f "$LEDGER_701" ]]; then echo "ok   - 1d. no ledger file was written (a true no-op, not merely a denial)"
else echo "FAIL - 1d. ledger file was written despite the kill switch being off"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

# ── 2. brand-new ticket, GOVERN_ADVISOR=1 -> ALLOW (missing ledger != zero budget) ────────────────
rc=0; out="$(run GOVERN_ADVISOR=1 -- claim 701 --question "which retry class wins here?")" || rc=$?
assert_eq "$rc" "0" "2a. a first-ever claim on a ticket with no pre-existing ledger allows"
assert_contains "$out" '"decision":"allow"' "2b. the decision is allow"
assert_contains "$out" '"consultId":1' "2c. the first consult is numbered 1"
assert_contains "$(cat "$LEDGER_701")" '"event":"claim"' "2d. claim OPENED a ledger entry"
assert_contains "$(cat "$LEDGER_701")" 'which retry class wins here?' "2e. the question is recorded"

# ── 3. per-WORKER cap: GOVERN_ADVISOR_PER_WORKER=1 already used by case 2's claim ─────────────────
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_PER_WORKER=1 -- claim 701)" || rc=$?
assert_eq "$rc" "1" "3a. a 2nd claim over a per-worker cap of 1 denies"
assert_contains "$out" '"reason":"worker-budget-exhausted"' "3b. the reason names the exhausted worker cap"
assert_contains "$out" '"workerRemaining":0' "3c. workerRemaining reports 0"

# ── 4. per-SESSION cap across TWO DIFFERENT tickets sharing one session key ───────────────────────
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-A GOVERN_ADVISOR_PER_SESSION=1 GOVERN_ADVISOR_PER_WORKER=5 -- claim 710)" || rc=$?
assert_eq "$rc" "0" "4a. the first ticket in the session claims fine (well under its own per-worker cap)"
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-A GOVERN_ADVISOR_PER_SESSION=1 GOVERN_ADVISOR_PER_WORKER=5 -- claim 711)" || rc=$?
assert_eq "$rc" "1" "4b. a DIFFERENT ticket sharing the session key denies once the session cap is used"
assert_contains "$out" '"reason":"session-budget-exhausted"' "4c. the reason names the exhausted session cap, not the worker cap"
assert_contains "$out" '"workerRemaining":5' "4d. ticket #711's OWN worker budget is untouched (5 of 5)"

# ── 5. no session key available -> degrades to the per-worker cap, loudly ────────────────────────
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_PER_SESSION=1 GOVERN_ADVISOR_PER_WORKER=3 -- claim 720)" || rc=$?
assert_eq "$rc" "0" "5a. with no session key, a session cap of 1 does NOT deny a fresh ticket (degrades to the per-worker cap of 3, not the session cap)"
assert_contains "$(cat "$ERR")" "no session key available" "5b. the degrade is logged loudly, not silent"

# ── 6. GOVERN_ADVISOR_BUDGET overrides the per-worker default; 0 denies immediately ───────────────
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-B GOVERN_ADVISOR_BUDGET=0 -- claim 730)" || rc=$?
assert_eq "$rc" "1" "6a. GOVERN_ADVISOR_BUDGET=0 (the stated/scoped grade) denies on the very first claim"
assert_contains "$out" '"reason":"worker-budget-exhausted"' "6b. reported as the worker cap, correctly, since 0 remaining IS exhausted"
rc=0; out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-C -- claim 731)" || rc=$?
assert_eq "$rc" "0" \
  "6c. with GOVERN_ADVISOR_BUDGET unset entirely (the interactive lane: no launcher, no grade) claim still allows via the plain per-worker default"

# ── 7. an `allow` names no model at all: nothing ever spawns an advisor ──────────────────────────
out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-D -- claim 740)"
assert_contains "$out" '"decision":"allow"' "7a. the claim is allowed"
assert_not_contains "$out" 'advisorModel' \
  "7b. the allow response carries NO advisorModel: an allow authorises ASKING the advisor session, never spawning one"
assert_not_contains "$out" 'model' \
  "7c. no model field of any name -- there is nothing in the response for a worker to spawn a tier from"

# ── 8. GOVERN_ADVISOR_MAX_TOKENS controls the per-consult token ceiling ───────────────────────────
out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-F -- claim 750)"
assert_contains "$out" '"maxTokens":4000' "8a. the default per-consult token cap is 4000"
out="$(run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-G GOVERN_ADVISOR_MAX_TOKENS=1500 -- claim 751)"
assert_contains "$out" '"maxTokens":1500' "8b. GOVERN_ADVISOR_MAX_TOKENS overrides it"

# ── 9. record closes the entry with what came back ────────────────────────────────────────────────
run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-H -- claim 760 >/dev/null
run GOVERN_ADVISOR=1 GOVERN_ADVISOR_SESSION_KEY=SESS-H -- record 760 1 --model opus --tokens 1234 --answer "use govern::retry_class for this" >/dev/null
rec="$(jq -c 'select(.event=="record")' "$TMP/logs/ticket-760/advisor.jsonl")"
assert_contains "$rec" '"model":"opus"' "9a. the closing row records the model that answered"
assert_contains "$rec" '"tokens":1234' "9b. and the tokens used"
assert_contains "$rec" "use govern::retry_class for this" "9c. and the answer summary"
assert_contains "$rec" '"workerRemaining"' "9d. and the budget state after (consults emit events the dispatching side can read)"

# ── 10. usage errors ───────────────────────────────────────────────────────────────────────────
rc=0; run -- >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "2" "10a. no verb at all -> exit 2"
rc=0; run -- claim notanumber >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "2" "10b. a non-numeric ticket -> exit 2"
rc=0; run -- record 701 notanumber >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "2" "10c. a non-numeric consultId -> exit 2"

assert_done
