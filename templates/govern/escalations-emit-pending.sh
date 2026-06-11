#!/usr/bin/env bash
# #62 — driver→relay hand-off. Scan escalations.md "## Open" and write a machine-readable
# governor/pending-escalations.json listing the entries that STILL need an operator answer
# (Answer field is the `_(operator)_` placeholder). The launching Claude session (the /govern
# relay) reads this file, presents each via AskUserQuestion, and writes the chosen Answer +
# Disposition back into escalations.md — closing the write-only gap where parked decisions sat
# unanswered indefinitely. Also fires the configured notification channel (GOVERN_NOTIFY_CMD)
# when pending escalations exist and no session is watching (the driver is headless).
#
# Usage:  escalations-emit-pending.sh [run-id]
#   prints the pending count to stdout; writes governor/pending-escalations.json
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

RUN_ID="${1:-}"
OUT="${GOVERN_PENDING_FILE:-$GOVERNOR_DIR/pending-escalations.json}"

# Collect open entries that are genuinely unanswered (Answer is still the placeholder).
pending="$(govern::escalations_open_ndjson | jq -s '
  [ .[] | select((.answer // "") == "" or (.answer | test("\\(operator\\)"))) ]
  | map({ticket: (.ticket|tonumber), title, reason, question, options})' 2>/dev/null || echo '[]')"
[[ -n "$pending" ]] || pending='[]'
count="$(printf '%s' "$pending" | jq 'length' 2>/dev/null || echo 0)"

# Stamp with epoch (date is allowed in bash) so the relay/operator can see staleness.
jq -n --argjson e "$pending" --arg run "$RUN_ID" --argjson ts "$(date +%s)" \
  '{generatedAt: $ts, run: $run, count: ($e|length), escalations: $e}' > "$OUT" 2>/dev/null \
  || govern::log "could not write $OUT"

if [[ "$count" -gt 0 ]]; then
  govern::log "$count open escalation(s) await an operator answer → $OUT (relay presents these via AskUserQuestion)"
  # Notification channel (#62): the driver is headless, so a no-session run would otherwise leave
  # the decisions silent. If GOVERN_NOTIFY_CMD is configured, feed it a one-line message on stdin
  # (best-effort, never fatal). Default unset → the run summary's "Needs you" section is the signal.
  if [[ -n "${GOVERN_NOTIFY_CMD:-}" ]]; then
    msg="governor: $count escalation(s) need your answer — see governor/pending-escalations.json (tickets: $(printf '%s' "$pending" | jq -r 'map(.ticket)|join(", ")'))"
    printf '%s\n' "$msg" | eval "${GOVERN_NOTIFY_CMD}" >/dev/null 2>&1 \
      || govern::log "GOVERN_NOTIFY_CMD failed (non-fatal)"
  fi
else
  govern::log "no pending escalations → $OUT (count 0)"
fi
echo "$count"
