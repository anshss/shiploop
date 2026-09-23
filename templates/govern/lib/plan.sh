#!/usr/bin/env bash
# lib/plan.sh: the batching / composition-check half of pre-dispatch-check.sh's PLAN mode.
# Sourced only by pre-dispatch-check.sh,
# which has already sourced lib/common.sh (TICKETS_FILE, REPOS, govern::*) and defined
# pdc_gate_one, the per-ticket gate this file calls once per named member.
#
# The advisor has read every ticket and written each proposal, so IT plans the dispatch (which
# tickets share a worker, which run parallel); this file only CHECKS the plan mechanically:
#   - no dependency inside a batch, either direction (govern::ticket_deps)
#   - every member resolves to the same sub-repo (a ticket with no determinable sub-repo never
#     blocks this -- fail-open, the same posture every gate in this file takes)
#   - batch size at most GOVERN_GROUP_MAX (default 6)
#   - a batch with NO shared measured path across any pair of its members (an "unrelated" tiny
#     batch) may only carry `stated`-precision tickets naming 1-2 measured files
# It does NOT try to verify "same code area" -- that is the advisor's own judgment,
# trusted, not a text pattern a script can confirm.
#
# Bash 3.2 (macOS's own /bin/bash, this codebase's floor) has no
# associative arrays: every per-ticket fact below is derived on demand from TICKETS_FILE via the
# existing govern:: helpers, never cached in a map.
set -uo pipefail

# Backticked tokens in a ticket's own **Where:** paragraph only -- the same "trust the author's own
# backticks" rule govern::overlap_nudge applies to a NAMED ticket, so a vague prose mention
# elsewhere in the ticket never drags an unrelated composition decision along.
_pdc_where_paths() { # N -> path-like tokens, one per line
  local n="$1"
  govern::ticket_block "$n" "$TICKETS_FILE" \
    | awk '/^\*\*Where:\*\*/{grab=1} grab{print} grab && /^[[:space:]]*$/{exit}' \
    | grep -oE '`[^`]+`' | tr -d '`' || true
  return 0
}
# Every measured path a ticket names (**Files:** + **Where:**), deduped, one per line.
_pdc_measured_paths() { # N -> paths
  local n="$1"
  { govern::ticket_paths "$n" "$TICKETS_FILE"; _pdc_where_paths "$n"; } | awk 'NF && !seen[$0]++'
  return 0
}
# The single sub-repo short name a ticket's measured paths resolve to; "" if none, OR if its paths
# span more than one repo (ambiguous -- fail-open).
_pdc_repo_for_ticket() { # N -> repo short name or ""
  local n="$1" p repo found=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    for repo in "${REPOS[@]}"; do
      case "$p" in
        "$repo"/*)
          if [[ -z "$found" ]]; then found="$repo"
          elif [[ "$found" != "$repo" ]]; then printf ''; return 0; fi
          ;;
      esac
    done
  done < <(_pdc_measured_paths "$n")
  printf '%s' "$found"
  return 0
}

# ── each check: <batch-index> <member...> -> prints its OWN drop lines directly (never swallowed
# by a command substitution) and sets $_PDC_SURVIVORS (space-separated) as the return channel. ────

# No dependency inside the batch, either direction.
_pdc_check_deps() {
  local bi="$1"; shift
  local a b dep dropped survivors=""
  for a in "$@"; do
    dropped=""
    for b in "$@"; do
      [[ "$a" != "$b" ]] || continue
      while IFS= read -r dep; do
        [[ "$dep" == "$b" ]] || continue
        dropped="depends on #$b (same batch)"
      done < <(govern::ticket_deps "$a" "$TICKETS_FILE")
      [[ -z "$dropped" ]] || break
    done
    if [[ -n "$dropped" ]]; then
      printf '#%s: dropped from batch %s: %s\n' "$a" "$bi" "$dropped"
    else
      survivors="$survivors $a"
    fi
  done
  _PDC_SURVIVORS="$survivors"
}

# Every member resolves to the same sub-repo. The FIRST member with a determinable repo anchors it;
# a later member with a DIFFERENT determinable repo is dropped. A member with no determinable repo
# is never dropped by this check (fail-open).
_pdc_check_same_repo() {
  local bi="$1"; shift
  local m r anchor="" survivors=""
  for m in "$@"; do
    r="$(_pdc_repo_for_ticket "$m")"
    if [[ -z "$r" ]]; then
      survivors="$survivors $m"
    elif [[ -z "$anchor" ]]; then
      anchor="$r"; survivors="$survivors $m"
    elif [[ "$r" == "$anchor" ]]; then
      survivors="$survivors $m"
    else
      printf "#%s: dropped from batch %s: sub-repo '%s' differs from the batch's '%s'\n" "$m" "$bi" "$r" "$anchor"
    fi
  done
  _PDC_SURVIVORS="$survivors"
}

# Batch size at most GOVERN_GROUP_MAX (default 6) -- drop the trailing overflow.
_pdc_check_size() {
  local bi="$1"; shift
  local cap="${GOVERN_GROUP_MAX:-6}" m idx=0 survivors=""
  for m in "$@"; do
    idx=$((idx + 1))
    if [[ "$idx" -le "$cap" ]]; then
      survivors="$survivors $m"
    else
      printf '#%s: dropped from batch %s: batch size exceeds GOVERN_GROUP_MAX=%s\n' "$m" "$bi" "$cap"
    fi
  done
  _PDC_SURVIVORS="$survivors"
}

# An "unrelated" batch (no measured path shared by ANY pair of its members -- rule 1's "same code
# area" does not hold) may only carry `stated`-precision members naming 1-2 measured files (rule 2).
# A batch where at least one pair DOES share a path is left alone: rule 1 already covers it, judged
# by the advisor before it named the batch.
_pdc_check_unrelated_precision() {
  local bi="$1"; shift
  local a b p q related=0 survivors=""
  for a in "$@"; do
    for b in "$@"; do
      [[ "$a" != "$b" ]] || continue
      for p in $(_pdc_measured_paths "$a"); do
        for q in $(_pdc_measured_paths "$b"); do
          if [[ "$p" == "$q" ]]; then related=1; fi
        done
      done
    done
  done
  if [[ "$related" -eq 1 ]]; then
    _PDC_SURVIVORS="$*"
    return 0
  fi
  local m prec nfiles
  for m in "$@"; do
    prec="$(govern::ticket_precision "$m" "$TICKETS_FILE")"
    nfiles="$(_pdc_measured_paths "$m" | grep -c .)"
    if [[ "$prec" == "stated" && "${nfiles:-0}" -ge 1 && "${nfiles:-0}" -le 2 ]]; then
      survivors="$survivors $m"
    else
      printf '#%s: dropped from batch %s: an unrelated batch (no shared measured path) needs stated precision naming 1-2 measured files (precision=%s, files=%s)\n' \
        "$m" "$bi" "${prec:-none}" "${nfiles:-0}"
    fi
  done
  _PDC_SURVIVORS="$survivors"
}

# pdc_plan <batch1> [<batch2> ...] -- each <batchN> is a comma-separated list of ticket numbers
# (a bare N with no comma is a batch of one). Prints the full plan-mode transcript to stdout.
pdc_plan() {
  local -a final_batches=()
  local bi=0 batch

  for batch in "$@"; do
    bi=$((bi + 1))
    local -a members=()
    IFS=',' read -r -a members <<< "$batch"
    local m
    for m in "${members[@]}"; do
      [[ "$m" =~ ^[0-9]+$ ]] || govern::die "not a ticket number: '$m' (batch $bi: '$batch')"
    done

    # every existing gate, per member -- a skip/refuse drops that member from the batch.
    local proceeding="" verdict
    for m in "${members[@]}"; do
      verdict="$(pdc_gate_one "$m")"
      printf '#%s: %s\n' "$m" "$verdict"
      if [[ "$verdict" == "proceed" ]]; then proceeding="$proceeding $m"; fi
    done

    if [[ "$(printf '%s\n' $proceeding | grep -c .)" -ge 2 ]]; then
      _pdc_check_deps "$bi" $proceeding
      proceeding="$_PDC_SURVIVORS"
    fi
    if [[ -n "$proceeding" ]]; then
      _pdc_check_same_repo "$bi" $proceeding
      proceeding="$_PDC_SURVIVORS"
    fi
    if [[ -n "$proceeding" ]]; then
      _pdc_check_size "$bi" $proceeding
      proceeding="$_PDC_SURVIVORS"
    fi
    if [[ "$(printf '%s\n' $proceeding | grep -c .)" -ge 2 ]]; then
      _pdc_check_unrelated_precision "$bi" $proceeding
      proceeding="$_PDC_SURVIVORS"
    fi

    proceeding="$(printf '%s\n' $proceeding | awk 'NF' | tr '\n' ' ')"
    proceeding="${proceeding% }"
    if [[ -n "$proceeding" ]]; then
      local joined; joined="${proceeding// /,}"
      printf 'batch %s: proceed %s\n' "$bi" "$joined"
      final_batches+=("$joined")
    else
      printf 'batch %s: nothing to dispatch\n' "$bi"
    fi
  done

  if [[ "${#final_batches[@]}" -gt 0 ]]; then
    local plan_line="" b
    for b in "${final_batches[@]}"; do plan_line="${plan_line:+$plan_line|}$b"; done
    printf 'plan: %s\n' "$plan_line"
  else
    printf 'plan: (nothing to dispatch)\n'
  fi
}
