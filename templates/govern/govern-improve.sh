#!/usr/bin/env bash
# Self-improvement (observe → PROPOSE, never auto-apply). A fresh read-only reviewer looks at the
# run's friction (parked/failed outcomes, supervisor notes, escalations) + the harness layout, and
# proposes concrete harness improvements. Output is APPENDED to governor/improvements.md by this
# script (the agent runs in plan mode → can't write/commit). Safety rails are never auto-changed.
# Usage: govern-improve.sh <run-dir>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
RUNDIR="${1:?run dir required}"
OUT="${GOVERN_IMPROVEMENTS_FILE:-$GOVERNOR_DIR/improvements.md}"

state="$(cat "$RUNDIR/state.jsonl" 2>/dev/null || true)"
review="$(cat "$RUNDIR/review.md" 2>/dev/null || true)"
open_esc="$(awk '/^## Open/{o=1;next} /^## /{o=0} o' "$ESCALATIONS_FILE" 2>/dev/null | head -60 || true)"
harness="$(ls "$DIR"/*.sh "$GOVERNOR_DIR"/*.md 2>/dev/null | sed "s#$WS_ROOT/##" || true)"

# #59: the reviewer should know WHY tickets failed, not just THAT they did. For each failed
# ticket, surface its worker log's final result event (subtype + snippet — often reveals the
# worker actually succeeded but emitted prose instead of JSON, or hit a concrete error) plus
# the first couple of events. This turns generic proposals into ones that target the real cause.
failed_logs=""
fn_list="$(printf '%s' "$state" | jq -r 'select(.status=="failed") | .ticket' 2>/dev/null | sort -un || true)"
while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  # #75: read THIS run's worker log ONLY (run-scoped under $RUNDIR/ticket-N/). The legacy flat
  # logs/govern/ticket-N/worker.jsonl is NOT consulted — a re-run that wrote no new log (e.g. failed
  # at worktree-setup) must read "no worker.jsonl", never a PRIOR run's stale log (the #75 bug).
  jf="$RUNDIR/ticket-$fn/worker.jsonl"
  [[ -f "$jf" ]] || { failed_logs+="$(printf '\n### #%s — no worker.jsonl (failed before the worker wrote anything, e.g. worktree setup)\n' "$fn")"; continue; }
  last="$(grep '"type":"result"' "$jf" 2>/dev/null | tail -1 | jq -r '"\(.subtype // "?"): \((.result // "")[0:500])"' 2>/dev/null || true)"
  failed_logs+="$(printf '\n### #%s worker — final result\n%s\n' "$fn" "${last:-<no result event — worker killed/timed out or crashed mid-run>}")"
  # #122: the final result alone says WHICH ticket failed, not WHY. Surface the HEAD of the worker
  # log too — the opening events reveal what the worker set out to do and where it got stuck (a
  # mid-run crash/timeout leaves no result event at all, so the head is the ONLY signal). Render
  # compactly (event type + text/tool snippet) and drop the system-hook noise that dominates the
  # first lines, so the prompt stays bounded; raw stream-json lines are huge.
  head_excerpt="$(head -200 "$jf" 2>/dev/null | jq -r '
      if .type=="assistant" then "[assistant] " + (((.message.content // []) | map(if .type=="text" then .text elif .type=="tool_use" then "→"+(.name//"?") else "" end) | join(" "))[0:220])
      elif .type=="user" then "[tool_result] " + (((.message.content // []) | tostring)[0:140])
      elif .type=="result" then "[result:"+(.subtype // "?")+"]"
      else empty end' 2>/dev/null \
    | grep -vE '^\[assistant\] $|^\[tool_result\] (\[\]|null|"")$' | head -30 || true)"
  [[ -n "$head_excerpt" ]] && failed_logs+="$(printf '\n#### #%s worker — first events (what it attempted)\n%s\n' "$fn" "$head_excerpt")"
done <<< "$fn_list"

# #122: the reviewer must also know WHY PARKED tickets stopped, not just THAT they did. state.jsonl
# carries only ticket/status/note; the worker's escalation (reason/question/options) lives in the
# per-ticket report.json this run wrote ($RUNDIR/ticket-N/report.json). Without this the "Why
# parked/failed tickets stopped" section came up empty even when a full worker report existed.
# Surface each parked ticket's escalation so that section is populated from real worker context.
parked_ctx=""
pn_list="$(printf '%s' "$state" | jq -r 'select(.status=="parked") | .ticket' 2>/dev/null | sort -un || true)"
while IFS= read -r pn; do
  [[ -n "$pn" ]] || continue
  rf="$RUNDIR/ticket-$pn/report.json"
  if [[ -s "$rf" ]]; then
    esc="$(govern::extract_report < "$rf" 2>/dev/null | jq -r '
        if .escalation then
          "- title: \(.escalation.title // "?")\n- reason: \(.escalation.reason // "")\n- question: \(.escalation.question // "")\n- options: \((.escalation.options // []) | if type=="array" then join(" / ") else tostring end)"
        else "<report carried no escalation>" end' 2>/dev/null || true)"
    parked_ctx+="$(printf '\n### #%s — parked; worker escalation\n%s\n' "$pn" "${esc:-<report.json unparseable>}")"
  else
    parked_ctx+="$(printf '\n### #%s — parked; no report.json (worker died before writing one — see worker.jsonl)\n' "$pn")"
  fi
done <<< "$pn_list"

prompt="GOVERN-IMPROVE. You are reviewing one run of the meta-repo 'governor' ticket harness to
propose improvements to the HARNESS ITSELF (not the tickets). You are read-only — just propose.

Below: this run's per-ticket outcomes, the supervisor's notes, the open escalations, and the
harness file list. Identify friction the harness hit (failures, parks, awkward flows, caveats)
and propose **concrete, specific** changes — name the file and the change.

RULES:
- Propose harness mechanics/robustness/ergonomics improvements only.
- NEVER propose weakening a safety rail (the hard-stops, the run bounds, the permission gate, the
  merge allowlist). If one of those seems to cause friction, label it 'OPERATOR DECISION' and
  explain the trade-off — do not propose silently changing it.
- If the run was clean and you see nothing worth changing, output exactly: NONE
- Otherwise output a short markdown bullet list, each: '- <file>: <specific change> — <why>'.

## Per-ticket outcomes (state.jsonl)
$state

## Supervisor notes
$review

## Why the failed tickets failed (worker-log final result + head of what it attempted)
$failed_logs

## Why the parked tickets stopped (worker escalation from this run's report.json)
$parked_ctx

## Open escalations
$open_esc

## Harness files
$harness"

claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
model="${GOVERN_IMPROVE_MODEL:-sonnet}"
# TokenJam: tag this self-improve session with the run id so it groups with the run's workers (#tokenjam).
out="$(env OTEL_RESOURCE_ATTRIBUTES="$(govern::otel_attrs self-improve)" "$claude_bin" -p "$prompt" --output-format stream-json --verbose \
       --setting-sources "${GOVERN_SETTING_SOURCES:-user}" --permission-mode plan --model "$model" 2>/dev/null \
       | grep '"type":"result"' | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"

# Nothing useful → don't touch the file.
[[ -z "$out" ]] && { govern::log "improve: no output"; exit 0; }
printf '%s' "$out" | grep -qiE '^[[:space:]]*NONE[[:space:]]*$' && { govern::log "improve: reviewer found nothing"; exit 0; }

[[ -f "$OUT" ]] || printf '# Governor self-improvement proposals\n\nAuto-appended after runs with friction. Review + apply (or file as tickets). Safety rails are never auto-changed.\n' > "$OUT"
{
  printf '\n## %s — run %s (resolved/parked/failed observed)\n\n' "$(date +%Y-%m-%d\ %H:%M)" "$(basename "$RUNDIR")"
  printf '%s\n' "$out"
} >> "$OUT"
govern::log "improve: proposals appended → $OUT"

# Ported from harness #111 (via #112): COMMIT the appended improvements.md to main here — this step
# is its WRITER, so (exactly like govern-bookkeep commits tickets.md) it must commit its own tracked
# artifact rather than leave it uncommitted. Left dirty, a later `git pull --rebase` on the main
# checkout (e.g. the next run's govern-bookkeep pre-edit origin sync) aborts on "cannot pull with
# rebase: You have unstaged changes". Only the DEFAULT tracked file in the real checkout — a test's
# GOVERN_IMPROVEMENTS_FILE override points elsewhere, so it's skipped.
if [[ "$OUT" == "$GOVERNOR_DIR/improvements.md" ]]; then
  govern::commit_meta_to_main "$WS_ROOT" "governor/improvements.md" \
    "chore(govern): self-improvement notes from $(basename "$RUNDIR") (#111)" \
    && govern::log "improve: committed governor/improvements.md to main (#111)"
fi
