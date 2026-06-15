#!/usr/bin/env bash
# Lint tickets.md for duplicate `## #N` headings (#73). A duplicate means two filings collided on
# one number — exactly the failure #73 prevents at the source (govern::next_ticket_number); this is
# the cheap backstop that CATCHES one that still slipped through (a hand-edit, a pre-helper filing,
# an unserialized append). Prints the offending numbers to stderr and exits 1 if any duplicate
# exists; silent + exit 0 when clean. Wire into the Stop hook (scripts/hooks/ticket-sweep-reminder).
#
# Usage: scripts/govern/lint-tickets.sh [tickets-file]   (defaults to the root tickets.md)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

file="${1:-$TICKETS_FILE}"
if dups="$(govern::duplicate_ticket_headings "$file")"; then
  exit 0
fi
# Human header → stderr; the bare "#N ×count" list → stdout (machine-readable for the Stop hook).
printf 'DUPLICATE ## #N heading(s) in %s — two filings reused one number (#73):\n' "$file" >&2
printf '%s\n' "$dups"
exit 1
