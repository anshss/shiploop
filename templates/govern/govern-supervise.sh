#!/usr/bin/env bash
# Spawn a fresh, short-lived Claude supervisor to review recent run state. Feeds it INCREMENTAL
# state (only ticket outcomes since ITS OWN last pass this run, plus its own last verdict as a
# carried-forward compressed summary) + the full current ticket-blocks window + open escalations,
# gets back a structured verdict. Read-only (plan mode), cheap model.
# Usage: govern-supervise.sh <run-dir>
# Prints: {"verdict":"ok|concerns|halt","concerns":[...],"haltReason":null}
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
RUNDIR="${1:?run dir required}"
PROMPT_FILE="${GOVERN_SUPERVISOR_PROMPT_FILE:-$GOVERNOR_DIR/supervisor-prompt.md}"

# #56: originally fed the supervisor the FULL run history every pass (not tail -8 — that was
# blind to most of the run, so a conflict between an early ticket and a much-later one, e.g.
# #98/#109 or #104/#105, sat outside an 8-line tail and was never caught).
# At the full-history design, EVERY pass re-sent the SAME, steadily growing text — wasted
# tokens on every call, worse the longer the run. Fix: go INCREMENTAL, not windowed. Each pass
# reads only the state.jsonl lines appended SINCE ITS OWN previous pass (cursor file below) plus
# its OWN previous verdict JSON (the compressed judgment it already formed over everything
# before that). This stays lossless across the run — every ticket outcome lands in exactly one
# pass's "since last pass" section, never dropped by a size/age window the way tail -8 dropped
# them — so the #56 regression (blindness past a fixed window) cannot return: nothing is ever cut
# from history, a pass just stops RE-reading outcomes an earlier pass in this SAME run already
# reviewed and folds them into its own carried-forward verdict instead (the same way a human
# reviewer trusts their own earlier notes instead of re-reading a whole document each time).
# #122: the ticket-BLOCKS window below is intentionally left UNCHANGED by this ticket — it still
# shows the FULL current queue (bodies, GOVERN_SUPERVISOR_BLOCKS_LINES-capped, default 500) on
# every pass. Unlike run history, the queue isn't something the supervisor "already reviewed" —
# a same-surface conflict can appear between a ticket resolved 20 tickets ago and one just filed,
# and predicting which subset is "relevant to this run" would silently reintroduce the #122
# blindness (truncated conflict-detection) this file was already fixed for. It's already bounded
# and doesn't grow pass-over-pass the way raw run history did, so it isn't what this ticket targets.
STATE_FILE="$RUNDIR/state.jsonl"
CURSOR_FILE="$RUNDIR/.supervisor-cursor"
PREV_VERDICT_FILE="$RUNDIR/.supervisor-last-verdict.json"

total_lines="$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)"; total_lines="${total_lines//[[:space:]]/}"
[[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=0
prev_cursor="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
[[ "$prev_cursor" =~ ^[0-9]+$ ]] || prev_cursor=0
# Defensive clamp only — state.jsonl only ever grows within a run, so this never skips a real
# entry; it just guards a corrupt/stale cursor from claiming there's nothing new to show.
[[ "$prev_cursor" -gt "$total_lines" ]] && prev_cursor=0

new_since_last="$(tail -n "+$((prev_cursor + 1))" "$STATE_FILE" 2>/dev/null || true)"
prev_verdict="$(cat "$PREV_VERDICT_FILE" 2>/dev/null || true)"

blocks="$(awk '/^## #[0-9]+ /{p=1} p' "$TICKETS_FILE" 2>/dev/null | head -"${GOVERN_SUPERVISOR_BLOCKS_LINES:-500}" || true)"
open_esc="$(awk '/^## Open/{o=1;next} /^## /{o=0} o' "$ESCALATIONS_FILE" 2>/dev/null | head -40 || true)"

prompt="$(cat "$PROMPT_FILE")

## Your own verdict from the previous supervisor pass this run (compressed summary of every
## ticket outcome reviewed before this pass — treat it as already-seen, not as something to
## re-derive)
${prev_verdict:-(none — this is the first supervisor pass this run)}

## Ticket outcomes since your previous pass (newest last; anything earlier was already reviewed
## and is summarized in the verdict above)
${new_since_last:-(none — no ticket has resolved/parked/failed since your last pass)}

## Open tickets — full blocks (bodies included; these are the upcoming candidates)
$blocks

## Open escalations
$open_esc"

claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
model="${GOVERN_SUPERVISOR_MODEL:-sonnet}"
# TokenJam: tag this supervisor session with the run id so it groups with the run's workers (#tokenjam).
out="$(env OTEL_RESOURCE_ATTRIBUTES="$(govern::otel_attrs supervisor)" "$claude_bin" -p "$prompt" --output-format stream-json --verbose \
       --setting-sources "${GOVERN_SETTING_SOURCES:-project,local}" --permission-mode plan --model "$model" 2>/dev/null \
       | grep '"type":"result"' | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"

emit=""
if printf '%s' "$out" | jq -e '.verdict' >/dev/null 2>&1; then
  emit="$out"
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
    emit="$recovered"
  else
    # Truly unparseable even after fence-strip + scan → fail-open to "ok" (deliberate: never
    # block the loop on a flaky review) but LOG the miss loudly + tag the emitted verdict so a
    # lost halt is visible in the run log rather than silently downgraded to ok.
    govern::log "supervisor verdict UNPARSEABLE — defaulting ok (any halt in the response was lost)" >&2
    emit='{"verdict":"ok","concerns":[],"haltReason":"supervisor unparseable — defaulted ok","unparseable":true}'
  fi
fi

# Persist this pass's verdict + cursor so the NEXT pass this run only sees what's new. Cursor only
# advances if the verdict write actually lands — if it doesn't (e.g. disk full), the next pass
# keeps the OLD cursor and finds no prev_verdict either, so it naturally re-reads the same
# state.jsonl range from scratch: degrades to the old #56 full-resend behavior, never to blindness.
if printf '%s\n' "$emit" > "$PREV_VERDICT_FILE" 2>/dev/null; then
  printf '%s' "$total_lines" > "$CURSOR_FILE" 2>/dev/null || true
fi

printf '%s\n' "$emit"
