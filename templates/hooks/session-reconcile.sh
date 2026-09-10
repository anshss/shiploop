#!/usr/bin/env bash
# SessionStart hook — close the escalation lifecycle for a plain interactive session (shiploop
# 1.19.2, the loop purge).
#
# escalations-apply-answers.sh (un-park / migrate-to-parked / mitigated / kill / rules an answered
# escalation, commits + pushes) and escalations-emit-pending.sh (regenerate
# governor/pending-escalations.json against the current escalations.md ## Open) used to run only
# at run-start/run-end inside the autonomous dispatch loop (since retired). A plain interactive
# session that never touched that loop never saw an operator's recorded answer take effect,
# and never got a fresh pending-escalations.json either. Both are durable-file operations with
# nothing loop-specific about them — wiring them here just runs them at the moment a session
# actually exists to read the result.
#
# Fail-open + quiet on the common case: prints nothing when there is nothing to apply and no
# escalation is awaiting an answer. Both scripts are also runnable by hand:
#   npm run govern:escalations-apply
#   npm run govern:escalations-emit
#
# Kill switch: GOVERN_SESSION_RECONCILE=0.
set -uo pipefail

# Never fire inside a governor worker (its own prompt forbids touching escalations.md) or a
# sub-agent (its transcript is throwaway; a SessionStart hook only fires for the top-level
# session anyway, but the same GOVERN_RUN exemption every other hook here uses costs nothing).
[ -n "${GOVERN_RUN:-}" ] && exit 0
[ "${GOVERN_SESSION_RECONCILE:-1}" != "0" ] || exit 0

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$SELF_ROOT/scripts/govern/escalations-apply-answers.sh"
EMIT="$SELF_ROOT/scripts/govern/escalations-emit-pending.sh"
[ -f "$APPLY" ] && [ -f "$EMIT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

apply_out="$(bash "$APPLY" 2>/dev/null || true)"
emit_out="$(bash "$EMIT" 2>/dev/null || true)"

note=""
case "$apply_out" in
  ""|"no escalations file"*|"no open escalations"*) : ;;
  *)
    # Any nonzero count in the summary line ("un-parked N, deferred N, ...") means something
    # actually happened — a plain "un-parked 0, deferred 0, ..." line is the no-op shape and
    # stays silent. Checking for ANY digit 1-9 (rather than matching the exact wording) survives
    # a future rewording of that summary line.
    if printf '%s' "$apply_out" | grep -qE '[1-9]'; then
      note="$apply_out"
    fi
    ;;
esac

case "$emit_out" in
  ""|0) : ;;
  *[!0-9]*) : ;;   # not a bare count (unexpected shape) — say nothing rather than guess
  *) note="${note:+$note }$emit_out escalation(s) awaiting an operator answer — see governor/pending-escalations.json" ;;
esac

[ -n "$note" ] || exit 0
printf -- '── escalation reconcile ──\n%s\n' "$note"
exit 0
