#!/usr/bin/env bash
# dispatch.sh <N>[,<N>...] [<N>[,<N>...] ...] [--model <haiku|sonnet|opus>]: the one command that
# turns "I want a worker on ticket N" into a gated, ready-to-paste spawn.
#
# What it does, in order, so none of it depends on the advisor remembering a step:
#   1. runs pre-dispatch-check.sh on every named batch (comma = one worker, space = parallel
#      workers) and stops on a `skip:` / `refuse:` verdict, printing that line;
#   2. for every batch that proceeds, runs dispatch-packet.sh (worktree, packet, and the
#      `Model: <alias>` line, default sonnet);
#   3. prints, per batch, the ticket's own `**Proposed solution:**` and `**Done when:**` blocks
#      verbatim (the advisor re-reads what it is about to hand over), then ONE ready Agent call:
#      subagent_type "worker", name worker-<first N>, `model` only when it is not sonnet (the
#      Agent call's own model param wins over the worker frontmatter), and the packet's one-line
#      prompt. router-posture-guard.sh denies a worker spawn that does not match this packet, so
#      the printed call is the one that passes.
#
# Usage: dispatch.sh 12 | 12,14 | 12 15 | 12,14 15 [--model opus]
# Exit code: 0 whenever a verdict was produced (a skip or refuse is information, not an error),
# non-zero only for a malformed invocation or a packet that could not be written.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

# ── block extraction, straight out of the ticket block ───────────────────────────────────────────
# A field runs from its marker line to the next bold `**Field:**` line, a `---` rule or a heading.
ticket_field() { # <N> <marker-regex> -> the field's text, trailing blank lines trimmed
  local n="$1" marker="$2"
  govern::ticket_block "$n" "$TICKETS_FILE" | awk -v m="$marker" '
    grab && (/^\*\*[A-Za-z][^*]*:?\*\*/ || /^---[[:space:]]*$/ || /^##[[:space:]]/) { exit }
    !grab && $0 ~ m { grab = 1 }
    grab { buf[++n] = $0 }
    END { while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print buf[i] }'
  return 0
}

print_blocks() { # <N>... -> each ticket's Proposed solution and Done when blocks, verbatim
  local n ps dw
  for n in "$@"; do
    printf '\n#%s Proposed solution:\n' "$n"
    ps="$(ticket_field "$n" '^\\*\\*Proposed solution:?\\*\\*')"
    printf '%s\n' "${ps:-(none found)}"
    printf '\n#%s Done when:\n' "$n"
    dw="$(ticket_field "$n" '^(\\*\\*Done when:?\\*\\*|Done when:)')"
    printf '%s\n' "${dw:-(none found)}"
  done
  return 0
}

# --print-blocks <N>[,<N>...]: only the blocks, no gates and no packet. router-posture-guard.sh calls
# it to hand the advisor the ticket at spawn time.
if [[ "${1:-}" == "--print-blocks" ]]; then
  IFS=',' read -r -a _pb <<< "${2:-}"
  print_blocks "${_pb[@]}"
  exit 0
fi

MODEL_ALIAS="sonnet"
BATCH_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) [[ $# -ge 2 ]] || govern::die "--model needs a value (haiku|sonnet|opus)"; MODEL_ALIAS="$2"; shift 2 ;;
    --model=*) MODEL_ALIAS="${1#--model=}"; shift ;;
    *) BATCH_ARGS+=("$1"); shift ;;
  esac
done
[[ "${#BATCH_ARGS[@]}" -ge 1 ]] || govern::die "usage: dispatch.sh <N>[,<N>...] [<N>[,<N>...] ...] [--model <haiku|sonnet|opus>]"
case "$MODEL_ALIAS" in
  haiku|sonnet|opus) ;;
  *) govern::die "not a model alias: '$MODEL_ALIAS' (use haiku, sonnet or opus)" ;;
esac
for _a in "${BATCH_ARGS[@]}"; do
  [[ "$_a" =~ ^[0-9]+(,[0-9]+)*$ ]] || govern::die "not a ticket number or comma group: '$_a'"
done

# ── 1. the gates ─────────────────────────────────────────────────────────────────────────────────
verdict="$(bash "$DIR/pre-dispatch-check.sh" "${BATCH_ARGS[@]}")"
printf '%s\n' "$verdict"

PROCEED=()
plan_line="$(printf '%s\n' "$verdict" | grep -E '^plan: ' | tail -n 1 || true)"
if [[ -n "$plan_line" ]]; then
  _plan="${plan_line#plan: }"
  [[ "$_plan" == "(nothing to dispatch)" ]] && exit 0
  IFS='|' read -r -a PROCEED <<< "$_plan"
else
  [[ "$verdict" == "proceed" ]] || exit 0
  PROCEED=("${BATCH_ARGS[0]}")
fi

# ── 2 + 3. packet and the ready call, per batch ──────────────────────────────────────────────────
for batch in "${PROCEED[@]}"; do
  [[ -n "$batch" ]] || continue
  out="$(bash "$DIR/dispatch-packet.sh" "$batch" --model "$MODEL_ALIAS")" || govern::die "dispatch-packet failed for $batch"
  packet="$(printf '%s\n' "$out" | sed -n '1p')"
  prompt="$(printf '%s\n' "$out" | sed -n '2p')"
  primary="${batch%%,*}"

  printf '\n== batch %s ==\n' "$batch"
  IFS=',' read -r -a members <<< "$batch"
  print_blocks "${members[@]}"
  printf '\nPacket: %s\nSpawn it with exactly this call:\n\nAgent(\n  subagent_type: "worker",\n  name: "worker-%s",\n' "$packet" "$primary"
  [[ "$MODEL_ALIAS" == "sonnet" ]] || printf '  model: "%s",\n' "$MODEL_ALIAS"
  printf '  description: "Resolve ticket %s",\n  prompt: "%s"\n)\n' "$primary" "$prompt"
done
exit 0
