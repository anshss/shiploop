#!/usr/bin/env bash
# pre-dispatch-check.sh — ONE entry point for the pre-spawn gates a session should run BEFORE
# dispatching a worker on ticket N (shiploop 1.19.2, the loop purge).
#
# Before this script, these gates only ran inside the autonomous loop's dispatch path
# (run-loop.sh), so a plain interactive session dispatching a worker directly (or via
# `Agent(subagent_type: "worker")`) skipped every one of them. Every gate below reuses the
# existing implementation verbatim — never reimplemented — so the SAME gate that would have
# skipped/refused a ticket under the loop skips/refuses it here too.
#
# Usage:  pre-dispatch-check.sh <N>
# Verdict on stdout, exactly one line, one of:
#   proceed                — every gate passed (or was inconclusive); dispatch a worker.
#   skip: <reason>         — this ticket needs no worker right now (NA-marked, already a public
#                            issue, no longer on origin/main, an unmet dependency, or confidently
#                            stale). Not an error.
#   refuse: <reason>       — the upstream-drift pregate found the hub is ahead on a file this
#                            ticket targets; port the diff down instead of spawning a fresh-fix
#                            worker.
# Exit code is always 0 unless the invocation itself is malformed or a required tool is missing —
# the verdict text on stdout is what a caller branches on, not the exit code. Every gate here is
# fail-open by construction (an inconclusive check always resolves to "proceed"), matching the
# loop's own posture: a false "skip"/"refuse" silently drops real work, so only POSITIVE evidence
# ever short-circuits dispatch.
#
# Gates, in the same order the loop ran them, same helper functions, same env vars:
#   0. disk pre-flight           (GOVERN_MIN_FREE_GB, default 5GB), a full disk must not
#                                 masquerade as a worker failure
#   1. NA-marker auto-skip       (govern::not_automatable_tickets), plus the chronic-skip streak
#                                 bump and its one-time permanent-park escalation
#   2. already-a-public-issue    (govern::tickets_already_issues,
#                                 GOVERN_SKIP_ISSUE_TICKETS, default on)
#   3. cross-driver re-verify    (govern::ticket_present_on_origin) still on origin/main?
#   4. depends-on gate           (govern::ticket_deps) every **Depends on:** #K landed?
#   5. staleness gate            (staleness-gate.sh; GOVERN_STALENESS_GATE=0 by default, ships
#                                 inert, the same default the loop shipped)
#   6. failure-streak breaker    (GOVERN_MAX_TICKET_FAILS default 2) an item that failed /
#                                 timed out / blew its budget on the last N attempts is escalated
#                                 as a systemic blocker instead of burning another worker
#   7. proposed-solution gate    (govern::ticket_proposal) refuses a ticket with no **Proposed
#                                 solution:**; the advisor must decide what the change is before
#                                 dispatching a worker on it. Ships ON, GOVERN_PROPOSAL_GATE=0 is
#                                 the kill switch. THIS GATE APPLIES ONLY TO A NUMBERED-TICKET
#                                 WORKER DISPATCH (this script's one and only input is a ticket
#                                 number): it is never in the path of an advisor's own read-only
#                                 data-collection child: that child is spawned directly, is not
#                                 "dispatching a worker on ticket N", and so never calls this
#                                 script at all. Nothing here needs to distinguish the two; the
#                                 non-overlap is structural, not a runtime check.
#   8. upstream-drift pregate    (govern::pregate_hub_ahead, lib/pregate.sh)
#   9. overlap nudge             (govern::overlap_nudge) advisory only, stderr, never a verdict
#
# NOT ported here (deliberately out of scope): the per-ticket CLAIM lock and the "resume an existing
# open PR" adoption, both loop-only machinery per the purge audit. A concurrent-dispatch race is now
# the same shape as any other concurrent-session race the BK_LOCK/CAS protocol already serializes at
# LAND time.
#
# Kill switch: GOVERN_PRE_DISPATCH_CHECK=0 prints "proceed" unconditionally.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "usage: pre-dispatch-check.sh <ticket-number>"

if [[ "${GOVERN_PRE_DISPATCH_CHECK:-1}" == "0" ]]; then
  echo "proceed"
  exit 0
fi

# ── 0. disk pre-flight (ported from run-loop.sh) ─────────────────────────────────────────────
# Never let a full disk cascade into phantom worker failures: below the worktree headroom, refuse
# the dispatch with a distinct reason instead of spawning a worker that cannot check anything out.
if [[ "${GOVERN_MODE:-live}" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
  _free_gb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
  if [[ "${_free_gb:-99}" -lt "${GOVERN_MIN_FREE_GB:-5}" ]]; then
    echo "skip: disk low (${_free_gb}GB < ${GOVERN_MIN_FREE_GB:-5}GB). Free space or resolve escalations to reclaim parked worktrees, then dispatch again"
    exit 0
  fi
fi

# ── 1. NA-marker auto-skip, plus the chronic-skip streak ─────────────────────────────────────
# The streak counter is file-backed (governor/na-skip-counts.json via govern::na_skip_bump), so it
# survives the loop it used to live in: a ticket auto-skipped as NOT-automatable for
# GOVERN_NA_NUDGE_AFTER (default 3) consecutive dispatches gets ONE escalation recommending the
# operator defer it permanently, guarded by has_open_escalation so it is never re-filed while the
# prior recommendation is still open. Pruning the counter for tickets that are no longer NA happens
# on every invocation, so a re-marked or resolved ticket can never fire a stale nudge.
_na_set=","
_na_hit=""
_na_hit_reason=""
while IFS=$'\t' read -r _na_n _na_reason; do
  [[ -n "$_na_n" ]] || continue
  _na_set+="$_na_n,"
  if [[ "$_na_n" == "$N" ]]; then _na_hit="$_na_n"; _na_hit_reason="$_na_reason"; fi
done < <(govern::not_automatable_tickets "$TICKETS_FILE" 2>/dev/null || true)
if [[ "${GOVERN_MODE:-live}" == "live" ]]; then
  govern::na_skip_prune "$_na_set" 2>/dev/null || true
fi
if [[ -n "$_na_hit" ]]; then
  if [[ "${GOVERN_MODE:-live}" == "live" ]]; then
    _na_count="$(govern::na_skip_bump "$N" 2>/dev/null || echo 0)"
    if [[ "${_na_count:-0}" -ge "${GOVERN_NA_NUDGE_AFTER:-3}" ]] && ! govern::has_open_escalation "$N"; then
      govern::log "#$N auto-skipped ${_na_count} consecutive dispatches ('$_na_hit_reason'), filing a one-time escalation to PERMANENTLY remove it from the live queue"
      govern::file_open_escalation "$N" \
        "permanently park chronically-skipped '$_na_hit_reason' ticket" \
        "auto-skipped as '$_na_hit_reason' for ${_na_count} consecutive govern dispatches, it can't be resolved headlessly and is churning a skip note every time instead of leaving the live queue" \
        "remove it from the live queue: answer Disposition 'defer' to migrate it to tickets-parked.md (or 'do-the-work' to keep retrying it, 'keep-open' to leave it in the live queue)" \
        "defer (recommended) / do-the-work / keep-open"
    fi
  fi
  echo "skip: body marked '$_na_hit_reason' (not govern-automatable; handle interactively): no worker burned"
  exit 0
fi

# ── 2. already-a-public-issue dedup ──────────────────────────────────────────────────────────
if [[ "${GOVERN_SKIP_ISSUE_TICKETS:-1}" == "1" ]]; then
  while IFS=$'\t' read -r _iss_n _iss_url; do
    [[ "$_iss_n" == "$N" ]] || continue
    echo "skip: already a public issue $_iss_url — reserved for external contributors, not the internal dispatch path (GOVERN_SKIP_ISSUE_TICKETS)"
    exit 0
  done < <(govern::tickets_already_issues "$TICKETS_FILE" 2>/dev/null || true)
fi

# ── 3. cross-driver re-verify: still on origin/main? ─────────────────────────────────────────
META_DIR="$(govern::meta_root)"
if ! govern::ticket_present_on_origin "$META_DIR" "$N"; then
  echo "skip: #$N no longer on origin/main (resolved+pushed by a concurrent session): no worker burned"
  exit 0
fi

# ── 4. depends-on gate ────────────────────────────────────────────────────────────────────────
_unmet=""
while IFS= read -r _k; do
  [[ "$_k" =~ ^[0-9]+$ ]] || continue
  grep -qE "^##[[:space:]]+#$_k([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null && _unmet="${_unmet:+$_unmet, }#$_k"
done < <(govern::ticket_deps "$N" "$TICKETS_FILE")
if [[ -n "$_unmet" ]]; then
  echo "skip: depends on unresolved $_unmet (still in tickets.md): no worker burned"
  exit 0
fi

# ── 5. staleness gate (ships inert by default) ───────────────────────────────────────────────
if [[ "${GOVERN_STALENESS_GATE:-0}" == "1" ]]; then
  _sg_out=""
  _sg_rc=0
  _sg_out="$("$DIR/staleness-gate.sh" "$N" 2>/dev/null)" || _sg_rc=$?
  if [[ "$_sg_rc" -eq 10 ]]; then
    echo "skip: ${_sg_out:-confidently stale}: no worker burned"
    exit 0
  fi
fi

# ── 6. failure-streak breaker (ported verbatim from run-loop.sh's consecutive_fails) ─────────
# Trailing CONSECUTIVE failed / timeout / budget-exceeded / early-abort outcomes for THIS ticket
# across the cross-run history (a resolved or parked outcome resets the streak). Its data source,
# governor/ticket-history.jsonl, is written by govern::record-style writers that survive the loop
# (resolve-ticket.sh's rt_record_history and spawn-worker's own ledger), so this is a MOVE of
# default-ON behaviour, not a new mechanism: an item that fails cleanly every attempt (worker
# converges, opens a PR, CI never passes, or the item is mis-scoped) trips none of spawn-worker's
# live early-abort signals but does trip this one. Without it such an item burns a fresh worker on
# every future dispatch, forever, with no operator-facing signal.
_consecutive_fails() { # ticket -> count
  [[ -f "$TICKET_HISTORY_FILE" ]] || { echo 0; return 0; }
  jq -s --argjson t "$1" '
    [ .[] | select(.ticket == $t) ] | reverse
    | (reduce .[] as $e ({n:0,stop:false};
        if .stop then .
        elif ($e.status=="failed" or $e.status=="timeout" or $e.status=="budget-exceeded" or $e.status=="early-abort") then {n:(.n+1),stop:false}
        else {n:.n,stop:true} end)).n' "$TICKET_HISTORY_FILE" 2>/dev/null || echo 0
  return 0
}
_cf=0
if command -v jq >/dev/null 2>&1; then _cf="$(_consecutive_fails "$N")"; fi
if [[ "${_cf:-0}" -ge "${GOVERN_MAX_TICKET_FAILS:-2}" ]]; then
  # Auto-escalate as a systemic blocker (filed under "## Open", so the next dispatch skips it too)
  # rather than re-attempting: the operator / root-cause path takes over instead of an infinite
  # retry. One escalation only, guarded the same way the chronic-skip nudge is.
  if [[ "${GOVERN_MODE:-live}" == "live" ]] && ! govern::has_open_escalation "$N"; then
    govern::file_open_escalation "$N" \
      "systemic blocker: ${_cf} consecutive failed dispatches" \
      "systemic blocker: failed ${_cf} consecutive dispatches. Needs operator / root-cause, not another auto-retry" \
      "inspect the preserved worktree + worker.jsonl, fix the underlying blocker (or re-scope / close the ticket)" \
      ""
  fi
  echo "skip: #$N failed ${_cf} consecutive dispatches (GOVERN_MAX_TICKET_FAILS=${GOVERN_MAX_TICKET_FAILS:-2}): auto-escalated as a systemic blocker, not re-spawning"
  exit 0
fi

# ── 7. proposed-solution gate ────────────────────────────────────────────────────────────────────
# An inert-by-default gate risks shipping silently off, exactly the failure to avoid, so this
# ships ON: the kill switch must be set explicitly, not assumed. Reads the ticket exactly once,
# through the one shared implementation (govern::ticket_proposal). Nothing else on this path
# re-parses the ticket file.
if [[ "${GOVERN_PROPOSAL_GATE:-1}" != "0" ]]; then
  if [[ -z "$(govern::ticket_proposal "$N" "$TICKETS_FILE")" ]]; then
    echo "refuse: no proposed solution - the driver must specify before dispatch"
    exit 0
  fi
fi

# ── 8. upstream-drift pregate ─────────────────────────────────────────────────────────────────
if declare -F govern::pregate_hub_ahead >/dev/null 2>&1; then
  DRIFT="$(govern::pregate_hub_ahead "$N" "$TICKETS_FILE" 2>/dev/null || true)"
  if [[ -n "$DRIFT" ]]; then
    _dpaths="$(printf '%s' "$DRIFT" | cut -f1 | paste -sd' ' -)"
    _dpairs="$(printf '%s' "$DRIFT" | awk -F'\t' 'NF>=2{printf "%s%s -> %s", (n++?"; ":""), $1, $2}')"
    echo "refuse: #$N targets file(s) the HUB is AHEAD on ($_dpaths) — port the hub diff down instead of dispatching a fresh-fix worker ($_dpairs)"
    exit 0
  fi
fi

# ── 9. dispatch-time overlap nudge (zero model calls, stderr only) ───────────────────────────
# A non-blocking hint that some OTHER queued-but-unnamed ticket touches the files this one does, so
# the operator can batch them into one worker. It never changes the verdict and never touches the
# queue. GOVERN_OVERLAP_NUDGE=0 silences it.
govern::overlap_nudge "$N" "$TICKETS_FILE" || true

echo "proceed"
exit 0
