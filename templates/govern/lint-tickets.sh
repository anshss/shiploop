#!/usr/bin/env bash
# Lint tickets.md for duplicate `## #N` headings (#73). A duplicate means two filings collided on
# one number — exactly the failure #73 prevents at the source (govern::next_ticket_number); this is
# the cheap backstop that CATCHES one that still slipped through (a hand-edit, a pre-helper filing,
# an unserialized append). Prints the offending numbers to stderr and exits 1 if any duplicate
# exists; silent + exit 0 when clean. Wire into the Stop hook (scripts/hooks/ticket-sweep-reminder).
#
# ALSO runs a NON-BLOCKING warning pass (#309): prose dependency phrases ("depends on #N", "blocked
# by #N", "blocks #N") that lack a canonical bold `**Depends on:**`/`**Blocks:**` marker — a
# prose-only edge the pre-spawn dependency gate can't see (the #308/#306/#307 miss). Warnings go to
# stderr and NEVER change the exit code; only a duplicate heading fails the lint.
#
# Usage: scripts/govern/lint-tickets.sh [tickets-file]   (defaults to the root tickets.md)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

file="${1:-$TICKETS_FILE}"

# ── Non-blocking pass: prose deps without a bold marker (#309). Advisory only — stderr, exit
# untouched — so a prose-only dependency surfaces for canonicalization without failing the lint.
if warns="$(govern::prose_dep_warnings "$file")" && [[ -n "$warns" ]]; then
  printf 'WARN: prose dependency phrase without a **Depends on:**/**Blocks:** marker in %s (#309):\n' "$file" >&2
  printf '%s\n' "$warns" | sed 's/^/  - /' >&2
  printf '  → canonicalize to a bold **Depends on:** / **Blocks:** marker so the dependency gate sees it.\n' >&2
fi

# ── Non-blocking pass: a dependency on a ticket that no longer exists. Advisory only, like the
# prose-dep pass above. Findings are durable; "blocked on #M" is a claim about the PRESENT, and #M
# gets resolved and deleted (often by another session on the same queue) while the blocker line goes
# on reading authoritative. Warn rather than fail: a dangling ref can be deliberate history, and
# this lint gates the Stop hook for everyone.
if dangling="$(govern::dangling_dep_refs "$file")" && [[ -n "$dangling" ]]; then
  printf 'WARN: dependency on a ticket that no longer exists in %s:\n' "$file" >&2
  printf '%s\n' "$dangling" | sed 's/^/  - /' >&2
  printf '  → the blocker is resolved or was never filed. Re-check and update the ticket, do not just delete the ref.\n' >&2
fi

if dups="$(govern::duplicate_ticket_headings "$file")"; then
  exit 0
fi
# Human header → stderr; the bare "#N ×count" list → stdout (machine-readable for the Stop hook).
printf 'DUPLICATE ## #N heading(s) in %s — two filings reused one number (#73):\n' "$file" >&2
printf '%s\n' "$dups"
exit 1
