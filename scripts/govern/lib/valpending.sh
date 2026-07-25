#!/usr/bin/env bash
# Durable validation runner — pending-results delivery substrate (spec §4). Sourced by the three
# readers (validations-pending-apply.sh for the supervisor pass + SessionStart hook,
# govern-validations.sh for the on-demand surface); definitions only.
#
# Interface contract (OWNED by sibling ticket #5 — consume, never edit): a job dir
# logs/govern/validations/<job>/ carries status.jsonl (one JSON object per phase boundary:
# {ts, phase, deploys, verdict, evidence} — verdict is null until a terminal PASS/FAIL/ABORT/ERROR
# line) and a heartbeat file (mtime = process liveness). This module owns exactly ONE new file per
# job dir: pending-result.json — written atomically (tmp+mv, the escalations-emit-pending.sh pattern)
# the first time a terminal record is observed, then flipped to consumed:true by whichever reader
# applies it first. Applying (registry stamp on PASS / escalation on FAIL·ABORT·ERROR, then mark
# consumed) is serialized under the SAME bookkeep mutex govern::cas_edit uses, so two readers racing
# one terminal job can never double-stamp or double-file.

# ── paths ────────────────────────────────────────────────────────────────────
# Sibling to govern::worker_logdir's $LOG_ROOT/ticket-N convention. Override GOVERN_VALIDATIONS_DIR
# for tests / a non-default job root.
govern::valpending_dir() { # -> dir
  printf '%s' "${GOVERN_VALIDATIONS_DIR:-$LOG_ROOT/validations}"
}

# job-id shape is `val-<flowid>-<ts>` (spec §1) — ts is the trailing numeric segment; a flow id may
# itself contain digits (e.g. `vastai2`), so only strip a trailing ALL-DIGITS segment, never a mixed one.
govern::valpending_flowid_from_jobid() { # jobid -> flowid
  local jobid="$1" rest tail
  rest="${jobid#val-}"
  tail="${rest##*-}"
  if [[ "$tail" =~ ^[0-9]+$ ]]; then
    printf '%s' "${rest%-"$tail"}"
  else
    printf '%s' "$rest"
  fi
}

# The LAST status.jsonl line carrying a recognized terminal verdict, or empty if the job hasn't
# terminated yet. A malformed line is silently skipped by jq -c (never aborts the scan).
govern::valpending_terminal_record() { # jobdir -> json line | ""
  local f="$1/status.jsonl"
  [[ -f "$f" ]] || return 0
  jq -c 'select(.verdict=="PASS" or .verdict=="FAIL" or .verdict=="ABORT" or .verdict=="ERROR")' \
    "$f" 2>/dev/null | tail -1
}

# Idempotent, atomic (tmp+mv) first-touch emission of pending-result.json for a terminated job.
# rc 0 = emitted (new); rc 1 = no-op (already emitted, or no terminal record yet). Lock-free by
# design: content is DERIVED deterministically from status.jsonl, so two readers racing here at worst
# both write the same bytes and mv picks a winner — the mutex-protected step is APPLY, not emit.
govern::valpending_emit() { # jobdir -> 0 emitted, 1 no-op
  local jobdir="$1"
  local pending="$jobdir/pending-result.json" rec jobid flowid verdict evidence env deploys ts tmp
  [[ -f "$pending" ]] && return 1
  rec="$(govern::valpending_terminal_record "$jobdir")"
  [[ -n "$rec" ]] || return 1
  jobid="$(basename "$jobdir")"
  flowid="$(govern::valpending_flowid_from_jobid "$jobid")"
  verdict="$(printf '%s' "$rec" | jq -r '.verdict // ""' 2>/dev/null)"
  evidence="$(printf '%s' "$rec" | jq -r '.evidence // ""' 2>/dev/null)"
  env="$(printf '%s' "$rec" | jq -r '.env // "local"' 2>/dev/null)"
  deploys="$(printf '%s' "$rec" | jq -c '.deploys // []' 2>/dev/null)"; [[ -n "$deploys" ]] || deploys='[]'
  ts="$(printf '%s' "$rec" | jq -r '.ts // empty' 2>/dev/null)"; [[ -n "$ts" ]] || ts="$(date +%s)"
  tmp="$pending.tmp.$$"
  if jq -n --arg jobId "$jobid" --arg flowId "$flowid" --arg verdict "$verdict" --arg evidence "$evidence" \
        --arg env "$env" --argjson deploys "$deploys" --argjson terminalTs "$ts" --argjson emittedAt "$(date +%s)" \
      '{jobId:$jobId, flowId:$flowId, verdict:$verdict, evidence:$evidence, env:$env, deploys:$deploys,
        terminalTs:$terminalTs, emittedAt:$emittedAt, consumed:false, consumedBy:null, consumedAt:null}' \
      > "$tmp" 2>/dev/null; then
    mv "$tmp" "$pending" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  return 0
}

# First-touch-emit every job dir under <validations-dir>. Prints one job-id per line for jobs that
# got a NEW pending-result.json this call (empty output = nothing new).
govern::valpending_scan() { # [validations-dir]
  local vdir="${1:-$(govern::valpending_dir)}" d
  [[ -d "$vdir" ]] || return 0
  for d in "$vdir"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    govern::valpending_emit "$d" && printf '%s\n' "$(basename "$d")"
  done
  return 0
}

# Apply ONE job's pending-result under the bookkeep mutex: evidence-stamp the flow registry on PASS
# (govern::flows_stamp_from_report — the same primitive bookkeep uses for a ticket resolve), file an
# escalation on FAIL/ABORT/ERROR (govern::file_open_escalation, anchored to a freshly-minted ticket
# number since a validation job isn't itself a ticket), then mark consumed. Re-checks `consumed`
# AFTER acquiring the lock (the double-check that makes the two-reader race safe) — a reader that
# loses the race to acquire finds consumed:true already and returns 1 without touching anything twice.
# rc 0 = applied this call; rc 1 = nothing to do (no pending file, already consumed, or lock busy).
govern::valpending_apply_one() { # jobdir [reader] -> 0 applied, 1 no-op
  local jobdir="$1" reader="${2:-cli}"
  local pending="$jobdir/pending-result.json"
  [[ -f "$pending" ]] || return 1
  local consumed; consumed="$(jq -r '.consumed // false' "$pending" 2>/dev/null || echo true)"
  [[ "$consumed" == "false" ]] || return 1

  local BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}" held=0
  if [[ "${GOVERN_BOOKKEEP_LOCK_HELD:-0}" != "1" ]]; then
    govern::lock_acquire "$BK_LOCK" 60 300 || { govern::log "valpending: bookkeep lock busy >60s — skipping $(basename "$jobdir") this pass"; return 1; }
    held=1
  fi

  # Double-check under the lock — a racing reader may have already consumed this between our
  # unlocked peek above and acquiring the lock.
  consumed="$(jq -r '.consumed // false' "$pending" 2>/dev/null || echo true)"
  if [[ "$consumed" != "false" ]]; then
    [[ "$held" == "1" ]] && govern::lock_release "$BK_LOCK"
    return 1
  fi

  local jobid flowid verdict evidence env meta
  jobid="$(jq -r '.jobId // ""' "$pending" 2>/dev/null)"
  flowid="$(jq -r '.flowId // ""' "$pending" 2>/dev/null)"
  verdict="$(jq -r '.verdict // ""' "$pending" 2>/dev/null)"
  evidence="$(jq -r '.evidence // ""' "$pending" 2>/dev/null)"
  env="$(jq -r '.env // "local"' "$pending" 2>/dev/null)"
  meta="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"

  if [[ "$verdict" == "PASS" && -n "$flowid" ]] && command -v govern::flows_stamp_from_report >/dev/null 2>&1; then
    local report
    report="$(jq -n --arg env "$env" --arg ev "$evidence" '{validation:{environment:$env, evidence:$ev, validatedShas:{}}}')"
    GOVERN_BOOKKEEP_LOCK_HELD=1 govern::flows_stamp_from_report "$report" resolve "$flowid" "$meta" >/dev/null 2>&1 || true
  elif [[ -n "$verdict" && "$verdict" != "PASS" ]]; then
    local n
    n="$(GOVERN_BOOKKEEP_LOCK_HELD=1 govern::next_ticket_number 2>/dev/null || true)"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
      govern::file_open_escalation "$n" "validation job $jobid ($flowid) ended $verdict" \
        "durable validation job $jobid for flow '${flowid:-unknown}' terminated $verdict — evidence: ${evidence:-none}" \
        "adopt this result — file a fix ticket, re-run the flow, or accept it as expected?" \
        "do-the-work | defer | mitigated | keep-open" "validation-job" \
        "operator: do-the-work | defer | mitigated | keep-open" >/dev/null 2>&1 || true
    else
      govern::log "valpending: could not mint an escalation anchor for $jobid — leaving unconsumed for the next pass"
      [[ "$held" == "1" ]] && govern::lock_release "$BK_LOCK"
      return 1
    fi
  fi

  local tmp="$pending.tmp.$$"
  if jq --arg by "$reader" --argjson ts "$(date +%s)" '.consumed=true | .consumedBy=$by | .consumedAt=$ts' \
       "$pending" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$pending" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi

  [[ "$held" == "1" ]] && govern::lock_release "$BK_LOCK"
  return 0
}

# Apply every unconsumed pending-result under <validations-dir>. Prints one job-id per line for
# each job actually applied this call.
govern::valpending_apply_all() { # [validations-dir] [reader]
  local vdir="${1:-$(govern::valpending_dir)}" reader="${2:-cli}" d
  [[ -d "$vdir" ]] || return 0
  for d in "$vdir"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ -f "$d/pending-result.json" ]] || continue
    govern::valpending_apply_one "$d" "$reader" && printf '%s\n' "$(basename "$d")"
  done
  return 0
}

# Seconds since <jobdir>/heartbeat last touched, or "-" if the job has no heartbeat file (a terminal
# job's runner has typically stopped touching it — callers show the verdict instead, see the live
# listing below).
govern::valpending_heartbeat_age() { # jobdir -> seconds | "-"
  local hb="$1/heartbeat" m
  [[ -f "$hb" ]] || { printf '%s' "-"; return 0; }
  m="$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo 0)"
  m="${m//[!0-9]/}"; [[ -n "$m" ]] || m=0
  echo $(( $(date +%s) - m ))
}

# Driver-facing live-jobs surface (spec §4 reader 3/3: `flows status` / `govern validations`).
# Non-terminal job → phase + heartbeat age; terminal (pending or already-consumed) job → its verdict.
govern::valpending_live_listing() { # [validations-dir]
  local vdir="${1:-$(govern::valpending_dir)}" d any=0
  if [[ ! -d "$vdir" ]]; then printf 'No validation jobs (%s).\n' "$vdir"; return 0; fi
  for d in "$vdir"/*/; do
    [[ -d "$d" ]] || continue
    any=1
    d="${d%/}"
    local jobid lastline phase deploys age term
    jobid="$(basename "$d")"
    lastline="$(tail -1 "$d/status.jsonl" 2>/dev/null || true)"
    phase="$(printf '%s' "$lastline" | jq -r '.phase // "unknown"' 2>/dev/null || echo unknown)"
    deploys="$(printf '%s' "$lastline" | jq -r '(.deploys // []) | join(",")' 2>/dev/null || true)"
    term="$(printf '%s' "$lastline" | jq -r 'select(.verdict=="PASS" or .verdict=="FAIL" or .verdict=="ABORT" or .verdict=="ERROR") | .verdict' 2>/dev/null || true)"
    if [[ -n "$term" ]]; then
      printf '  %-28s phase=%-14s TERMINAL=%-6s deploys=%s\n' "$jobid" "$phase" "$term" "${deploys:-none}"
    else
      age="$(govern::valpending_heartbeat_age "$d")"
      printf '  %-28s phase=%-14s heartbeat=%ss ago deploys=%s\n' "$jobid" "$phase" "$age" "${deploys:-none}"
    fi
  done
  [[ "$any" == "1" ]] || printf 'No validation jobs (%s).\n' "$vdir"
  return 0
}
