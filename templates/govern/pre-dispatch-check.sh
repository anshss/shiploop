#!/usr/bin/env bash
# pre-dispatch-check.sh — ONE entry point for the pre-spawn gates a session should run BEFORE
# dispatching a worker on ticket N (shiploop 1.19.3, the loop purge).
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
#   1. NA-marker auto-skip       (govern::not_automatable_tickets)          — run-loop.sh:903-936
#   2. already-a-public-issue    (govern::tickets_already_issues,             run-loop.sh:944-954
#                                 GOVERN_SKIP_ISSUE_TICKETS, default on)
#   3. cross-driver re-verify    (govern::ticket_present_on_origin) —       run-loop.sh:1218-1232
#                                 still on origin/main?
#   4. depends-on gate           (govern::ticket_deps) — every                run-loop.sh:1234-1253
#                                 **Depends on:** #K landed?
#   5. staleness gate            (staleness-gate.sh; GOVERN_STALENESS_GATE=0    run-loop.sh:1265
#                                 by default — ships inert, same default the loop shipped)
#   6. upstream-drift pregate    (govern::pregate_hub_ahead, lib/pregate.sh) run-loop.sh:1287-1331
#
# NOT ported here (deliberately out of scope): the per-ticket CLAIM lock, the cross-run
# failure-streak auto-escalation (#60), and the "resume an existing open PR" adoption — all
# loop-only machinery per the purge audit. A concurrent-dispatch race is now the same shape as any
# other concurrent-session race the BK_LOCK/CAS protocol already serializes at LAND time.
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

# ── 1. NA-marker auto-skip ───────────────────────────────────────────────────────────────────
while IFS=$'\t' read -r _na_n _na_reason; do
  [[ "$_na_n" == "$N" ]] || continue
  echo "skip: body marked '$_na_reason' (not govern-automatable; handle interactively) — no worker burned (#92)"
  exit 0
done < <(govern::not_automatable_tickets "$TICKETS_FILE" 2>/dev/null || true)

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
  echo "skip: #$N no longer on origin/main (resolved+pushed by a concurrent session) — no worker burned (#108)"
  exit 0
fi

# ── 4. depends-on gate ────────────────────────────────────────────────────────────────────────
_unmet=""
while IFS= read -r _k; do
  [[ "$_k" =~ ^[0-9]+$ ]] || continue
  grep -qE "^##[[:space:]]+#$_k([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null && _unmet="${_unmet:+$_unmet, }#$_k"
done < <(govern::ticket_deps "$N" "$TICKETS_FILE")
if [[ -n "$_unmet" ]]; then
  echo "skip: depends on unresolved $_unmet (still in tickets.md) — no worker burned (#119)"
  exit 0
fi

# ── 5. staleness gate (ships inert by default) ───────────────────────────────────────────────
if [[ "${GOVERN_STALENESS_GATE:-0}" == "1" ]]; then
  _sg_out=""
  _sg_rc=0
  _sg_out="$("$DIR/staleness-gate.sh" "$N" 2>/dev/null)" || _sg_rc=$?
  if [[ "$_sg_rc" -eq 10 ]]; then
    echo "skip: ${_sg_out:-confidently stale} — no worker burned (#4.5)"
    exit 0
  fi
fi

# ── 6. upstream-drift pregate ─────────────────────────────────────────────────────────────────
if declare -F govern::pregate_hub_ahead >/dev/null 2>&1; then
  DRIFT="$(govern::pregate_hub_ahead "$N" "$TICKETS_FILE" 2>/dev/null || true)"
  if [[ -n "$DRIFT" ]]; then
    _dpaths="$(printf '%s' "$DRIFT" | cut -f1 | paste -sd' ' -)"
    _dpairs="$(printf '%s' "$DRIFT" | awk -F'\t' 'NF>=2{printf "%s%s -> %s", (n++?"; ":""), $1, $2}')"
    echo "refuse: #$N targets file(s) the HUB is AHEAD on ($_dpaths) — port the hub diff down instead of dispatching a fresh-fix worker ($_dpairs)"
    exit 0
  fi
fi

echo "proceed"
exit 0
