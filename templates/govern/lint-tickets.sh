#!/usr/bin/env bash
# Lint tickets.md for duplicate `## #N` headings. A duplicate means two filings collided on
# one number — exactly the failure collision-safe numbering (govern::next_ticket_number) prevents
# at the source; this is the cheap backstop that CATCHES one that still slipped through (a
# hand-edit, a pre-helper filing, an unserialized append). ALSO fails on a ticket block carrying
# two `**Severity:**` fields (whatever renders the ticket reads the FIRST; a second copy is
# invisible dead text that can disagree with it), and on a bullet-prefixed field marker
# (`- **Proposed solution:**`, a label in GOVERN_STRICT_FIELD_LABELS; a bold label on a prose
# bullet is content, not a field), which is invisible to the strict line-anchored extractors, since
# file-ticket.sh de-bullets at file time and anything still stored arrived by hand-edit or an
# older filer. Each fault's stdout lines are TAGGED `HEADING #N ×count` / `SEVERITY #N ×count` /
# `FIELD #N line <n>: ...` so the Stop hook routes them to the right remedy.
# Prints the offending numbers to stderr and exits 1 if any duplicate exists; silent + exit 0
# when clean. Wire into the Stop hook (scripts/hooks/ticket-sweep-reminder).
#
# ALSO runs a NON-BLOCKING warning pass: prose dependency phrases ("depends on #N", "blocked
# by #N", "blocks #N") that lack a canonical bold `**Depends on:**`/`**Blocks:**` marker — a
# prose-only edge the pre-spawn dependency gate can't see (prose phrasing has slipped past it
# undetected before). Warnings go to stderr and NEVER change the exit code; only a duplicate
# heading fails the lint.
#
# Usage: scripts/govern/lint-tickets.sh [tickets-file]   (defaults to the root tickets.md)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

file="${1:-$TICKETS_FILE}"

# ── Non-blocking pass: prose deps without a bold marker. Advisory only — stderr, exit
# untouched — so a prose-only dependency surfaces for canonicalization without failing the lint.
if warns="$(govern::prose_dep_warnings "$file")" && [[ -n "$warns" ]]; then
  printf 'WARN: prose dependency phrase without a **Depends on:**/**Blocks:** marker in %s:\n' "$file" >&2
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

# Three INDEPENDENT faults fail this lint, and each is TAGGED on its stdout lines (`HEADING #N
# ×count`, `SEVERITY #N ×count` or `FIELD #N line <n>: ...`) so the Stop hook can route them
# separately instead of reporting
# every non-zero exit as a heading collision (whose remedy — renumbering — silently corrupts a live
# ticket's `**Ref:**`/`depends on #N` pointers if followed for the WRONG fault). An untagged line
# (a future check) surfaces verbatim as "read the lint's own output".
rc=0
if dups="$(govern::duplicate_ticket_headings "$file")"; then
  :
else
  printf 'DUPLICATE ## #N heading(s) in %s — two filings reused one number:\n' "$file" >&2
  printf '%s\n' "$dups" | sed 's/^/HEADING /'
  rc=1
fi
if sevdups="$(govern::duplicate_severity_fields "$file")"; then
  :
else
  printf 'Ticket(s) carrying two **Severity:** fields in %s — only the FIRST is read:\n' "$file" >&2
  printf '%s\n' "$sevdups" | sed 's/^/SEVERITY /'
  rc=1
fi
if bulletfields="$(govern::bullet_prefixed_fields "$file")"; then
  :
else
  printf 'Bullet-prefixed field marker(s) in %s (invisible to the line-anchored extractors): strip the leading bullet so the line starts with the bold marker:\n' "$file" >&2
  printf '%s\n' "$bulletfields" | sed 's/^/FIELD /'
  rc=1
fi
# A heading numbered ABOVE governor/.ticket-seq is a hand-minted filing: the allocator (file-ticket.sh)
# reads/bumps the seq file under the bookkeeping lock for every filing, so nothing it allocated can land
# above it. Skipped when the seq file is absent: with no high-water mark on disk the allocator derives
# everything from the file, so "above seq" is meaningless. Headings inside ``` fences are ignored (a
# quoted heading is evidence, not a filing), same as the duplicate-heading pass.
if [[ -f "${GOVERN_TICKET_SEQ_FILE:-$GOVERNOR_DIR/.ticket-seq}" ]]; then
  seq_val="$(tr -dc '0-9' < "${GOVERN_TICKET_SEQ_FILE:-$GOVERNOR_DIR/.ticket-seq}" 2>/dev/null)"
  seq_val="${seq_val:-0}"
  seq_over="$(awk -v seq="$seq_val" '
    /^```/ { infence = !infence; next }
    !infence && $0 ~ /^##[[:space:]]+#[0-9]+/ {
      n = $0; sub(/^##[[:space:]]+#/, "", n); sub(/[^0-9].*$/, "", n)
      if (n + 0 > seq + 0) print n + 0
    }
  ' "$file" | sort -nu || true)"
  if [[ -n "$seq_over" ]]; then
    printf 'Ticket heading(s) numbered above the allocator high-water mark (%s) in %s — a hand-minted filing that bypassed file-ticket.sh:\n' "$seq_val" "$file" >&2
    printf '%s\n' "$seq_over" | sed 's/^/SEQ #/'
    printf '  → renumber the block(s) through allocator conventions (file-ticket.sh prints the next safe number), then set the seq file to the live max.\n' >&2
    rc=1
  fi
fi
if [[ "$rc" -eq 0 ]]; then
  exit 0
fi
# Tagged "#N ×count" list → stdout (machine-readable for the Stop hook); human headers → stderr.
exit "$rc"
