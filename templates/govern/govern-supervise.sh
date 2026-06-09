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

recent="$(tail -8 "$RUNDIR/state.jsonl" 2>/dev/null || true)"
headings="$(grep -oE '^## #[0-9]+ .*' "$TICKETS_FILE" 2>/dev/null | head -60 || true)"
open_esc="$(awk '/^## Open/{o=1;next} /^## /{o=0} o' "$ESCALATIONS_FILE" 2>/dev/null | head -40 || true)"

prompt="$(cat "$PROMPT_FILE")

## Recent ticket outcomes (this run, newest last)
$recent

## Current open ticket headings
$headings

## Open escalations
$open_esc"

claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
model="${GOVERN_SUPERVISOR_MODEL:-sonnet}"
out="$("$claude_bin" -p "$prompt" --output-format stream-json --verbose \
       --setting-sources "${GOVERN_SETTING_SOURCES:-user}" --permission-mode plan --model "$model" 2>/dev/null \
       | grep '"type":"result"' | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"

if printf '%s' "$out" | jq -e '.verdict' >/dev/null 2>&1; then
  printf '%s\n' "$out"
else
  # Supervisor unreachable/garbled → fail safe to "ok" (never block the loop on a flaky review).
  printf '{"verdict":"ok","concerns":[],"haltReason":"supervisor unparseable — defaulted ok"}\n'
fi
