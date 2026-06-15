#!/usr/bin/env bash
# Append ONE ticket to tickets.md with a collision-safe number (#73). The number comes from the
# LIVE max via govern::next_ticket_number — max(tickets.md's highest `## #N`, governor/.ticket-seq)
# + 1, allocated under the bookkeep lock and persisted to .ticket-seq — so a manual filing can never
# silently reuse a number a concurrent session (or the governor) already took. This is THE supported
# manual-filing path: never hand-append `## #N` with a guessed/hardcoded number, and never let two
# sessions append to tickets.md unserialized.
#
# Usage:
#   scripts/govern/file-ticket.sh "Short title" [Severity] < body.md
#   printf 'Where: ...\nObserved: ...\nDone when: ...\n' | scripts/govern/file-ticket.sh "Title" Low
#
# Prints the allocated ticket number to stdout. Does NOT git-commit (the caller stages tickets.md +
# governor/.ticket-seq with the rest of its change), so it composes inside a larger filing session.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

title="${1:?ticket title required (arg 1)}"
sev="${2:-Medium}"
body="$(cat)"
[[ -n "${body//[[:space:]]/}" ]] || govern::die "ticket body required on stdin"

n="$(govern::next_ticket_number "$TICKETS_FILE")"
printf '\n## #%s — %s\n\n**Severity:** %s\n\n%s\n\n---\n' "$n" "$title" "$sev" "$body" >> "$TICKETS_FILE"
echo "$n"
