#!/usr/bin/env bash
# ticket-proposal.sh <N> [tickets-file] — print ticket N's **Proposed solution:** / **Precision:**
# fields, or nothing if the ticket carries
# neither yet (absent, or still the filing-time placeholder — filing is not specifying).
#
# A worker's entry point into govern::ticket_proposal / govern::ticket_precision (lib/common.sh),
# the one shared implementation. Nothing assembles a dispatch prompt on a worker's behalf, so a
# worker subagent (.claude/agents/worker.md) runs THIS as its own first
# step, the same pattern gotchas-for-paths.sh already established for hazard handoff.
#
# Usage: scripts/govern/ticket-proposal.sh <N>[part-letter] [tickets-file]
# Prints nothing (exit 0) when the ticket has no real proposal yet — the caller must treat that as
# "no proposed solution," never guess one from the surrounding prose.
#
# A FOLDED ticket (one carrying `### A.` / `### B.` parts) is ambiguous when called by bare
# number — the old code silently returned the earliest part's proposal, which is how a worker
# dispatched against part B could implement part A while believing it followed doctrine. Name the
# part (`ticket-proposal.sh 900B`, or GOVERN_TICKET_PART=B) and you get THAT part's proposal;
# leave it off and this refuses with exit 3 and an explanation on stderr, printing nothing on
# stdout so the "empty output -> STOP" backstop in the worker doctrine still fires.
#
# A STALE caller copy (this script run inside a worker worktree whose queue file predates main's
# proposal-appending commit: no proposal HERE, but the main checkout's copy holds one) refuses
# with exit 4 and a re-sync message on stderr, never the same silence as a genuinely-absent
# proposal, which sent the session to rewrite a proposal that already existed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

N="${1:?ticket number required}"
FILE="${2:-$TICKETS_FILE}"

rc=0
prop="$(govern::ticket_proposal "$N" "$FILE")" || rc=$?
if [[ "$rc" -eq 2 ]]; then
  printf 'ticket-proposal: #%s is AMBIGUOUS — it is folded into `### <letter>.` parts, or carries more\n' "$N" >&2
  printf '  than one proposal. Re-run naming the part you are dispatching, e.g. `%s %sB`.\n' "$(basename "$0")" "$N" >&2
  printf '  Refusing rather than returning whichever proposal happens to come first.\n' >&2
  exit 3
fi
if [[ "$rc" -eq 3 ]]; then
  printf 'ticket-proposal: #%s has no proposal in THIS copy of %s, but the MAIN checkout copy holds one.\n' "$N" "$FILE" >&2
  printf '  The copy is STALE - it predates the proposal appended on main. Re-sync the queue file from\n' >&2
  printf '  main; do NOT ask the advisor to rewrite a proposal that already exists.\n' >&2
  exit 4
fi
[[ -n "${prop//[[:space:]]/}" ]] || exit 0
prec="$(govern::ticket_precision "$N" "$FILE" || true)"
[[ -n "$prec" ]] || prec="scoped (default — no explicit or recognised **Precision:** field)"

printf '## Proposed solution for #%s (advisor-authored — implement it, report if you believe it is wrong)\n%s\n\n**Precision:** %s\n' \
  "$N" "$prop" "$prec"
