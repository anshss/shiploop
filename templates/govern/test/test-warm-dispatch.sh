#!/usr/bin/env bash
# Locks in the warm-parent dispatch branch: not every ticket earns a full-autonomy worker.
#
# Why it exists: dispatch was UNCONDITIONAL — every ticket got a fresh headless worker that
# re-derived the codebase from scratch no matter what the parent session already knew. The
# criterion for spawning at all is that the side task would flood the parent with output it will
# never reference again; when the parent already HOLDS the context, the spawn buys nothing and pays
# a cold start.
#
# The dangerous direction is a FALSE POSITIVE: an execute-only worker faithfully implements whatever
# it is told, so a branch taken by accident lands a wrong change confidently. Hence the assertion is
# explicit, per-invocation, and scoped to exactly one ticket number — never inferred. Most of the
# cases below assert that the branch is NOT taken.
#
# Cases:
#   1. No GOVERN_WARM → dispatch is byte-identical to before (no brief, normal tier).
#   2. GOVERN_WARM naming a DIFFERENT ticket → not taken (scoping is by exact ticket number).
#   3. Malformed GOVERN_WARM (no `|`, non-numeric ticket) → ignored, dispatch continues normally.
#   4. GOVERN_EXECUTE_ONLY=0 → branch hard-disabled even with a well-formed assertion.
#   5. A matching assertion → the brief reaches the worker prompt AND carries the mismatch-stop
#      instruction (the entire safety property of this branch).
#   6. A matching assertion → the worker runs at the cheapest EXISTING tier, from the existing
#      coarse set — never a newly minted (model, effort) pair.
#   7. A retry overrides the cheap execute-only tier (a failed cheap bet is never re-bet).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #601 — the ticket the parent is warm on
**Severity:** Medium
Observed: something small in one file.
Done when: PR opens.

---

## #602 — an unrelated ticket
**Severity:** Medium
Observed: something else entirely.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

BRIEF='I read templates/govern/spawn-worker.sh this session. Change resolve_sizing so the measured verdict wins; the latch is the TICKET_MODEL block.'

# Two observation seams, both short-circuiting before any worktree or worker:
#   dry()    → the resolved dispatch FLAGS as JSON (model/effort/source)
#   prompt() → the fully assembled worker prompt
# Assignments are passed as an ARRAY, never a word-split string: a stated change contains spaces,
# and splitting it would silently truncate the very value under test.
_base() { # <logtag>
  BASE_ENV=(
    "GOVERN_TICKETS_FILE=$TMP/tickets.md"
    "GOVERN_PREFERENCES_FILE=$TMP/governor/preferences.md"
    "GOVERN_WORKER_PROMPT_FILE=$TMP/governor/worker-prompt.md"
    "GOVERN_LOG_ROOT=$TMP/logs-$1"
    "GOVERN_WORKER_MODEL=opus"
  )
}
dry() { # <ticket> <logtag> [extra env assignments...]
  local n="$1"; _base "$2"; shift 2
  env "${BASE_ENV[@]}" "$@" GOVERN_SPAWN_DRY_RUN=1 "$SPAWN" "$n"
}
render() { # <ticket> <logtag> [extra env assignments...]
  local n="$1"; _base "$2"; shift 2
  env "${BASE_ENV[@]}" "$@" GOVERN_SPAWN_PRINT_PROMPT=1 "$SPAWN" "$n"
}
assert_lacks() { # <text> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then
    printf 'FAIL - %s\n       unexpectedly present: %s\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# ── The branch must NOT be taken (the direction that costs a wrong change if it regresses) ──

# 1. No assertion at all → today's behavior exactly.
p1="$(render 601 no-warm)"
assert_lacks "$p1" "EXECUTE-ONLY" "no GOVERN_WARM → no execute-only brief in the prompt"
assert_eq "$(dry 601 no-warm-dry | jq -r '.model')" "opus" \
  "no GOVERN_WARM → the normal tier, unchanged"

# 2. Assertion scoped to a DIFFERENT ticket → not taken. Scoping is by exact ticket number, so a
# warm assertion can never leak onto the next ticket the driver happens to pick up.
p2="$(render 602 other-ticket "GOVERN_WARM=601|$BRIEF")"
assert_lacks "$p2" "EXECUTE-ONLY" "assertion naming #601 does NOT apply to #602"
assert_eq "$(dry 602 other-ticket-dry "GOVERN_WARM=601|$BRIEF" | jq -r '.model')" "opus" \
  "a non-matching assertion leaves #602's tier untouched"

# 3. Malformed values are IGNORED, not guessed at — the branch is never taken by accident.
p3a="$(render 601 malformed-nopipe "GOVERN_WARM=just some prose with no pipe")"
assert_lacks "$p3a" "EXECUTE-ONLY" "GOVERN_WARM with no '|' separator → ignored"
p3b="$(render 601 malformed-noticket "GOVERN_WARM=notanumber|$BRIEF")"
assert_lacks "$p3b" "EXECUTE-ONLY" "GOVERN_WARM with a non-numeric ticket → ignored"

# 4. Fleet-wide kill switch beats a well-formed assertion.
p4="$(render 601 killswitch "GOVERN_WARM=601|$BRIEF" "GOVERN_EXECUTE_ONLY=0")"
assert_lacks "$p4" "EXECUTE-ONLY" "GOVERN_EXECUTE_ONLY=0 → branch disabled even with a valid assertion"
assert_eq "$(dry 601 killswitch-dry "GOVERN_WARM=601|$BRIEF" "GOVERN_EXECUTE_ONLY=0" | jq -r '.model')" "opus" \
  "GOVERN_EXECUTE_ONLY=0 → tier is the normal one"

# ── The branch IS taken, and carries its safety property ──

# 5. The brief reaches the worker, WITH the mismatch-stop. A warm parent can be stale or simply
# wrong; a cold worker re-derives and catches that, an execute-only worker does not. The instruction
# to stop and report on a mismatch is what makes this branch safe — assert it explicitly.
p5="$(render 601 warm "GOVERN_WARM=601|$BRIEF")"
assert_contains "$p5" "EXECUTE-ONLY" "a matching assertion → the execute-only block is appended"
assert_contains "$p5" "resolve_sizing so the measured verdict wins" \
  "the parent's stated change reaches the worker verbatim"
assert_contains "$p5" "BELIEF, not a fact" \
  "the brief presents the assertion as falsifiable, not as a command"
assert_contains "$p5" "STOP" \
  "the brief carries the mismatch-stop instruction"
assert_contains "$p5" "newTickets" \
  "the brief tells the worker to route adjacent findings to newTickets, not widen the diff"

# 6. Cheaper tier — from the EXISTING coarse set. A new (model, effort) pair here would re-fragment
# the cross-worker prompt cache the coarse set exists to protect.
d6="$(dry 601 warm-dry "GOVERN_WARM=601|$BRIEF")"
assert_eq "$(printf '%s' "$d6" | jq -r '.model')" "haiku" \
  "execute-only dispatch drops to the cheapest existing model tier"
assert_eq "$(printf '%s' "$d6" | jq -r '.effort')" "low" \
  "execute-only dispatch drops to the cheapest existing effort tier"
assert_contains "$(printf '%s' "$d6" | jq -r '.model_source')" "execute-only" \
  "the dispatch record names execute-only as the reason for the tier"

# 7. A RETRY is never re-bet at the cheap tier — the escalation ladder still owns a second attempt.
d7="$(dry 601 warm-retry "GOVERN_WARM=601|$BRIEF" "GOVERN_SPAWN_FORCE_RETRY=1")"
assert_eq "$(printf '%s' "$d7" | jq -r '.is_retry')" "1" "the retry path is actually exercised"
assert_eq "$(printf '%s' "$d7" | jq -r '.model')" "opus" \
  "a retry escalates off the execute-only cheap tier (a failed cheap bet is never re-bet)"

assert_done
