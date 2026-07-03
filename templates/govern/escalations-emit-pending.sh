#!/usr/bin/env bash
# #62 — driver→relay hand-off. Scan escalations.md "## Open" and write a machine-readable
# governor/pending-escalations.json listing the entries that STILL need an operator answer
# (Answer field is the `_(operator)_` placeholder). The launching Claude session (the /govern
# relay) reads this file, presents ALL entries in a single batched AskUserQuestion (#89 — ≤4 per
# prompt, chunk if >4, never one prompt per ticket), and writes the chosen Answer +
# Disposition back into escalations.md — closing the write-only gap where parked decisions sat
# unanswered indefinitely. Also fires the configured notification channel (GOVERN_NOTIFY_CMD)
# when pending escalations exist and no session is watching (the driver is headless).
#
# Usage:  escalations-emit-pending.sh [run-id] [review-file]
#   prints the pending count to stdout; writes governor/pending-escalations.json
#   review-file (#92): the run's review.md of supervisor concerns — its non-empty lines are folded
#   into the JSON as `supervisorConcerns` and into the notify message, so the supervisor's advice
#   reaches the relay/operator at run-end instead of dying in review.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

# #337: hard skip when a parent context has suppressed emit — its sub-tree (e.g. a nested porter
# claude session) must NOT rewrite the parent run's pending-escalations.json against a partial /
# nested view of state. The parent's authoritative emit-at-last reconciles against the FINAL
# escalations.md ## Open once every run-end writer has fired. No-op silently, non-zero exit avoided
# so callers that `|| true` still see 0.
if [[ "${GOVERN_SUPPRESS_EMIT_PENDING:-0}" == "1" ]]; then
  govern::log "emit-pending: SUPPRESSED (GOVERN_SUPPRESS_EMIT_PENDING=1 — parent will regenerate) [#337]"
  echo 0
  exit 0
fi

govern::require jq

RUN_ID="${1:-}"
REVIEW_FILE="${2:-}"
OUT="${GOVERN_PENDING_FILE:-$GOVERNOR_DIR/pending-escalations.json}"

# #92: collect the run's supervisor concerns (one JSON array of trimmed, non-empty lines).
concerns='[]'
if [[ -n "$REVIEW_FILE" && -s "$REVIEW_FILE" ]]; then
  concerns="$(grep -v '^[[:space:]]*$' "$REVIEW_FILE" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  [[ -n "$concerns" ]] || concerns='[]'
fi
nconcerns="$(printf '%s' "$concerns" | jq 'length' 2>/dev/null || echo 0)"

# Collect open entries that are genuinely unanswered (Answer is still the placeholder).
pending="$(govern::escalations_open_ndjson | jq -s '
  [ .[] | select((.answer // "") == "" or (.answer | test("\\(operator\\)"))) ]
  | map({ticket: (.ticket|tonumber), title, reason, question, options})' 2>/dev/null || echo '[]')"
[[ -n "$pending" ]] || pending='[]'
count="$(printf '%s' "$pending" | jq 'length' 2>/dev/null || echo 0)"

# Stamp with epoch (date is allowed in bash) so the relay/operator can see staleness.
# #92: supervisorConcerns rides alongside the escalations so the relay surfaces the supervisor's
# run-end advice (e.g. "#N unblocked — attempt now", "#M NOT automatable") even when it produced
# no formal escalation of its own.
# Atomic write (tmp + mv): a reader (the /govern relay, run-start regen, or a concurrent driver) must
# never observe a half-written pending-escalations.json. mv is atomic on the same filesystem.
_out_tmp="$OUT.tmp.$$"
if jq -n --argjson e "$pending" --argjson c "$concerns" --arg run "$RUN_ID" --argjson ts "$(date +%s)" \
  '{generatedAt: $ts, run: $run, count: ($e|length), escalations: $e, supervisorConcerns: $c}' > "$_out_tmp" 2>/dev/null; then
  mv "$_out_tmp" "$OUT" 2>/dev/null || { rm -f "$_out_tmp" 2>/dev/null || true; govern::log "could not write $OUT"; }
else
  rm -f "$_out_tmp" 2>/dev/null || true; govern::log "could not write $OUT"
fi

if [[ "$count" -gt 0 ]]; then
  govern::log "$count open escalation(s) await an operator answer → $OUT (relay presents these via AskUserQuestion)"
elif [[ "$nconcerns" -gt 0 ]]; then
  govern::log "no pending escalations, but $nconcerns supervisor concern(s) surfaced → $OUT (supervisorConcerns)"
else
  govern::log "no pending escalations → $OUT (count 0)"
fi

# Notification channel (#62, extended #92): the driver is headless, so a no-session run would
# otherwise leave the decisions/advice silent. Fire GOVERN_NOTIFY_CMD when EITHER an escalation
# needs an answer OR the supervisor raised a concern (best-effort, never fatal). Default unset →
# the run summary's "Needs you" / "Supervisor notes" sections are the signal.
if [[ -n "${GOVERN_NOTIFY_CMD:-}" ]] && { [[ "$count" -gt 0 ]] || [[ "$nconcerns" -gt 0 ]]; }; then
  msg="governor:"
  [[ "$count" -gt 0 ]] && msg="$msg $count escalation(s) need your answer (tickets: $(printf '%s' "$pending" | jq -r 'map(.ticket)|join(", ")'))."
  [[ "$nconcerns" -gt 0 ]] && msg="$msg $nconcerns supervisor concern(s) to review."
  msg="$msg See governor/pending-escalations.json"
  printf '%s\n' "$msg" | eval "${GOVERN_NOTIFY_CMD}" >/dev/null 2>&1 \
    || govern::log "GOVERN_NOTIFY_CMD failed (non-fatal)"
fi
echo "$count"
