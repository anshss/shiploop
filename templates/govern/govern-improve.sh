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
