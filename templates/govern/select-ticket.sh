#!/usr/bin/env bash
# Emit the next ticket number to work: severity desc (High>Medium>Low>unknown), then # asc.
# Skips numbers in $1 (comma-separated) and any # with an entry under "## Open" in escalations.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

EXCLUDE_ARG="${1:-}"
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
# "handle interactively" marker — a headless worker can't resolve them, so selecting one just
# burns a worker and fast-fails every run. They stay in tickets.md (workable again once a human
# un-parks/handles them); the loop logs the human-readable why (this script's stderr is suppressed).
while IFS=$'\t' read -r na_n _; do
  [[ -n "$na_n" ]] && exclude+="${na_n},"
done < <(govern::not_automatable_tickets "$TICKETS_FILE")

# Parse tickets into "sev num" rows. sev: 1=High 2=Medium 3=Low 4=unknown.
rows=()
current=""; sev=4
flush() { [[ -n "$current" ]] && rows+=("$sev $current"); return 0; }
while IFS= read -r line; do
  if [[ "$line" =~ ^##[[:space:]]+\#([0-9]+) ]]; then
    flush; current="${BASH_REMATCH[1]}"; sev=4
  elif [[ -n "$current" && "$line" == '**Severity:**'* ]]; then
    lc="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
    case "$lc" in *high*) sev=1;; *medium*) sev=2;; *low*) sev=3;; esac
  fi
done < "$TICKETS_FILE"
flush

[[ "${#rows[@]}" -gt 0 ]] || exit 0   # no tickets → empty output, exit 0

for r in "${rows[@]}"; do
  n="${r#* }"
  case "$exclude" in *",$n,"*) continue;; esac
  printf '%s\n' "$r"
done | sort -k1,1n -k2,2n | head -1 | awk '{print $2}'
