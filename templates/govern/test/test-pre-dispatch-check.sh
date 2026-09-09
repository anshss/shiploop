#!/usr/bin/env bash
# pre-dispatch-check.sh — the pre-spawn gates, as one entry point (shiploop 1.19.3, the loop purge).
#
# The gates are FAIL-OPEN by construction: a false "skip"/"refuse" silently drops real work, so only
# positive evidence may withhold a dispatch. These assertions pin that posture, not the individual
# gate logic (each gate keeps its own dedicated test).
#
#   1. an ordinary open ticket verdicts "proceed".
#   2. an NA-marked ticket verdicts "skip: ..." (positive evidence, so withholding is allowed).
#   3. exactly ONE line of verdict on stdout, always (the caller parses it).
#   4. GOVERN_PRE_DISPATCH_CHECK=0 forces "proceed".
#   5. an unknown ticket number does not refuse work: fail-open to "proceed".
#   6. the depends-on gate: an item whose **Depends on:** blocker is still in the queue skips, and
#      the blocker itself still proceeds.
#   7. the failure-streak breaker (#60, ported from the deleted run-loop.sh): GOVERN_MAX_TICKET_FAILS
#      consecutive failed/timeout/budget-exceeded/early-abort outcomes in ticket-history.jsonl skip
#      the dispatch and file ONE systemic-blocker escalation. A history whose trailing outcome is
#      resolved (or that has no history at all) never trips it, and a resolved outcome RESETS the
#      streak. This is the gate with no successor anywhere else: an item that fails CLEANLY every
#      attempt (worker converges, opens a PR, CI never passes) trips none of spawn-worker's live
#      early-abort signals, so without this it burns a fresh worker forever with no operator signal.
#   8. cross-driver re-verify: an item another session already resolved and PUSHED is gone from
#      origin/main, so this session skips it instead of burning a second worker on answered work.
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
# Tickets

## #50 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.

---

## #51 — ops: rotate the provider credential by hand in the console

**Severity:** Low

**NOT govern-automatable:** requires a human in a third-party console; no API exists.

Done when: rotated.

---

## #52, frontend: use the new retry ladder

**Severity:** Low

**Depends on:** #50

Done when: the frontend stops at three too.
TIX
( cd "$T" && git add -A && git commit -qm init )

run_pdc() { ( cd "$T" && bash "$PDC" "$1" 2>/dev/null ); }

out50="$(run_pdc 50)"
assert_contains "$out50" "proceed" "1. an ordinary open ticket verdicts proceed"
assert_eq "$(printf '%s\n' "$out50" | grep -c .)" "1" "3. the verdict is exactly one line"

out51="$(run_pdc 51)"
assert_contains "$out51" "skip" "2. an NA-marked ticket verdicts skip"

outk="$( cd "$T" && GOVERN_PRE_DISPATCH_CHECK=0 bash "$PDC" 51 2>/dev/null )"
assert_eq "$outk" "proceed" "4. GOVERN_PRE_DISPATCH_CHECK=0 forces proceed"

out99="$(run_pdc 99)"
assert_contains "$out99" "proceed" "5. an unknown ticket fails OPEN (never silently drops work)"

# ── 6. the depends-on gate ───────────────────────────────────────────────────────────────────────
out52="$(run_pdc 52)"
assert_contains "$out52" "skip" "6. an item whose Depends on: blocker is still queued skips"
assert_contains "$out52" "#50"  "6. ...and the skip names the unmet blocker"
assert_contains "$out50" "proceed" "6. ...while the blocker itself still dispatches"

# ── 7. the failure-streak breaker (#60) ──────────────────────────────────────────────────────────
# The counter's only input is governor/ticket-history.jsonl, written by resolve-ticket.sh and by
# spawn-worker's own ledger. Drive it to threshold with real rows and assert the gate fires; then
# prove a clean history (and a streak a `resolved` outcome broke) does NOT withhold a dispatch.
HIST="$T/hist.jsonl"
mkdir -p "$T/governor"
esc_count() { grep -c '^### #50 ' "$T/governor/escalations.md" 2>/dev/null | tr -d ' '; }
run_streak() { ( cd "$T" && GOVERN_HISTORY_FILE="$HIST" GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md"                   bash "$PDC" 50 2>/dev/null ); }

printf '## Open

## Resolved
' > "$T/governor/escalations.md"
: > "$HIST"
assert_contains "$(run_streak)" "proceed" "7. an EMPTY history never withholds a dispatch (fail-open)"

printf '{"ticket":50,"run":"r1","status":"failed","ts":1}
' > "$HIST"
assert_contains "$(run_streak)" "proceed" "7. ONE failure is below GOVERN_MAX_TICKET_FAILS=2, so it still dispatches"

# Two consecutive failures = the default threshold.
printf '{"ticket":50,"run":"r1","status":"failed","ts":1}
{"ticket":50,"run":"r2","status":"timeout","ts":2}
' > "$HIST"
out_streak="$(run_streak)"
assert_contains "$out_streak" "skip" "7. two consecutive failed/timeout outcomes skip the dispatch (#60)"
assert_contains "$out_streak" "systemic blocker" "7. ...and the verdict says WHY (systemic blocker, not another retry)"
assert_eq "$(printf '%s
' "$out_streak" | grep -c .)" "1" "7. the streak verdict is still exactly one line"
assert_eq "$(esc_count)" "1" "7. exactly ONE systemic-blocker escalation is filed for the streak"
# Re-running must not file a SECOND escalation while the first is still open.
run_streak >/dev/null
assert_eq "$(esc_count)" "1" "7. a second dispatch attempt does not re-file the escalation"

# A `resolved` outcome AFTER the failures breaks the streak: the item is workable again.
printf '## Open

## Resolved
' > "$T/governor/escalations.md"
printf '{"ticket":50,"run":"r1","status":"failed","ts":1}
{"ticket":50,"run":"r2","status":"timeout","ts":2}
{"ticket":50,"run":"r3","status":"resolved","ts":3}
' > "$HIST"
assert_contains "$(run_streak)" "proceed" "7. a resolved outcome RESETS the streak (trailing-only, never a lifetime tally)"

# Another ticket's failures never count against this one.
printf '{"ticket":7,"run":"r1","status":"failed","ts":1}
{"ticket":7,"run":"r2","status":"failed","ts":2}
' > "$HIST"
assert_contains "$(run_streak)" "proceed" "7. the streak is keyed PER ITEM (another item's failures do not block this one)"

# ── 8. cross-driver re-verify against origin/main ────────────────────────────────────────────────
# A concurrent session (or a different machine) may have resolved and pushed the item between the
# moment it was picked and the moment a worker would be spawned. Positive evidence that it is GONE
# from origin/main withholds the dispatch; anything inconclusive (no remote, fetch fails, file
# missing) fails OPEN, which is what every other case in this file already exercises.
X="$(mktemp -d)"; trap 'rm -rf "$T" "$X"' EXIT
git init -q --bare "$X/origin.git"
mkdir -p "$X/ws/queue"
( cd "$X/ws" && git init -q && git config user.email t@t && git config user.name t
  printf '# Tickets

## #60, only on this checkout

**Severity:** Low

Done when: done.
' > queue/tickets.md
  git add -A && git commit -qm "local only" >/dev/null
  git remote add origin "$X/origin.git"
  # origin/main deliberately does NOT carry #60: publish an EMPTY queue file as main.
  printf '# Tickets
' > queue/tickets.md
  git add -A && git commit -qm "published without it" >/dev/null
  git branch -M main >/dev/null 2>&1 || true
  git push -q origin main
  # Put the item BACK in the working checkout only, so local says "open" and origin says "gone".
  printf '# Tickets

## #60, only on this checkout

**Severity:** Low

Done when: done.
' > queue/tickets.md
  git add -A && git commit -qm "restore locally" >/dev/null ) >/dev/null 2>&1

out60="$( cd "$X/ws" && GOVERN_QUEUE_DIR="$X/ws/queue" GOVERN_NO_PUSH=0 bash "$PDC" 60 2>/dev/null )"
assert_contains "$out60" "skip" "8. an item no longer on origin/main is skipped (a peer already landed it)"
assert_contains "$out60" "origin/main" "8. ...and the verdict says so"

assert_done
