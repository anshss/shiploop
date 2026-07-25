#!/usr/bin/env bash
# Durable validation runner (spec §4) — pending-results delivery. All three readers (the governor
# supervisor's periodic pass in run-loop.sh, the SessionStart hook, and `govern-validations.sh` on
# demand) call this SAME mechanical script so "apply + mark consumed" always runs through one code
# path under one mutex. First scans every job dir under logs/govern/validations/<job>/ (owned by the
# runner, ticket #5) for a terminal status.jsonl record, atomically emitting a pending-result.json
# the first time one appears (mirrors escalations-emit-pending.sh's tmp+mv pattern), then applies
# every still-unconsumed pending entry: evidence-stamp the flow registry on PASS, file an escalation
# on FAIL/ABORT/ERROR, then mark consumed — serialized under the bookkeep mutex so two readers racing
# one terminal job can never double-stamp or double-file (see lib/valpending.sh).
#
# Usage: validations-pending-apply.sh [--reader NAME] [--scan-only] [validations-dir]
#   --reader NAME    tag written into pending-result.json's consumedBy (default: cli)
#   --scan-only      emit pending entries but don't apply them; prints newly-emitted job-ids
# Prints one job-id per line for each job actually applied (scan-only: each job newly emitted).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
source "$DIR/lib/valpending.sh"
govern::require jq

reader="cli"; scan_only=0; vdir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reader) reader="${2:-cli}"; shift 2 ;;
    --scan-only) scan_only=1; shift ;;
    *) vdir="$1"; shift ;;
  esac
done
[[ -n "$vdir" ]] || vdir="$(govern::valpending_dir)"

emitted="$(govern::valpending_scan "$vdir" 2>/dev/null || true)"
[[ -n "$emitted" ]] && govern::log "valpending: emitted pending-result for: $(printf '%s' "$emitted" | tr '\n' ' ')"

if [[ "$scan_only" == "1" ]]; then
  [[ -n "$emitted" ]] && printf '%s\n' "$emitted"
  exit 0
fi

applied="$(govern::valpending_apply_all "$vdir" "$reader" 2>/dev/null || true)"
[[ -n "$applied" ]] && govern::log "valpending: applied+consumed (reader=$reader): $(printf '%s' "$applied" | tr '\n' ' ')"
[[ -n "$applied" ]] && printf '%s\n' "$applied"
exit 0
