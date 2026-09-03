#!/usr/bin/env bash
# Order a NAMED ticket set for dispatch: severity desc (High>Medium>Low>unknown), then # asc.
# Named dispatch is the only front door, so this script no longer picks anything FROM the backlog;
# it filters and orders a set the operator already chose. What survives from the old selector is
# exactly the ticket-BODY parser (the `## #N` scan + the tolerant `**Severity:**` match) and the
# eligibility exclusions, both of which named dispatch still needs.
#
# Usage: select-ticket.sh <exclude-csv> <candidate-csv>
#   <exclude-csv>    numbers to drop (may be empty)
#   <candidate-csv>  the named set. REQUIRED; an empty/absent set is a usage error (exit 2), never
#                    an implicit "pick something for me".
# Prints one eligible ticket number per line, in dispatch order. Silent + exit 0 when the whole set
# is ineligible (the caller names each survivor-less target and says why).
#
# Also dropped, per set: any ticket with an entry under "## Open" in escalations.md, any ticket whose
# body is marked NOT govern-automatable (#92), and any ticket colliding with an open sync-port
# manual port (#314).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

EXCLUDE_ARG="${1:-}"
CANDIDATES="${2:-}"
CANDIDATES="${CANDIDATES//[^0-9,]/}"
if [[ -z "${CANDIDATES//,/}" ]]; then
  printf 'usage: select-ticket.sh <exclude-csv> <candidate-csv>\n' >&2
  printf '  the candidate set is required: this selector orders a NAMED set, it never picks from the backlog\n' >&2
  exit 2
fi
include=",${CANDIDATES},"
exclude=",${EXCLUDE_ARG},"

# Add open-escalation ticket numbers to the exclude set.
if [[ -f "$ESCALATIONS_FILE" ]]; then
  in_open=0
  while IFS= read -r line; do
    case "$line" in
      "## Open"*) in_open=1; continue;;
      "## "*) in_open=0; continue;;
    esac
    if [[ "$in_open" -eq 1 && "$line" =~ ^###[[:space:]]+\#([0-9]+) ]]; then
      exclude+="${BASH_REMATCH[1]},"
    fi
  done < "$ESCALATIONS_FILE"
fi

# #92: drop tickets whose body carries a bold "NOT govern-automatable" / "requires web-UI" /
# "handle interactively" marker — a headless worker can't resolve them, so dispatching one just
# burns a worker and fast-fails. They stay in tickets.md (workable again once a human
# un-parks/handles them); the loop logs the human-readable why (this script's stderr is suppressed).
while IFS=$'\t' read -r na_n _; do
  [[ -n "$na_n" ]] && exclude+="${na_n},"
done < <(govern::not_automatable_tickets "$TICKETS_FILE")

# #314: drop tickets that edit a file with an OPEN sync-port manual-port escalation — dispatching
# one risks colliding with that in-progress port's `sync-auto-*` branch/worktree (the #309
# collision). They stay in tickets.md (dispatchable once the sync-port escalation resolves).
while IFS=$'\t' read -r sp_n _; do
  [[ -n "$sp_n" ]] && exclude+="${sp_n},"
done < <(govern::sync_port_collision_tickets "$TICKETS_FILE" "$ESCALATIONS_FILE")

# Parse tickets into "sev num" rows. sev: 1=High 2=Medium 3=Low 4=unknown.
rows=()
current=""; sev=4
flush() { [[ -n "$current" ]] && rows+=("$sev $current"); return 0; }
while IFS= read -r line; do
  if [[ "$line" =~ ^##[[:space:]]+\#([0-9]+) ]]; then
    flush; current="${BASH_REMATCH[1]}"; sev=4
  # Tolerant severity match: accept an optional leading list marker + whitespace
  # (`- **Severity:** …`) and both colon placements (`**Severity:**` and `**Severity**:`).
  # The strict `**Severity:***` glob missed the list form and the colon-outside-bold form,
  # silently deprioritizing those tickets to sev=4.
  elif [[ -n "$current" && "$line" =~ ^[[:space:]]*(-[[:space:]]+)?\*\*Severity(\*\*:|:\*\*) ]]; then
    lc="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
    case "$lc" in *high*) sev=1;; *medium*) sev=2;; *low*) sev=3;; esac
  fi
done < "$TICKETS_FILE"
flush

[[ "${#rows[@]}" -gt 0 ]] || exit 0   # no tickets → empty output, exit 0

for r in "${rows[@]}"; do
  n="${r#* }"
  case "$include" in *",$n,"*) ;; *) continue;; esac
  case "$exclude" in *",$n,"*) continue;; esac
  printf '%s\n' "$r"
done | sort -k1,1n -k2,2n | awk '{print $2}'
