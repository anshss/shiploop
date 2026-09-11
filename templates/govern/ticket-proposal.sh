#!/usr/bin/env bash
# ticket-proposal.sh <N> [tickets-file] — print ticket N's **Proposed solution:** / **Precision:**
# fields (.specs/2026-09-11-advisor-worker-design.md D2/D6), or nothing if the ticket carries
# neither yet (absent, or still the filing-time placeholder — filing is not specifying).
#
# This is the interactive lane's entry point into the SAME extraction the headless launcher
# (spawn-worker.sh) runs via govern::ticket_proposal / govern::ticket_precision before it ever
# assembles a dispatch prompt — see lib/common.sh, the one shared implementation both lanes call.
# The headless lane gets this injected into its dispatch prompt automatically; a worker subagent
# (.claude/agents/worker.md) has no launcher to do that for it, so it runs THIS as its own first
# step, the same pattern gotchas-for-paths.sh (#125) already established for hazard handoff.
#
# Usage: scripts/govern/ticket-proposal.sh <N> [tickets-file]
# Prints nothing (exit 0) when the ticket has no real proposal yet — the caller must treat that as
# "no proposed solution," never guess one from the surrounding prose.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

N="${1:?ticket number required}"
FILE="${2:-$TICKETS_FILE}"

prop="$(govern::ticket_proposal "$N" "$FILE")"
[[ -n "${prop//[[:space:]]/}" ]] || exit 0
prec="$(govern::ticket_precision "$N" "$FILE")"
[[ -n "$prec" ]] || prec="scoped (default — no explicit or recognised **Precision:** field)"

printf '## Proposed solution for #%s (advisor-authored — implement it, report if you believe it is wrong)\n%s\n\n**Precision:** %s\n' \
  "$N" "$prop" "$prec"
