#!/usr/bin/env bash
# dispatch.sh <N>[,<N>...] [<N>[,<N>...] ...] [--model <haiku|sonnet|opus>]: the one command that
# turns "I want a worker on ticket N" into a gated, ready-to-paste spawn.
#
# What it does, in order, so none of it depends on the advisor remembering a step:
#   1. runs pre-dispatch-check.sh on every named batch (comma = one worker, space = parallel
#      workers) and stops on a `skip:` / `refuse:` verdict, printing that line;
#   2. for every batch that proceeds, runs dispatch-packet.sh (worktree, packet, and the line
#      that says what the worker runs on: `Model: <alias>`, default sonnet);
#   3. prints, per batch, the ticket's own `**Proposed solution:**` and `**Done when:**` blocks
#      verbatim (the advisor re-reads what it is about to hand over), then ONE ready Agent call:
#      subagent_type "worker", name worker-<first N>, `model` only when it is not sonnet (the
#      Agent call's own model param wins over the worker frontmatter), and the packet's one-line
#      prompt. router-posture-guard.sh denies a worker spawn that does not match this packet, so
#      the printed call is the one that passes.
#
# Under an active model profile (SHIPLOOP_MODEL_PROFILE) the worker's model is the profile's model
# for its role, chosen at spawn by the model-router mod, so --model is refused in favor of
# --role <worker|worker-retry>: the packet gets a `Role:` line and the printed call names the
# role's agent type and carries no `model` at all.
#
# Usage: dispatch.sh 12 | 12,14 | 12 15 | 12,14 15 [--model opus | --role worker-retry]
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
# The profile that decides the worker's model, or "" when none is active (a name that is not a
# plain name is no profile, the same reading dispatch-packet.sh and the router make).
MODEL_PROFILE="${SHIPLOOP_MODEL_PROFILE:-}"
[[ "$MODEL_PROFILE" =~ ^[A-Za-z0-9_.-]+$ ]] || MODEL_PROFILE=""
ROLE_ARGS=()
USAGE="usage: dispatch.sh <N>[,<N>...] [<N>[,<N>...] ...] [--model <haiku|sonnet|opus> | --role <worker|worker-retry>]"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || govern::die "--model needs a value (haiku|sonnet|opus)"
      [[ -z "$MODEL_PROFILE" ]] || govern::die "SHIPLOOP_MODEL_PROFILE=$MODEL_PROFILE is active: the worker's model comes from that profile's model for its role, so pass --role <worker|worker-retry>, not --model"
      MODEL_ALIAS="$2"; shift 2 ;;
    --model=*)
      [[ -z "$MODEL_PROFILE" ]] || govern::die "SHIPLOOP_MODEL_PROFILE=$MODEL_PROFILE is active: the worker's model comes from that profile's model for its role, so pass --role <worker|worker-retry>, not --model"
      MODEL_ALIAS="${1#--model=}"; shift ;;
    --role) [[ $# -ge 2 ]] || govern::die "$USAGE"; ROLE_ARGS=(--role "$2"); shift 2 ;;
    --role=*) ROLE_ARGS=(--role "${1#--role=}"); shift ;;
    *) BATCH_ARGS+=("$1"); shift ;;
  esac
done
[[ "${#BATCH_ARGS[@]}" -ge 1 ]] || govern::die "$USAGE"
case "$MODEL_ALIAS" in
  haiku|sonnet|opus) ;;
  *) govern::die "not a model alias: '$MODEL_ALIAS' (use haiku, sonnet or opus)" ;;
esac
# --role means nothing without a profile: the type's own definition decides the model then.
if [[ -z "$MODEL_PROFILE" && "${#ROLE_ARGS[@]}" -gt 0 ]]; then
  govern::die "--role names a role in a model profile, and no profile is active (SHIPLOOP_MODEL_PROFILE is unset): without one pass --model <haiku|sonnet|opus>"
fi
# The agent type the printed call names: the role under a profile, "worker" otherwise.
SPAWN_TYPE="worker"
if [[ -n "$MODEL_PROFILE" && "${#ROLE_ARGS[@]}" -eq 2 ]]; then SPAWN_TYPE="${ROLE_ARGS[1]}"; fi
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
  if [[ -n "$MODEL_PROFILE" ]]; then
    out="$(bash "$DIR/dispatch-packet.sh" "$batch" ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"})" || govern::die "dispatch-packet failed for $batch"
  else
    out="$(bash "$DIR/dispatch-packet.sh" "$batch" --model "$MODEL_ALIAS")" || govern::die "dispatch-packet failed for $batch"
  fi
  packet="$(printf '%s\n' "$out" | sed -n '1p')"
  prompt="$(printf '%s\n' "$out" | sed -n '2p')"
  primary="${batch%%,*}"

  printf '\n== batch %s ==\n' "$batch"
  IFS=',' read -r -a members <<< "$batch"
  print_blocks "${members[@]}"
  printf '\nPacket: %s\nSpawn it with exactly this call:\n\nAgent(\n  subagent_type: "%s",\n  name: "worker-%s",\n' "$packet" "$SPAWN_TYPE" "$primary"
  # Under a profile the call carries no model: the model-router mod sets it from the role at spawn.
  if [[ -z "$MODEL_PROFILE" && "$MODEL_ALIAS" != "sonnet" ]]; then printf '  model: "%s",\n' "$MODEL_ALIAS"; fi
  printf '  description: "Resolve ticket %s",\n  prompt: "%s"\n)\n' "$primary" "$prompt"
done
exit 0
