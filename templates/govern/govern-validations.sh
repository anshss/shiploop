#!/usr/bin/env bash
# `govern validations` — driver-facing live-jobs surface for the durable validation runner (spec §4,
# reader 3/3: "flows status / govern validations, on demand"). Lists every job under
# logs/govern/validations/<job>/: job-id, current phase, deploy-ids, and heartbeat age (a terminal job
# shows its verdict instead of a heartbeat, since the runner stops touching the heartbeat once it
# writes the terminal record). On-demand checks also double as an adoption pass — by default this
# scans + applies any unconsumed pending-results on the way (same mutex-serialized path the supervisor
# and SessionStart-hook readers use), so asking "what's running?" also adopts whatever just finished.
# Pass --no-apply for a read-only peek.
#
# Usage: govern-validations.sh [--no-apply]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
source "$DIR/lib/valpending.sh"
govern::require jq

do_apply=1
[[ "${1:-}" == "--no-apply" ]] && do_apply=0

VDIR="$(govern::valpending_dir)"
if [[ "$do_apply" == "1" ]]; then
  govern::valpending_scan "$VDIR" >/dev/null 2>&1 || true
  applied="$(govern::valpending_apply_all "$VDIR" "govern-validations" 2>/dev/null || true)"
  [[ -n "$applied" ]] && govern::log "adopted: $(printf '%s' "$applied" | tr '\n' ' ')"
fi

meta="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"
printf 'Validation jobs — %s\n' "${VDIR#"$meta/"}"
govern::valpending_live_listing "$VDIR"
