#!/usr/bin/env bash
# Governor v2 — pure-bash driver. Spends ~zero Claude context itself; Claude is invoked only
# in fresh, bounded sessions: the per-ticket worker (spawn-worker) and the periodic supervisor.
# Usage: run-loop.sh [--dry-run] [--exclude N,N,...] [<ticket-number>]
#   no args        → work the whole eligible backlog sequentially
#   <number>       → work that one ticket only
#   --dry-run      → worker runs plan-mode; merge + bookkeep are skipped (logged)
#   --exclude N,N  → skip these ticket numbers (e.g. a parallel govern session owns them)
#
# GOVERN_ALLOW_CONCURRENT=1 → run alongside another driver (parallel sessions on disjoint
#   tickets, #41): skips the single-run lock; safety comes from the per-ticket claim lock
#   (governor/.locks/ticket-N) + the bookkeep lock. Pair with --exclude to partition the backlog.
#
# Hard bounds (so an unattended run always ends; tune via env):
#   GOVERN_MAX_TICKETS     (20)    stop after this many tickets processed this run
#   GOVERN_MAX_BAD_STREAK  (4)     stop after this many CONSECUTIVE parked/failed
#   GOVERN_MAX_RUNTIME     (14400) stop starting new tickets after this many seconds (~4h, < the 5h window)
#   GOVERN_SUPERVISOR_EVERY(5)     supervisor review cadence (+ on anomaly)
#   GOVERN_WORKER_TIMEOUT  (3600)  per-worker wall-clock cap (enforced in spawn-worker)
#
# Progress preservation (acts like a human reopening sessions — never throws away work):
#   - only a cleanly RESOLVED ticket's worktree is torn down; failed/parked/timed-out worktrees
#     are KEPT on disk (uncommitted work survives) and their path is logged.
#   - before spawning, an existing open PR for the ticket (branch ticket-<N>) is detected and the
#     run RESUMES from it (CI→merge→bookkeep) instead of opening a duplicate PR.
#   - a clean interrupt (SIGINT/SIGTERM) leaves the in-flight ticket in tickets.md + its worktree,
#     so a re-run continues. Resolved tickets are gone from tickets.md; parked are skipped via
#     escalations — so re-running is always safe and resumes where it left off.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

MODE=live; TARGET=""; EXCLUDE_INIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      MODE=dry;;
    --exclude)      shift; EXCLUDE_INIT="${EXCLUDE_INIT:+$EXCLUDE_INIT,}${1//[^0-9,]/}";;
    --exclude=*)    EXCLUDE_INIT="${EXCLUDE_INIT:+$EXCLUDE_INIT,}${1#--exclude=}"; EXCLUDE_INIT="${EXCLUDE_INIT//[^0-9,]/}";;
    [0-9]*)         TARGET="$1";;
    *) govern::die "unknown arg: $1";;
  esac
  shift
done
SUP_EVERY="${GOVERN_SUPERVISOR_EVERY:-5}"
MAX_TICKETS="${GOVERN_MAX_TICKETS:-20}"
MAX_BAD_STREAK="${GOVERN_MAX_BAD_STREAK:-4}"
MAX_RUNTIME="${GOVERN_MAX_RUNTIME:-14400}"
START_EPOCH="$(date +%s)"; INTERRUPTED=0

# --- run lock. Default: single-run (one exclusive driver). GOVERN_ALLOW_CONCURRENT=1 opts into
# parallel drivers on disjoint tickets (#41): the global lock is skipped, and safety comes from
# the per-ticket CLAIM lock (no two drivers work the same ticket) + the bookkeep lock in
# govern-bookkeep.sh (no two drivers race tickets.md). Use --exclude to partition the backlog. ---
LOCK="${GOVERN_LOCK:-$GOVERNOR_DIR/.govern.lock}"; TOOK_LOCK=0; CUR_CLAIM=""
if [[ "${GOVERN_ALLOW_CONCURRENT:-0}" == "1" ]]; then
  govern::log "GOVERN_ALLOW_CONCURRENT=1 — running alongside other drivers (per-ticket claim + bookkeep lock keep tickets.md safe)"
elif mkdir "$LOCK" 2>/dev/null; then
  TOOK_LOCK=1
else
  govern::die "another govern run holds $LOCK — remove it if stale, or set GOVERN_ALLOW_CONCURRENT=1 to run in parallel on disjoint tickets (--exclude)."
fi

RUNDIR="$LOG_ROOT/run-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUNDIR"
STATE="$RUNDIR/state.jsonl"; REVIEW="$RUNDIR/review.md"; : > "$STATE"
# Cross-run, append-only outcome history (#60) — survives across runs so a ticket that fails
# run-after-run is detectable and can be auto-escalated instead of silently re-attempted forever.
HISTORY="${GOVERN_HISTORY_FILE:-$GOVERNOR_DIR/ticket-history.jsonl}"
excludes="$EXCLUDE_INIT"; bad_streak=0; since_review=0; nres=0; npark=0; nfail=0; done_count=0

record() { # ticket status note
  printf '{"ticket":%s,"status":"%s","note":%s}\n' "$1" "$2" "$(jq -Rn --arg s "$3" '$s')" >> "$STATE"
  # #60: persist the outcome to the cross-run history (run id + epoch) — best-effort.
  printf '{"ticket":%s,"run":"%s","status":"%s","ts":%s}\n' "$1" "$(basename "$RUNDIR")" "$2" "$(date +%s)" >> "$HISTORY" 2>/dev/null || true
}
wt_path() { echo "$WORKTREE_BASE/ticket-$1"; }

# #60: trailing CONSECUTIVE failed/timeout outcomes for ticket $1 across the cross-run history
# (a resolved/parked outcome resets the streak). Prints the count (0 if no history).
consecutive_fails() { # ticket -> count
  [[ -f "$HISTORY" ]] || { echo 0; return; }
  jq -s --argjson t "$1" '
    [ .[] | select(.ticket == $t) ] | reverse
    | (reduce .[] as $e ({n:0,stop:false};
        if .stop then .
        elif ($e.status=="failed" or $e.status=="timeout") then {n:(.n+1),stop:false}
        else {n:.n,stop:true} end)).n' "$HISTORY" 2>/dev/null || echo 0
}

# Plain-words session log — written on EVERY exit (clean OR crash/kill/Ctrl-C). Says what ran +
# how long, so an interruption always leaves an explanation behind.
write_summary() {
  local now dur m s reason; now="$(date +%s)"; dur=$(( now - START_EPOCH )); m=$(( dur/60 )); s=$(( dur%60 ))
  reason="completed normally"; [[ "$INTERRUPTED" -eq 1 ]] && reason="INTERRUPTED (crash / kill / Ctrl-C / battery / OOM)"
  local f="$RUNDIR/summary.md"
  {
    echo "# Governor session — $(basename "$RUNDIR")"; echo
    echo "- **Ended:** $reason"
    echo "- **Ran for:** ${m}m ${s}s"
    echo "- **Mode:** $MODE${TARGET:+ (single ticket #$TARGET)}"
    echo "- **Tickets:** processed ${done_count:-0} → ✅ resolved ${nres:-0} · ⏸ parked ${npark:-0} · ✖ failed ${nfail:-0}"; echo
    echo "## What it did, ticket by ticket"
    if [[ -s "$STATE" ]]; then
      jq -r '"- #\(.ticket): \(.status)" + (if (.note//"")!="" then " — \(.note)" else "" end)' "$STATE" 2>/dev/null || cat "$STATE"
    else echo "- (nothing processed yet)"; fi
    echo
    if [[ "${npark:-0}" -gt 0 || "${nfail:-0}" -gt 0 ]]; then
      echo "## Needs you"
      echo "- Open decisions: \`governor/escalations.md\` (\`## Open\`). The /govern relay presents the still-unanswered ones from \`governor/pending-escalations.json\` via AskUserQuestion — answer there and the next run applies them (un-park / migrate-to-parked / add-rule)."
      echo "- Preserved worktrees (work not lost): \`$WORKTREE_BASE/ticket-<N>\`."; echo
    fi
    [[ -s "$REVIEW" ]] && { echo "## Supervisor notes"; cat "$REVIEW"; echo; }
    echo "## To resume"
    echo "- Re-run the governor. Resolved tickets are gone, parked are skipped, an open PR on \`ticket-<N>\` is reused — so it picks up safely where it left off. Nothing is discarded."
  } > "$f" 2>/dev/null || true
  cp "$f" "$LOG_ROOT/last-session.md" 2>/dev/null || true
  govern::log "session summary → $f  (also logs/govern/last-session.md)"
}
on_exit() {
  write_summary
  [[ -n "$CUR_CLAIM" ]] && govern::lock_release "$CUR_CLAIM"   # free the in-flight ticket for a re-run (#41)
  [[ "$TOOK_LOCK" -eq 1 ]] && rmdir "$LOCK" 2>/dev/null || true
}
trap 'on_exit' EXIT
trap 'INTERRUPTED=1; govern::log "INTERRUPTED — in-flight ticket kept in tickets.md + worktree preserved; re-run resumes."; exit 130' INT TERM

govern::log "run $RUNDIR (mode=$MODE, target=${TARGET:-backlog}, max=$MAX_TICKETS, bad-streak=$MAX_BAD_STREAK, runtime=${MAX_RUNTIME}s)"

# #62: close the escalation lifecycle BEFORE selecting tickets — apply any operator answers the
# relay recorded into escalations.md since the last run. "do-the-work" un-parks (the ticket
# becomes selectable again this run); "defer" migrates the ticket to tickets-parked.md; a
# "make this a rule" answer grows preferences.md. Without this, answers stay inert file text and
# parked decisions never migrate (the gap #62 fixes). Live only; dry-run logs intent.
if [[ "$MODE" == "live" ]]; then
  "$DIR/escalations-apply-answers.sh" >&2 || govern::log "escalations-apply-answers failed (non-fatal) — continuing"
else
  govern::log "[dry] would apply recorded escalation answers (un-park / migrate-to-parked / preferences) from escalations.md"
fi

while :; do
  # --- hard bounds: stop BEFORE starting another ticket ---
  if [[ "$done_count" -ge "$MAX_TICKETS" ]]; then govern::log "reached GOVERN_MAX_TICKETS=$MAX_TICKETS — stopping"; break; fi
  elapsed=$(( $(date +%s) - START_EPOCH ))
  if [[ "$elapsed" -ge "$MAX_RUNTIME" ]]; then govern::log "reached GOVERN_MAX_RUNTIME=${MAX_RUNTIME}s (elapsed ${elapsed}s) — stopping"; break; fi

  if [[ -n "$TARGET" ]]; then N="$TARGET"; else N="$("$DIR/select-ticket.sh" "$excludes" 2>/dev/null || true)"; fi
  [[ -n "$N" ]] || { govern::log "no eligible tickets — done"; break; }

  # Per-ticket CLAIM lock (#41): two concurrent drivers must never work the same ticket. Non-
  # blocking — if a live other driver holds it, exclude it this run and pick another (or stop in
  # single-ticket mode). Released after the ticket's outcome; on_exit frees an in-flight claim.
  CUR_CLAIM="$GOVERNOR_DIR/.locks/ticket-$N"
  if [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]] && ! govern::lock_try "$CUR_CLAIM"; then
    govern::log "#$N already claimed by another driver — skipping"
    CUR_CLAIM=""
    [[ -n "$TARGET" ]] && break
    excludes="$excludes,$N"; continue
  fi
  govern::log "=== ticket #$N (elapsed ${elapsed}s, done $done_count/$MAX_TICKETS) ==="

  # --- resume: if a prior (crashed) run already opened a PR for this ticket, don't re-spawn ---
  resumed=""; cf=0
  if [[ "$MODE" == "live" ]]; then
    resumed="$(govern::find_pr "$N" || true)"
    # #60: only consider the cross-run failure streak when there's no PR to resume and we're
    # not targeting a single ticket (an explicit target overrides the auto-escalation).
    [[ -z "$resumed" && -z "$TARGET" ]] && cf="$(consecutive_fails "$N" 2>/dev/null || echo 0)"
  fi
  if [[ -n "$resumed" ]]; then
    set -- $resumed; rrepo="$1"; rpr="$2"; rurl="${3:-}"
    govern::log "found existing PR $rrepo#$rpr for #$N — resuming (no new worker, no duplicate PR)"
    report="$(jq -nc --arg r "$rrepo" --argjson n "$rpr" --arg u "$rurl" \
      '{status:"resolved",pr:{repo:$r,number:$n,url:$u},lessonPatch:null,newTickets:[],crossRefs:{},escalation:null}')"
  elif [[ "${cf:-0}" -ge "${GOVERN_MAX_TICKET_FAILS:-2}" ]]; then
    # #60: this ticket already failed/timed-out on the last N runs — re-attempting it just burns
    # another worker. Auto-escalate it as a systemic blocker (goes under "## Open" → skipped next
    # run too) so the operator/root-cause path takes over instead of an infinite retry.
    govern::log "#$N failed $cf consecutive runs — auto-escalating as a systemic blocker; not re-spawning (#60)"
    report="$(jq -nc --argjson c "$cf" '{status:"parked",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{title:("systemic blocker — " + ($c|tostring) + " consecutive failed runs"),reason:("systemic blocker — failed " + ($c|tostring) + " consecutive runs; needs operator / root-cause, not another auto-retry"),question:"inspect the preserved worktree + worker.jsonl, fix the underlying blocker (or re-scope / close the ticket)",options:[]}}')"
  else
    report="$(GOVERN_MODE="$MODE" "$DIR/spawn-worker.sh" "$N" 2>/dev/null || true)"
  fi

  status="$(printf '%s' "$report" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"
  crossN="$(printf '%s' "$report" | jq -r '((.crossRefs.overlaps//[])+(.crossRefs.dependsOn//[]))|length' 2>/dev/null || echo 0)"
  anomaly=0

  if [[ "$status" == "resolved" ]]; then
    repo="$(printf '%s' "$report" | jq -r '.pr.repo // empty' 2>/dev/null || true)"
    pr="$(printf '%s' "$report" | jq -r '.pr.number // empty' 2>/dev/null || true)"
    mneeded="$(printf '%s' "$report" | jq -r '.migration.needed // false' 2>/dev/null || echo false)"
    mdestr="$(printf '%s' "$report" | jq -r '.migration.destructive // false' 2>/dev/null || echo false)"

    if [[ "$mneeded" == "true" && "$mdestr" == "true" ]]; then
      # DESTRUCTIVE prod migration → never auto-merge; escalate (hard-stop stays for these).
      govern::log "#$N needs a DESTRUCTIVE prod migration ($(printf '%s' "$report" | jq -r '.migration.name // "?"')) — NOT auto-merging; escalating"
      report="$(printf '%s' "$report" | jq -c --arg p "${repo:-?}#${pr:-?}" '.escalation={reason:"destructive prod migration — needs human review + coordinated merge/migrate",question:("review PR "+$p+", apply migration manually, then merge"),options:[]}')"
      status="parked"
    elif [[ "$mneeded" == "true" && -z "${GOVERN_MIGRATE_CMD:-}" ]]; then
      # ADDITIVE prod migration but no migrate command configured → do NOT silently merge-and-forget
      # the code ahead of a schema it needs. Escalate for a manual apply (parked = work preserved).
      govern::log "#$N needs an additive prod migration but no GOVERN_MIGRATE_CMD configured — skipping prod migration; escalating for manual apply"
      report="$(printf '%s' "$report" | jq -c --arg p "${repo:-?}#${pr:-?}" '.escalation={reason:"additive prod migration required but no GOVERN_MIGRATE_CMD configured",question:("review PR "+$p+", apply the additive migration to prod manually, then merge"),options:[]}')"
      status="parked"
    elif [[ -n "$repo" && -n "$pr" ]] && govern::is_merge_repo "$repo"; then
      if [[ "$MODE" == "dry" ]]; then
        govern::log "[dry] would await CI + merge $repo#$pr$([[ "$mneeded" == "true" ]] && echo ' + apply additive prod migration')"
      else
        st="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || echo none)"
        tries=0
        while [[ "$st" == "red" && "$tries" -lt 2 ]]; do
          govern::log "CI red on $repo#$pr — re-dispatching worker to fix (try $((tries+1))/2)"
          GOVERN_FIX_CI="$repo#$pr" GOVERN_MODE="$MODE" "$DIR/spawn-worker.sh" "$N" >/dev/null 2>&1 || true
          st="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || echo none)"; tries=$((tries+1))
        done
        if [[ "$st" == "green" || "$st" == "none" ]]; then
          "$DIR/merge-pr.sh" "$repo" "$pr" || govern::log "merge failed $repo#$pr"
          if [[ "$mneeded" == "true" ]]; then
            # ADDITIVE migration: apply to prod right after merge — old running code ignores the new
            # nullable/default column, new code arrives after, so column exists when needed (safe).
            # Only reached when GOVERN_MIGRATE_CMD is set (empty case parked above).
            #
            # Your GOVERN_MIGRATE_CMD MUST fast-forward the relevant checkout to origin/main BEFORE it
            # inspects/applies migration status. A migrate tool reads the migration dirs ON DISK in the
            # working tree; if the checkout still sits at a pre-merge SHA the just-merged migration dir
            # is absent, status compares an incomplete set, falsely reports "up to date", the apply
            # silently no-ops, and verify then false-alarms as "half-applied" (the #85 stale-checkout
            # bug). If it cannot ff-pull (diverged/dirty) it should REFUSE rather than trust a stale
            # set. Capture its output so the escalation can name the actual failure class.
            govern::log "applying additive prod migration for #$N via GOVERN_MIGRATE_CMD"
            mout="$( cd "$WS_ROOT" && eval "$GOVERN_MIGRATE_CMD" 2>&1 )"; mrc=$?
            if [[ "$mrc" -eq 0 ]] \
               && { [[ -z "${GOVERN_VERIFY_CMD:-}" ]] || ( cd "$WS_ROOT" && eval "$GOVERN_VERIFY_CMD" ) >/dev/null 2>&1; }; then
              govern::log "prod migration applied + verified for #$N"
            else
              # Classify the failure so the operator gets the RIGHT next action (#85): a FAILED/
              # half-applied migration needs a `migrate resolve` (NOT another deploy); a stale/diverged
              # checkout needs reconciling first; anything else is a generic verify miss. The markers
              # below match what the recommended deploy-check emits — emit the same strings from your
              # GOVERN_MIGRATE_CMD to light up the specific guidance.
              if printf '%s' "$mout" | grep -qiE 'FAILED / half-applied|failed state|migrate resolve'; then
                esc_reason='prod migration is in a FAILED / half-applied state after merge — needs `prisma migrate resolve` (do NOT re-run the migrate/deploy step); inspect migration status on prod'
              elif printf '%s' "$mout" | grep -qiE 'ff-pull FAILED|BEHIND origin/main|STALE on-disk'; then
                esc_reason='could not fast-forward the merged checkout to origin/main before applying the migration (local main diverged/dirty, so the migration dir may be absent on disk) — reconcile the checkout, then re-run the migrate step (#85)'
              else
                esc_reason='additive prod migration applied/verify FAILED after merge — check migration status on prod'
              fi
              govern::log "prod migration/verify FAILED for #$N — escalating ($esc_reason)"
              report="$(printf '%s' "$report" | jq -c --arg r "$esc_reason" '.escalation={reason:$r,question:"finish/repair the migration manually",options:[]}')"
              status="parked"
            fi
          fi
        elif [[ "$st" == "red" ]]; then govern::log "CI still red after $tries fixes → failed"; status="failed"; fi
      fi
    elif [[ -n "$repo" ]]; then
      govern::log "$repo#$pr left open (frontend is PR-only)"
    fi
  fi

  case "$status" in
    resolved)
      if [[ "$MODE" == "dry" ]]; then govern::log "[dry] would bookkeep #$N"
      else printf '%s' "$report" | "$DIR/govern-bookkeep.sh" "$N" >&2 || govern::log "bookkeep failed #$N"; fi
      record "$N" resolved "$(printf '%s' "$report" | jq -r '.pr.url // ""' 2>/dev/null || true)"
      nres=$((nres+1)); since_review=$((since_review+1)); bad_streak=0
      # only a cleanly-resolved worktree is torn down (live, real worktree only).
      if [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" && -z "$resumed" ]]; then
        # Direct bash (not `$ROOT_PM run`): pnpm v11's pre-run gate aborts in a non-TTY
        # shell before the script runs; our worktree scripts are PM-agnostic, so call them directly.
        ( cd "$WS_ROOT" && bash "$WS_ROOT/scripts/worktree/rm.sh" "ticket-$N" --force >/dev/null 2>&1 ) \
          || govern::log "worktree:rm ticket-$N failed — clean up manually"
      fi
      [[ "$crossN" -gt 0 ]] && { anomaly=1; govern::log "worker flagged $crossN cross-ref(s) on #$N"; }
      ;;
    parked)
      # #58: the heading is a short slug (escalation.title if the worker gave one, else the first
      # 80 chars of reason) so the escalations list stays scannable; the full prose lives under Reason.
      # #62: the Disposition field carries a machine-readable token the relay writes when the
      # operator answers (do-the-work | defer | keep-open); escalations-apply-answers.sh reads it
      # at the next run-start to un-park / migrate-to-parked, closing the lifecycle. Options is the
      # worker's known choices, surfaced to the operator by the relay.
      { printf '\n### #%s — %s\n- **Reason:** %s\n- **Question:** %s\n- **Options:** %s\n- **Answer:** _(operator)_\n- **Disposition:** _(operator: do-the-work | defer | keep-open)_\n- **Make this a rule?:** _(operator)_\n' \
          "$N" "$(printf '%s' "$report" | jq -r '.escalation.title // ((.escalation.reason // "parked")[0:80])')" \
          "$(printf '%s' "$report" | jq -r '.escalation.reason // ""')" \
          "$(printf '%s' "$report" | jq -r '.escalation.question // ""')" \
          "$(printf '%s' "$report" | jq -r '(.escalation.options // []) | if type=="array" then join(" / ") else tostring end')"
      } >> "$ESCALATIONS_FILE" 2>/dev/null || true
      record "$N" parked "escalated; worktree preserved: $(wt_path "$N")"
      govern::log "#$N PARKED — escalation filed; worktree PRESERVED at $(wt_path "$N")"
      excludes="$excludes,$N"; npark=$((npark+1)); bad_streak=$((bad_streak+1))
      ;;
    *)
      record "$N" failed "see $LOG_ROOT/ticket-$N/worker.jsonl; worktree preserved: $(wt_path "$N")"
      govern::log "#$N FAILED — worktree PRESERVED at $(wt_path "$N") (nothing discarded; re-run resumes)"
      excludes="$excludes,$N"; nfail=$((nfail+1)); bad_streak=$((bad_streak+1))
      ;;
  esac

  # release this ticket's claim now its outcome is recorded (#41)
  [[ -n "$CUR_CLAIM" ]] && { govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""; }

  [[ "$bad_streak" -ge "$MAX_BAD_STREAK" ]] && anomaly=1

  if [[ "$anomaly" -eq 1 || "$since_review" -ge "$SUP_EVERY" ]]; then
    govern::log "supervisor review (anomaly=$anomaly, since_review=$since_review)"
    verdict="$("$DIR/govern-supervise.sh" "$RUNDIR" 2>/dev/null || echo '{"verdict":"ok"}')"
    since_review=0
    concerns="$(printf '%s' "$verdict" | jq -r '(.concerns // [])|join("; ")' 2>/dev/null || true)"
    [[ -n "$concerns" ]] && printf -- '- after #%s: %s\n' "$N" "$concerns" >> "$REVIEW"
    if [[ "$(printf '%s' "$verdict" | jq -r '.verdict // "ok"' 2>/dev/null)" == "halt" ]]; then
      govern::log "SUPERVISOR HALT: $(printf '%s' "$verdict" | jq -r '.haltReason // ""')"; break
    fi
  fi

  done_count=$((done_count+1))
  if [[ "$bad_streak" -ge "$MAX_BAD_STREAK" ]]; then govern::log "circuit breaker: $bad_streak consecutive parked/failed — halting"; break; fi
  [[ -n "$TARGET" ]] && break
done

# #62: run-end operator hand-off. The driver is headless, so without this a parked decision is
# write-only — it lands in escalations.md and nothing ever asks the operator. Emit a
# machine-readable governor/pending-escalations.json of the still-unanswered "## Open" entries so
# the launching /govern relay can present them via AskUserQuestion + record answers (which the
# NEXT run-start applies). Also fires GOVERN_NOTIFY_CMD when pending escalations exist, so a
# no-session run still surfaces a signal.
if [[ "$MODE" == "live" ]]; then
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" >/dev/null 2>&1 \
    || govern::log "escalations-emit-pending failed (non-fatal)"
fi

# Self-improvement (observe → propose, never auto-apply): when a run hit friction, a fresh
# read-only reviewer proposes concrete harness improvements into governor/improvements.md.
if [[ "${GOVERN_IMPROVE:-1}" == "1" && "$MODE" == "live" ]] \
   && { [[ "${nfail:-0}" -gt 0 ]] || [[ "${npark:-0}" -gt 0 ]] || [[ -s "$REVIEW" ]]; }; then
  govern::log "self-improvement review → governor/improvements.md"
  "$DIR/govern-improve.sh" "$RUNDIR" >/dev/null 2>&1 || govern::log "improve step skipped (error)"
fi

# Opt-in guarded auto-apply (GOVERN_SELF_APPLY=1): apply ONE proposal under strict guards; the
# change takes effect next run. Default off — observe→propose is the default posture.
if [[ "${GOVERN_SELF_APPLY:-0}" == "1" && "$MODE" == "live" ]]; then
  "$DIR/govern-self-apply.sh" "$RUNDIR" 2>&1 | sed 's/^/[self-apply] /' || true
fi

govern::log "DONE — resolved=$nres parked=$npark failed=$nfail (processed $done_count) | state=$STATE review=$REVIEW"
[[ "$npark" -gt 0 || "$nfail" -gt 0 ]] && govern::log "preserved worktrees for parked/failed tickets remain under $WORKTREE_BASE/ — review then '$ROOT_PM run worktree:rm -- ticket-<N>'"
exit 0
