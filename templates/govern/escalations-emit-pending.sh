#!/usr/bin/env bash
# Driver→relay hand-off. Scan escalations.md "## Open" and write a machine-readable
# governor/pending-escalations.json listing the entries that STILL need an operator answer
# (Answer field is the `_(operator)_` placeholder). The launching Claude session (the /govern
# relay) reads this file, presents ALL entries in a single batched AskUserQuestion (≤4 per
# prompt, chunk if >4, never one prompt per ticket), and writes the chosen Answer +
# Disposition back into escalations.md — closing the write-only gap where parked decisions sat
# unanswered indefinitely. Also fires the configured notification channel (GOVERN_NOTIFY_CMD)
# when pending escalations exist and no session is watching (the driver is headless).
#
# Usage:  escalations-emit-pending.sh [run-id]
#   prints the pending count to stdout; writes governor/pending-escalations.json
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

# Hard skip when a parent context has suppressed emit — its sub-tree (e.g. a nested porter
# claude session) must NOT rewrite the parent run's pending-escalations.json against a partial /
# nested view of state. The parent's authoritative emit-at-last reconciles against the FINAL
# escalations.md ## Open once every run-end writer has fired. No-op silently, non-zero exit avoided
# so callers that `|| true` still see 0.
if [[ "${GOVERN_SUPPRESS_EMIT_PENDING:-0}" == "1" ]]; then
  govern::log "emit-pending: SUPPRESSED (GOVERN_SUPPRESS_EMIT_PENDING=1 — parent will regenerate)"
  echo 0
  exit 0
fi

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
# Atomic write (tmp + mv): a reader (the /govern relay, run-start regen, or a concurrent driver) must
# never observe a half-written pending-escalations.json. mv is atomic on the same filesystem.
_out_tmp="$OUT.tmp.$$"
if jq -n --argjson e "$pending" --arg run "$RUN_ID" --argjson ts "$(date +%s)" \
  '{generatedAt: $ts, run: $run, count: ($e|length), escalations: $e}' > "$_out_tmp" 2>/dev/null; then
  mv "$_out_tmp" "$OUT" 2>/dev/null || { rm -f "$_out_tmp" 2>/dev/null || true; govern::log "could not write $OUT"; }
else
  rm -f "$_out_tmp" 2>/dev/null || true; govern::log "could not write $OUT"
fi

if [[ "$count" -gt 0 ]]; then
  govern::log "$count open escalation(s) await an operator answer → $OUT (relay presents these via AskUserQuestion)"
else
  govern::log "no pending escalations → $OUT (count 0)"
fi

# Notification channel: the driver is headless, so a no-session run would
# otherwise leave the decisions silent. Fire GOVERN_NOTIFY_CMD when an escalation needs an answer
# (best-effort, never fatal). Default unset → the run summary's "Needs you" section is the signal.
if [[ -n "${GOVERN_NOTIFY_CMD:-}" ]] && [[ "$count" -gt 0 ]]; then
  msg="governor:"
  [[ "$count" -gt 0 ]] && msg="$msg $count escalation(s) need your answer (tickets: $(printf '%s' "$pending" | jq -r 'map(.ticket)|join(", ")'))."
  msg="$msg See governor/pending-escalations.json"
  printf '%s\n' "$msg" | eval "${GOVERN_NOTIFY_CMD}" >/dev/null 2>&1 \
    || govern::log "GOVERN_NOTIFY_CMD failed (non-fatal)"
fi
echo "$count"
