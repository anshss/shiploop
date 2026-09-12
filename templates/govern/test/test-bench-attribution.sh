#!/usr/bin/env bash
# bench: the two readers added when bench caught up with the four mechanisms that landed after
# 09ab731 -- per-attempt TIER ATTRIBUTION and ADVISOR CONSULT SPEND -- plus the run-less lever
# event census the interactive-lane watchdog feeds.
#
# `bench/fixtures/replay-attribution-fleet` (make-attribution-fixture.mjs):
#   run-...000000  ticket-801 fully-attributed ledger row + an attributable advisor ledger
#                  ticket-802 PRE-FIELD ledger row (keys absent) + an advisor ledger it shares with
#                             a second run, so that spend cannot be attributed
#                  ticket-803 ledger row carrying the keys as NULL
#                  ticket-804 no ledger at all
#   run-...000001  ticket-802 again
#   ticket-999     an advisor ledger for a ticket with no transcript anywhere
#   logs/govern/lever-events.jsonl  two run-less interactive-lane watchdog-kill rows
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-attribution-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-attribution-fleet"
j="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --json 2>&1)"
assert_eq "$?" "0" "--json exits 0 on the attribution fixture"
ta() { printf '%s' "$j" | jq -r ".tierAttribution.$1"; }
ad() { printf '%s' "$j" | jq -r ".advisorSpend.$1"; }

# ── 1. tier attribution: the ledger fields record_attempt() writes and replay used to discard ───
assert_eq "$(ta totalAttempts)" "5" "every attempt in the corpus is censused, like the outcome breakdown"
assert_eq "$(ta attributed)" "4" "four of them resolve to a ledger row"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.precision["stated x ticket-field"]')" "1" \
  "a graded ticket reports BOTH the grade and where the grade came from -- precision now drives tier selection"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.precision["scoped x inferred"]')" "1" \
  "a second grade/source pair is read off its own row, not collapsed into the first"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.modelSource["precision-grade"]')" "1" \
  "modelSource says WHY the tier was picked, which is the whole point of the section"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.modelSource["GOVERN_WORKER_MODEL"]')" "3" \
  "and the env-var default is counted separately from it"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.effort["high x precision-grade"]')" "1" \
  "effort is reported WITH its source, never as a bare level"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.respecRequested["true"]')" "1" \
  "a respec request is counted"

# ABSENT vs RECORDED-NULL. A ledger row written before a field existed must never read as though
# the harness had looked and found nothing: that would report a pre-8e4e807 corpus as fully graded.
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.precision["unrecorded x unrecorded"]')" "1" \
  "ticket-802's pre-field row buckets as unrecorded -- the key is not there at all"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.precision["none x none"]')" "1" \
  "ticket-803's explicit nulls bucket as none -- a DIFFERENT fact, never merged with unrecorded"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.respecRequested["unrecorded"]')" "1" \
  "the same distinction holds for a boolean field: absent is not false"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.precision["unrecorded x unrecorded"] != null and (.tierAttribution.precision | has("0")) == false')" "true" \
  "an absent field is never counted as a zero"

# Unattributed carries its reason, exactly like outcomeBreakdown's unclassified bucket.
assert_eq "$(ta 'unattributed.attempts')" "1" "ticket-804 has no attempts.jsonl, so its attempt is unattributed"
assert_eq "$(printf '%s' "$j" | jq -r '.tierAttribution.unattributed.reasons["no-ledger"]')" "1" \
  "and the reason is named, not silently dropped"
assert_eq "$(printf '%s' "$j" | jq -r '(.tierAttribution.attributed + .tierAttribution.unattributed.attempts) == .tierAttribution.totalAttempts')" "true" \
  "every attempt lands in exactly one of attributed / unattributed"
assert_eq "$(printf '%s' "$j" | jq -r '([.tierAttribution.modelSource[]] | add) == .tierAttribution.attributed')" "true" \
  "and every attributed attempt contributes exactly one count to each distribution"

# Scope-independent, like the outcome census: it describes attempts, not the headline.
res="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m --scope resolved --json 2>&1)"
assert_eq "$(printf '%s' "$res" | jq -r '.tierAttribution.totalAttempts')" "$(ta totalAttempts)" \
  "the attribution census does not move with --scope"

# ── 2. advisor consult spend: real tokens on a dispatch, in no transcript bench walks ───────────
assert_eq "$(ad present)" "true" "the flat per-ticket advisor.jsonl ledger is found and read"
assert_eq "$(ad consults)" "3" "every record row in the corpus is counted"
assert_eq "$(ad tokens)" "5500" "the ledger's own token figures, summed, not re-derived"
# 4000 opus tokens at the opus OUTPUT rate ($25/M) = $0.10. Priced through the same RATES/tierOf()
# the rest of the report uses; the OUTPUT rate is the stated upper bound (the ledger carries one
# combined figure, so there is no split to price properly), and over-stating a shiploop-side cost
# is the conservative direction.
assert_eq "$(printf '%s' "$j" | jq -r '.advisorSpend.attributed.costUsd')" "0.1" \
  "an attributable consult is priced at its answering tier's output rate"
assert_contains "$(ad pricing)" "UPPER bound" "and the report states that the price is an upper bound"

# Attribution: the ledger is FLAT and names a ticket only, so anything ambiguous says so rather
# than being charged to a run that may not have spent it.
assert_eq "$(printf '%s' "$j" | jq -r '.advisorSpend.attributed.consults')" "1" \
  "only the consult whose ticket appears in exactly one run is attributed"
assert_eq "$(printf '%s' "$j" | jq -r '.advisorSpend.unattributed.reasons["ticket-in-multiple-runs"]')" "1" \
  "a ticket that ran in two runs is UNATTRIBUTED with that reason, never assigned to one of them"
assert_eq "$(printf '%s' "$j" | jq -r '.advisorSpend.unattributed.reasons["ticket-not-in-corpus"]')" "1" \
  "and a consult for a ticket with no transcript here is named rather than dropped"
assert_eq "$(printf '%s' "$j" | jq -r '(.advisorSpend.attributed.tokens + .advisorSpend.unattributed.tokens) == .advisorSpend.tokens')" "true" \
  "attributed + unattributed is the whole spend: nothing is lost between the two"

# Charged INTO the shiploop arm and taken back out of vanilla, exactly like harness-overhead.
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].levers["advisor-consult"].tokens')" "-4000" \
  "the advisor-consult lever is negative by construction: a vanilla session buys no second opinion"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].levers["advisor-consult"].status')" "measured" \
  "a corpus WITH an advisor ledger reports the lever as measured"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].levers["advisor-consult"].n')" "1" \
  "only attributed consults are charged to an arm"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms[].leverSumCheck | .tokens and .cost and .quotaWeighted] | all')" "true" \
  "and the lever components still sum to the arm saving with the new term in them"
assert_eq "$(printf '%s' "$j" | jq -r '[.arms["1m"].shiploopBreakdown[]] | add')" \
  "$(printf '%s' "$j" | jq -r '.arms["1m"].shiploopTokens')" \
  "advisor tokens are in the shiploop breakdown too, so the four parts still sum to the total"

# A corpus with NO advisor ledger is UNINSTRUMENTED, never a measured zero -- GOVERN_ADVISOR ships
# off, so that is the expected state and must not read as "the advisor costs nothing".
o="$(node "$HUB/bench/replay.mjs" --fleet "$HUB/bench/fixtures/replay-outcome-fleet" --arm 1m --json 2>&1)"
assert_eq "$(printf '%s' "$o" | jq -r '.advisorSpend.present')" "false" \
  "a corpus with no advisor.jsonl anywhere reports present:false"
assert_eq "$(printf '%s' "$o" | jq -r '.arms["1m"].levers["advisor-consult"].status')" "uninstrumented" \
  "and its lever is uninstrumented, NOT a measured zero"

# ── 3. run-less lever events: the interactive lane's watchdog-kill rows ─────────────────────────
# agent-watchdog-guard.sh runs inside a live session with no GOVERN_RUN_DIR, so its events land at
# logs/govern/lever-events.jsonl, flat. Counted so the lane is visible; credited to no arm, because
# every event-derived lever is credited per RUN and these rows name none.
assert_eq "$(printf '%s' "$j" | jq -r '.instrumentation.unscoped.present')" "true" \
  "the flat lever-events.jsonl is read"
assert_eq "$(printf '%s' "$j" | jq -r '.instrumentation.unscoped.byEvent["watchdog-kill"]')" "2" \
  "and its watchdog-kill rows are counted by event name"
assert_eq "$(printf '%s' "$j" | jq -r '.instrumentation.unscoped.credited')" "false" \
  "explicitly uncredited: a run-less event is never attached to an arbitrary run"
assert_eq "$(printf '%s' "$j" | jq -r '.arms["1m"].levers["watchdog"].n')" "0" \
  "so the watchdog lever earns nothing from them -- counted is not credited"

txt="$(node "$HUB/bench/replay.mjs" --fleet "$FLEET" --arm 1m 2>&1)"
assert_contains "$txt" "RUN-LESS lever event" "the human-readable report discloses them too, not just the JSON"
assert_contains "$txt" "advisor consults:" "and advisor spend gets its own visible line, never folded into a total"
assert_contains "$txt" "tier attribution" "and the attribution census is printed beside the outcome census"

assert_done
