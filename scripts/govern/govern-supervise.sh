#!/usr/bin/env bash
# Spawn a fresh, short-lived Claude supervisor to review recent run state. Feeds it ONLY
# compact state (last few outcomes + current headings + open escalations), gets back a
# structured verdict. Read-only (plan mode), cheap model. Usage: govern-supervise.sh <run-dir>
# Prints: {"verdict":"ok|concerns|halt","concerns":[...],"haltReason":null}
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
RUNDIR="${1:?run dir required}"
PROMPT_FILE="${GOVERN_SUPERVISOR_PROMPT_FILE:-$GOVERNOR_DIR/supervisor-prompt.md}"

# #56: give the supervisor the FULL run history (not tail -8 — it was blind to most of the run)
# and the full ticket BLOCKS (bodies, not just headings) so it can spot a same-surface conflict or
# a subsumption in an UPCOMING ticket BEFORE it's worked, not after. Capped so the prompt stays sane.
# #122: the window is GOVERN_SUPERVISOR_BLOCKS_LINES-configurable, default 500 (was a hardcoded 260
# ≈ 25 tickets). A larger backlog silently truncated the conflict-detection window past ~ticket 25,
# so the supervisor went blind to overlaps (the kind it correctly caught for #98/#109, #104/#105).
recent="$(cat "$RUNDIR/state.jsonl" 2>/dev/null || true)"
blocks="$(awk '/^## #[0-9]+ /{p=1} p' "$TICKETS_FILE" 2>/dev/null | head -"${GOVERN_SUPERVISOR_BLOCKS_LINES:-500}" || true)"
open_esc="$(awk '/^## Open/{o=1;next} /^## /{o=0} o' "$ESCALATIONS_FILE" 2>/dev/null | head -40 || true)"

prompt="$(cat "$PROMPT_FILE")

## All ticket outcomes THIS run (newest last)
$recent

## Open tickets — full blocks (bodies included; these are the upcoming candidates)
$blocks

## Open escalations
$open_esc"

claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
model="${GOVERN_SUPERVISOR_MODEL:-sonnet}"
# TokenJam: tag this supervisor session with the run id so it groups with the run's workers (#tokenjam).
out="$(env OTEL_RESOURCE_ATTRIBUTES="$(govern::otel_attrs supervisor)" "$claude_bin" -p "$prompt" --output-format stream-json --verbose \
       --setting-sources "${GOVERN_SETTING_SOURCES:-user}" --permission-mode plan --model "$model" 2>/dev/null \
       | grep '"type":"result"' | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"

if printf '%s' "$out" | jq -e '.verdict' >/dev/null 2>&1; then
  printf '%s\n' "$out"
else
  # Format-tolerant recovery BEFORE defaulting: the supervisor sometimes wraps its JSON in a
  # ```json ...``` fence or emits trailing prose around the object. A raw jq parse then misses,
  # and a genuine `halt` (the systemic-failure brake) would silently downgrade to `ok`. Strip
  # a ```json / ``` fence pair if present, then walk balanced {...} chunks and keep the LAST
  # one whose jq parses AND has .verdict. If found, emit it.
  recovered=""
  stripped="$(printf '%s' "$out" | sed -E 's/^[[:space:]]*```(json)?[[:space:]]*//; s/[[:space:]]*```[[:space:]]*$//')"
  if printf '%s' "$stripped" | jq -e '.verdict' >/dev/null 2>&1; then
    recovered="$stripped"
  else
    while IFS= read -r -d $'\x1e' cand; do
      [[ -n "$cand" ]] || continue
      if printf '%s' "$cand" | jq -e '.verdict' >/dev/null 2>&1; then recovered="$cand"; fi
    done < <(printf '%s' "$stripped" | govern::_json_objects 2>/dev/null || true)
  fi
  if [[ -n "$recovered" ]]; then
    printf '%s\n' "$recovered"
  else
    # Truly unparseable even after fence-strip + scan → fail-open to "ok" (deliberate: never
    # block the loop on a flaky review) but LOG the miss loudly + tag the emitted verdict so a
    # lost halt is visible in the run log rather than silently downgraded to ok.
    govern::log "supervisor verdict UNPARSEABLE — defaulting ok (any halt in the response was lost)" >&2
    printf '{"verdict":"ok","concerns":[],"haltReason":"supervisor unparseable — defaulted ok","unparseable":true}\n'
  fi
fi
