#!/usr/bin/env bash
# dispatch-packet.sh <N>[,<N>...]: everything a worker needs to start, written to disk instead of
# re-typed into a prompt or re-derived by the worker itself.
#
# Run by the advisor AFTER `pre-dispatch-check.sh` has already verdicted "proceed" for every named
# ticket. It creates the worktree through the SAME code path as `worktree:new` (passing --adopt, so
# a re-run of this same dispatch reuses the worktree instead of erroring on "path already exists"),
# then writes <worktree>/.dispatch-packet.md: every named ticket's block verbatim (Proposed solution
# and Precision included -- it IS the ticket, read straight out of queue/tickets.md, so an
# investigator's findings folded into the proposal ride along automatically), the recorded-gotchas
# block for every path the tickets name, each member's advisor-consult budget, the worktree path,
# every touched sub-repo's own CLAUDE.md path, and each member's test command when its proposal
# names one (a **Test:** field). More than one member also gets the GOVERN_BATCH_MEMBER_TURNS value.
#
# Prints exactly two lines on stdout: the packet path, then the one-line dispatch prompt in the
# contract form router-posture-guard.sh also parses:
#   Resolve #12, #14. Read your packet at <worktree path>/.dispatch-packet.md first and follow it.
#   Resolve #12. Read your packet at <worktree path>/.dispatch-packet.md first and follow it.
# The `#N` stays in the prompt because the PROPOSAL GATE reads the ticket number out of it
# (resolve_tnum) -- that gate is unchanged by this script.
#
# Usage: dispatch-packet.sh <N>[,<N>...]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require git

TICKETS_ARG="${1:-}"
[[ -n "$TICKETS_ARG" ]] || govern::die "usage: dispatch-packet.sh <N>[,<N>...]"
IFS=',' read -r -a TICKET_NUMS <<< "$TICKETS_ARG"
for _t in "${TICKET_NUMS[@]}"; do
  [[ "$_t" =~ ^[0-9]+$ ]] || govern::die "not a ticket number: '$_t'"
done
PRIMARY="${TICKET_NUMS[0]}"
NAME="t$PRIMARY"

# ── 1. the worktree, via the SAME code path worktree:new uses ────────────────────────────────────
WT_NEW="$WS_ROOT/scripts/worktree/new.sh"
[[ -f "$WT_NEW" ]] || govern::die "scripts/worktree/new.sh not found -- is this a scaffolded workspace?"
govern::log "creating worktree '$NAME' (or adopting it if a prior dispatch already made one) ..."
bash "$WT_NEW" "$NAME" --adopt 1>&2 || govern::die "worktree:new failed for '$NAME'"
WORKTREE_PATH="$WORKTREE_BASE/$NAME"
[[ -d "$WORKTREE_PATH" ]] || govern::die "expected worktree at $WORKTREE_PATH after worktree:new, found nothing"

# ── 2. gather every member's advisor budget, test command, and measured paths ────────────────────
budget_for_grade() { # stated|scoped|open|"" -> advisor-consult budget for that grade
  case "$1" in
    open) printf '%s' "${GOVERN_ADVISOR_PER_WORKER_OPEN:-3}" ;;
    stated) printf '%s' "${GOVERN_ADVISOR_PER_WORKER_STATED:-1}" ;;
    *) printf '%s' "${GOVERN_ADVISOR_PER_WORKER:-2}" ;;
  esac
}
ticket_test_cmd() { # N -> the **Test:** field's value, "" if absent
  local n="$1" block
  block="$(govern::ticket_block "$n" "$TICKETS_FILE")"
  [[ -n "$block" ]] || return 0
  printf '%s\n' "$block" | sed -n -E 's/^\*\*Test:?\*\*[[:space:]]*//p' | head -1
  return 0
}
# Backticked tokens in the ticket's own **Where:** paragraph -- the same "narrow, trust the
# author's own backticks" rule govern::overlap_nudge applies to a NAMED ticket's own paths, so a
# vague prose mention elsewhere in the ticket never drags an unrelated hazard lookup along.
ticket_where_paths() { # N -> one path-like token per line
  local n="$1"
  govern::ticket_block "$n" "$TICKETS_FILE" \
    | awk '/^\*\*Where:\*\*/{grab=1} grab{print} grab && /^[[:space:]]*$/{exit}' \
    | grep -oE '`[^`]+`' | tr -d '`' || true
  return 0
}

ALL_PATHS=""
TOUCHED_REPOS=""
# Bash 3.2 (macOS's own /bin/bash, this codebase's floor) has no
# associative arrays, so "seen" is a plain substring check on TOUCHED_REPOS itself.
for _n in "${TICKET_NUMS[@]}"; do
  while IFS= read -r _p; do
    [[ -n "$_p" ]] || continue
    ALL_PATHS="$ALL_PATHS
$_p"
    for _r in "${REPOS[@]}"; do
      case "$_p" in
        "$_r"/*)
          case " $TOUCHED_REPOS " in
            *" $_r "*) : ;;
            *) TOUCHED_REPOS="$TOUCHED_REPOS $_r" ;;
          esac
          ;;
      esac
    done
  done < <(govern::ticket_paths "$_n" "$TICKETS_FILE"; ticket_where_paths "$_n")
done
ALL_PATHS="$(printf '%s\n' "$ALL_PATHS" | awk 'NF && !seen[$0]++')"

GOTCHAS=""
if [[ -n "$ALL_PATHS" ]]; then
  GOTCHAS="$(govern::gotcha_block $ALL_PATHS 2>/dev/null || true)"
fi

# ── 3. assemble the packet ─────────────────────────────────────────────────────────────────────
PACKET="$WORKTREE_PATH/.dispatch-packet.md"
{
  printf '<!-- GOVERN:PACKET-CREATED %s -->\n' "$(date -u +%s)"
  printf '# Dispatch packet for %s\n\n' "$(printf '#%s, ' "${TICKET_NUMS[@]}" | sed 's/, $//')"
  printf 'Created: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Worktree: %s\n' "$WORKTREE_PATH"
  if [[ -n "$TOUCHED_REPOS" ]]; then
    for _r in $TOUCHED_REPOS; do
      if [[ -f "$WORKTREE_PATH/$_r/CLAUDE.md" ]]; then
        printf 'Sub-repo CLAUDE.md: %s/%s/CLAUDE.md\n' "$WORKTREE_PATH" "$_r"
      fi
    done
  fi
  if [[ "${#TICKET_NUMS[@]}" -gt 1 ]]; then
    printf 'GOVERN_BATCH_MEMBER_TURNS: %s\n' "${GOVERN_BATCH_MEMBER_TURNS:-60}"
  fi
  printf '\n'

  for _n in "${TICKET_NUMS[@]}"; do
    printf '## Ticket #%s\n\n' "$_n"
    _block="$(govern::ticket_block "$_n" "$TICKETS_FILE")"
    if [[ -n "$_block" ]]; then
      printf '%s\n\n' "$_block"
    else
      printf '(ticket #%s not found in %s)\n\n' "$_n" "$TICKETS_FILE"
    fi
    _prec="$(govern::ticket_precision "$_n" "$TICKETS_FILE")"
    printf 'Advisor-consult budget for #%s: %s (grade: %s)\n\n' "$_n" "$(budget_for_grade "$_prec")" "${_prec:-scoped (default)}"
    _tc="$(ticket_test_cmd "$_n")"
    if [[ -n "$_tc" ]]; then
      printf '### Test command for #%s\n\n`%s`\n\n' "$_n" "$_tc"
    fi
  done

  if [[ -n "$GOTCHAS" ]]; then
    printf '## Recorded gotchas\n\n%s\n' "$GOTCHAS"
  fi
} > "$PACKET"

govern::log "wrote packet: $PACKET"

# ── 4. the one-line dispatch prompt (the form router-posture-guard.sh parses) ──────────────────────────
_refs="#${TICKET_NUMS[0]}"
for ((_ti = 1; _ti < ${#TICKET_NUMS[@]}; _ti++)); do _refs+=", #${TICKET_NUMS[_ti]}"; done

printf '%s\n' "$PACKET"
printf 'Resolve %s. Read your packet at %s first and follow it.\n' "$_refs" "$PACKET"
