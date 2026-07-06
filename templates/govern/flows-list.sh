#!/usr/bin/env bash
# Render validation/flows.md grouped by status (validations Phase 4, `/shiploop:flows list`). READ-ONLY
# by default: it never mutates the registry — it runs the cheap report-only staleness scan and ANNOTATES
# any flow whose mapped paths have moved past its validated SHA ("would go STALE"), so the operator sees
# reality without a surprise commit. `--sweep` first runs the persisting sweep (records the STALE
# degrades via cas_edit) and then renders the refreshed registry.
#
# Usage: scripts/govern/flows-list.sh [--sweep]
# BLOCKED flows show their named blocker; MEASURING flows show their gate/sample window.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
command -v govern::flow_ids >/dev/null 2>&1 || govern::die "flow parser (flows.sh) unavailable — upgrade the harness"

do_sweep=0; [[ "${1:-}" == "--sweep" ]] && do_sweep=1
META="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"
FLOWS="${GOVERN_FLOWS_FILE:-$META/validation/flows.md}"
[[ -f "$FLOWS" ]] || { printf 'No flow registry yet (%s). Run `/shiploop:flows extract` to inventory flows.\n' "${FLOWS#"$META/"}"; exit 0; }

# Persisting sweep (records STALE) or report-only scan (annotate only).
would_stale=""
if [[ "$do_sweep" -eq 1 ]]; then
  swept="$(govern::flows_sweep "$META" 2>/dev/null | tr '\n' ' ' || true)"
  [[ -n "${swept// /}" ]] && printf 'Swept: recorded STALE on %s\n\n' "$swept"
else
  would_stale=" $(govern::flows_sweep_scan "$META" 2>/dev/null | tr '\n' ' ' || true) "
fi

is_would_stale() { case "$would_stale" in *" $1 "*) return 0;; *) return 1;; esac; }

total="$(govern::flow_ids "$FLOWS" | grep -c . || true)"
printf 'Flow registry — %s   (%s flow(s))\n' "${FLOWS#"$META/"}" "$total"
printf '%s\n' "$(govern::flows_status_summary "$META" 2>/dev/null || true)"

# Group order: actionable/positive first, then negatives, then terminal.
for group in PASS EFFECTIVE MEASURING UNTESTED STALE FAIL INEFFECTIVE BLOCKED TOMBSTONED; do
  ids=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(govern::flow_field "$id" Status "$FLOWS")" == "$group" ]] && ids="${ids:+$ids }$id"
  done < <(govern::flow_ids "$FLOWS")
  [[ -n "$ids" ]] || continue
  # shellcheck disable=SC2086
  set -- $ids; printf '\n%s (%d)\n' "$group" "$#"
  for id in $ids; do
    kind="$(govern::flow_field "$id" Kind "$FLOWS")"
    surface="$(govern::flow_field "$id" Surface "$FLOWS")"
    printf '  %-34s %-13s %s\n' "$id" "$kind" "$surface"
    case "$group" in
      BLOCKED)   printf '  %-34s blocker: %s\n' "" "$(govern::flow_field "$id" Blocker "$FLOWS")" ;;
      MEASURING) printf '  %-34s window:  %s\n' "" "$(govern::flow_field "$id" Gate "$FLOWS")" ;;
    esac
    disp="$(govern::flow_field "$id" Disposition "$FLOWS")"
    [[ -n "$disp" ]] && printf '  %-34s disposition: %s\n' "" "$disp"
    if [[ "$group" != STALE && "$group" != UNTESTED && "$group" != BLOCKED && "$group" != TOMBSTONED ]] && is_would_stale "$id"; then
      printf '  %-34s ⚠ paths moved since validated — would go STALE on the next sweep (run --sweep to record)\n' ""
    fi
  done
done
