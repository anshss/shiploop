#!/usr/bin/env bash
# SessionStart hook — durable validation runner (spec §4, reader 2/3). A long validation job can
# finish with no governor run active; without this it lands in silence until the next scheduled
# supervisor pass. Runs the SAME mechanical apply script the supervisor uses (mutex-serialized, so
# racing readers never double-stamp/double-escalate one terminal job) and prints whichever jobs got
# adopted THIS session. Best-effort: guarded on the mechanism script + jq, always exits 0 (never
# blocks session start).
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$SELF_ROOT/scripts/govern/validations-pending-apply.sh"
[ -f "$APPLY" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

out="$(bash "$APPLY" --reader session-start 2>/dev/null || true)"
[ -n "$out" ] || exit 0

printf -- '── validation job(s) adopted this session ──\n'
printf '%s\n' "$out" | while IFS= read -r job; do
  [ -n "$job" ] || continue
  printf '  %s\n' "$job"
done
exit 0
