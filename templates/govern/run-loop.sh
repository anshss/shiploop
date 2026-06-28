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
START_EPOCH="$(date +%s)"; INTERRUPTED=0; INFRA_HALT=0; INFRA_HALT_ERR=""

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
# #75: every worker spawned this run writes its log under $RUNDIR/ticket-N/ (via govern::worker_logdir),
# so a re-run of ticket N can never read a PRIOR run's stale worker.jsonl. Exported so spawn-worker
# (a child process) inherits it.
export GOVERN_RUN_DIR="$RUNDIR"
# TokenJam cross-session run id — ONE per loop invocation, shared by every worker this run spawns.
# TokenJam groups all sessions that share a `tokenjam.run_id` OTel resource attribute into a single
# "Run", so a whole governor run shows up as one unit. Generate the id here (before the ticket loop),
# persist it, and EXPORT it; spawn-worker.sh stamps it into each worker claude's
# OTEL_RESOURCE_ATTRIBUTES. The file lets a crashed/interrupted run that gets RE-RUN resume under the
# SAME id (its workers still group with the original Run) — on_exit removes it on a CLEAN finish so
# the next genuine invocation starts a fresh Run. Format/path overridable for tests.
#
# Freshness guard (#3): only ADOPT a persisted id when the file is still FRESH. tj_heartbeat (below)
# bumps the file's mtime every loop iteration, so "age" measures time since the run's last activity,
# NOT time since it started — a resume happens shortly after a crash and re-adopts, while a STALE
# leftover from an unrelated earlier run is ignored so its id can't silently swallow this run into the
# same Run. The window auto-scales past one ticket's max wall-clock (worker timeout + 1h) so a mid-run
# resume always re-adopts; override with GOVERN_RUN_ID_MAX_AGE.
TJ_RUN_ID_FILE="${GOVERN_RUN_ID_FILE:-$GOVERNOR_DIR/.run-id}"
TJ_RUN_ID_MAX_AGE="${GOVERN_RUN_ID_MAX_AGE:-$(( ${GOVERN_WORKER_TIMEOUT:-3600} + 3600 ))}"
if [[ -s "$TJ_RUN_ID_FILE" ]]; then
  if [[ "$(govern::_lock_age "$TJ_RUN_ID_FILE")" -le "$TJ_RUN_ID_MAX_AGE" ]]; then
    TJ_RUN_ID="$(tr -d '[:space:]' < "$TJ_RUN_ID_FILE" 2>/dev/null || true)"
  else
    govern::log "ignoring stale run-id file ($(govern::_lock_age "$TJ_RUN_ID_FILE")s old > ${TJ_RUN_ID_MAX_AGE}s) — starting a fresh TokenJam Run"
  fi
fi
if [[ -z "${TJ_RUN_ID:-}" ]]; then
  TJ_RUN_ID="gov-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$(dirname "$TJ_RUN_ID_FILE")" 2>/dev/null || true
fi
printf '%s\n' "$TJ_RUN_ID" > "$TJ_RUN_ID_FILE" 2>/dev/null || true   # (re)stamp content + mtime at run start
export TJ_RUN_ID
govern::log "TokenJam run id: $TJ_RUN_ID (every worker tagged tokenjam.run_id=$TJ_RUN_ID)"
STATE="$RUNDIR/state.jsonl"; REVIEW="$RUNDIR/review.md"; : > "$STATE"
# Cross-run, append-only outcome history (#60) — survives across runs so a ticket that fails
# run-after-run is detectable and can be auto-escalated instead of silently re-attempted forever.
HISTORY="${GOVERN_HISTORY_FILE:-$GOVERNOR_DIR/ticket-history.jsonl}"
excludes="$EXCLUDE_INIT"; bad_streak=0; since_review=0; nres=0; npark=0; nfail=0; done_count=0
# #92: PRIORITY = comma list of ticket numbers a supervisor flagged "attempt-now" (e.g. a just-
# merged dependency unblocked one) — drained BEFORE normal severity selection so the advice changes
# behavior, not just the log. NA_SET = comma-wrapped set of "NOT govern-automatable" tickets (bold
# marker in body); select-ticket already excludes them, this set lets the loop log the why + keep a
# prioritized pick from ever resurrecting one.
PRIORITY=""; NA_SET=","

record() { # ticket status note
  printf '{"ticket":%s,"status":"%s","note":%s}\n' "$1" "$2" "$(jq -Rn --arg s "$3" '$s')" >> "$STATE"
  # #60: persist the outcome to the cross-run history (run id + epoch) — best-effort.
  # #90: NEVER record an infra/auth outage to the cross-run history — it is not the ticket's fault,
  # so it must not count toward #60 auto-escalation or be read back by govern-improve as a hard
  # ticket. (It still lands in this run's STATE above, for the human-readable session summary.)
  case "$2" in infra) return 0;; esac
  printf '{"ticket":%s,"run":"%s","status":"%s","ts":%s}\n' "$1" "$(basename "$RUNDIR")" "$2" "$(date +%s)" >> "$HISTORY" 2>/dev/null || true
}
wt_path() { echo "$WORKTREE_BASE/ticket-$1"; }

# TokenJam: bump the run-id file's mtime so its age reflects LIVENESS (the run-start freshness guard
# reads it to tell a prompt resume from an unrelated stale leftover) — and self-heal it if a concurrent
# driver's clean exit removed it out from under us. Cheap; once per ticket iteration is ample.
tj_heartbeat() {
  [[ -n "${TJ_RUN_ID_FILE:-}" && -n "${TJ_RUN_ID:-}" ]] || return 0
  if [[ -s "$TJ_RUN_ID_FILE" ]]; then touch "$TJ_RUN_ID_FILE" 2>/dev/null || true
  else printf '%s\n' "$TJ_RUN_ID" > "$TJ_RUN_ID_FILE" 2>/dev/null || true; fi
}

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

# Reclaim disk from a PRESERVED (parked/failed) worktree WITHOUT discarding any work.
# node_modules / .next / dist are gitignored + regenerable — never uncommitted work — so
# stripping them frees the bulk of a bootstrapped worktree while keeping the source checkout +
# any diffs for inspection/resume. This is what stops a run from self-bricking: a handful of parks
# no longer fills the disk (#48). Skipped in dry mode and when a worktree-cmd override is set (tests).
slim_worktree() {
  [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]] || return 0
  local wt; wt="$(wt_path "$1")"; [[ -d "$wt" ]] || return 0
  local before after
  before=$(du -sm "$wt" 2>/dev/null | awk '{print $1}')
  find "$wt" -type d \( -name node_modules -o -name .next -o -name dist \) -prune -exec rm -rf {} + 2>/dev/null || true
  after=$(du -sm "$wt" 2>/dev/null | awk '{print $1}')
  govern::log "slimmed worktree ticket-$1: ${before:-?}MB → ${after:-?}MB (node_modules/.next/dist stripped; source + diffs kept)"
}

# Plain-words session log — written on EVERY exit (clean OR crash/kill/Ctrl-C). Says what ran +
# how long, so an interruption always leaves an explanation behind.
write_summary() {
  local now dur m s reason; now="$(date +%s)"; dur=$(( now - START_EPOCH )); m=$(( dur/60 )); s=$(( dur%60 ))
  reason="completed normally"; [[ "$INTERRUPTED" -eq 1 ]] && reason="INTERRUPTED (crash / kill / Ctrl-C / battery / OOM)"
  [[ "${INFRA_HALT:-0}" -eq 1 ]] && reason="HALTED — infra/auth outage: ${INFRA_HALT_ERR:-unknown} (re-auth: \`claude login\`, then re-run)"
  local f="$RUNDIR/summary.md"
  {
    echo "# Governor session — $(basename "$RUNDIR")"; echo
    echo "- **Ended:** $reason"
    echo "- **Ran for:** ${m}m ${s}s"
    echo "- **Mode:** $MODE${TARGET:+ (single ticket #$TARGET)}"
    echo "- **Tickets:** processed ${done_count:-0} → ✅ resolved ${nres:-0} · ⏸ parked ${npark:-0} · ✖ failed ${nfail:-0}"; echo
    if [[ "${INFRA_HALT:-0}" -eq 1 ]]; then
      echo "## ⚠ Action needed — re-authenticate / restore connectivity"
      echo "- The run HALTED because workers could not authenticate or reach the API: \`${INFRA_HALT_ERR:-unknown}\`."
      echo "- Fix: run \`claude login\` (or restore network / VPN), then re-run the governor."
      echo "- No ticket was recorded as \`failed\` — affected tickets keep clean cross-run history and are retried next run (#90)."; echo
    fi
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
  # TokenJam run id: KEEP the run-id file on an INTERRUPTED / infra-halted run so a resume reuses the
  # same id (its workers still group with the original Run); REMOVE it on a clean finish so the next
  # invocation starts a fresh Run (one run id per loop invocation).
  if [[ "${INTERRUPTED:-0}" -eq 0 && "${INFRA_HALT:-0}" -eq 0 && -n "${TJ_RUN_ID_FILE:-}" ]]; then
    rm -f "$TJ_RUN_ID_FILE" 2>/dev/null || true
  fi
  [[ -n "$CUR_CLAIM" ]] && govern::lock_release "$CUR_CLAIM"   # free the in-flight ticket for a re-run (#41)
  [[ "$TOOK_LOCK" -eq 1 ]] && rmdir "$LOCK" 2>/dev/null || true
}
trap 'on_exit' EXIT
trap 'INTERRUPTED=1; govern::log "INTERRUPTED — in-flight ticket kept in tickets.md + worktree preserved; re-run resumes."; exit 130' INT TERM

govern::log "run $RUNDIR (mode=$MODE, target=${TARGET:-backlog}, max=$MAX_TICKETS, bad-streak=$MAX_BAD_STREAK, runtime=${MAX_RUNTIME}s)"

# Meta-repo checkout root that owns the queue/ folder (== origin/main for the harness lane). Resolved
# via the git toplevel (NOT dirname "$TICKETS_FILE", which is now the queue/ subfolder) so the
# run-start preflight (#71) and the per-ticket cross-driver re-verify (#108) operate on the repo root.
META_DIR="$(govern::meta_root)"

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

# #71: run-start preflight — reconcile the meta checkout's main with origin/main BEFORE cutting any
# harness-lane PR. The harness lane branches every ticket-<N> PR off main; a stale/ahead/DIVERGED
# local main (e.g. one pre-existing unpushed commit + a squash-merged harness PR) otherwise makes
# every later harness PR conflict on tickets.md → un-mergeable → parked, cascading the whole run.
# preflight-main.sh auto-reconciles (ff / push / rebase+push); it returns non-zero ONLY when main
# truly diverged and couldn't be reconciled — then we HALT with one clear message instead of
# silently cascading. Live only (dry-run logs intent).
if [[ "$MODE" == "live" ]]; then
  "$DIR/preflight-main.sh" "$META_DIR" \
    || govern::die "run-start preflight: could NOT reconcile the meta-repo main checkout with origin/main — see the SPECIFIC reason logged just above (an uncommitted runtime artifact to commit/stash, a genuine rebase conflict, or a rejected push), not necessarily a divergence. Until reconciled, the harness lane would cut PRs off a stale base (#71). Resolve it — e.g. cd '$META_DIR' && git status && git pull --rebase origin main && git push — then re-run."
else
  govern::log "[dry] would preflight-reconcile meta main with origin/main before the harness lane (#71)"
fi

# #92: announce (once) every ticket auto-skipped because its body carries a "NOT govern-automatable"
# marker. select-ticket.sh excludes them silently (its stderr is suppressed by the caller), so
# WITHOUT this log the skip would be invisible — the operator would never learn why a marked ticket
# is never picked. They stay in tickets.md until a human handles them interactively / un-parks them.
# #120: a ticket auto-skipped as NOT-automatable for K consecutive runs (GOVERN_NA_NUDGE_AFTER,
# default 3) churns a skip note every run but never leaves the live queue. After K, file ONE
# escalation recommending the operator escalate+defer it permanently (→ tickets-parked.md) instead
# of re-noting it forever. One-time: guarded by an existing-open-escalation check so it isn't re-filed
# while the prior recommendation is still awaiting an answer. The streak is reset (na_skip_prune below)
# for any ticket no longer NA, so a re-marked/resolved ticket never triggers a stale nudge.
NA_NUDGE_AFTER="${GOVERN_NA_NUDGE_AFTER:-3}"
while IFS=$'\t' read -r na_n na_reason; do
  [[ -n "$na_n" ]] || continue
  NA_SET+="$na_n,"
  govern::log "auto-skipping #$na_n — body marked '$na_reason' (not govern-automatable; handle interactively) — not selecting, no worker burned (#92)"
  if [[ "$MODE" == "live" ]]; then
    na_count="$(govern::na_skip_bump "$na_n" 2>/dev/null || echo 0)"
    if [[ "${na_count:-0}" -ge "$NA_NUDGE_AFTER" ]] && ! govern::has_open_escalation "$na_n"; then
      govern::log "#$na_n auto-skipped $na_count consecutive runs ('$na_reason') — filing a one-time escalation to PERMANENTLY remove it from the live queue (#120)"
      govern::file_open_escalation "$na_n" \
        "permanently park chronically-skipped '$na_reason' ticket" \
        "auto-skipped as '$na_reason' for $na_count consecutive govern runs — it can't be resolved headlessly and is churning a skip note every run instead of leaving the live queue (#120)" \
        "remove it from the live queue: answer Disposition 'defer' to migrate it to tickets-parked.md (or 'do-the-work' to keep retrying it, 'keep-open' to leave it in the live queue)" \
        "defer (recommended) / do-the-work / keep-open"
    fi
  fi
done < <(govern::not_automatable_tickets "$TICKETS_FILE")
# #120: reset the consecutive-skip streak for any ticket no longer NA (resolved / un-marked) so a
# stale count can never fire a spurious nudge. NA_SET is comma-wrapped (",N,N,") — "," resets all.
[[ "$MODE" == "live" ]] && govern::na_skip_prune "$NA_SET"

# #119: cross-run wait-for-merge / dependency deferrals. skipThisRun (#57) is in-memory only, so a
# supervisor "defer #N until PR #M merges" advisory evaporated at run-end and the selector re-picked
# the blocked ticket next run. We persist such waits to governor/pending-waits.json and, at run-start,
# re-check each blocker: a wait whose PR is still OPEN (or whose depended-on ticket is still in
# tickets.md) RE-EXCLUDES its ticket; a cleared wait (PR merged/closed, dep resolved, ticket gone) is
# dropped so the ticket is selectable again. WAIT_EXCLUDES tracks the tickets a wait deferred THIS run
# (comma-wrapped) so an in-run attemptNext (#92) — its blocker landed mid-run — can clear the wait.
WAIT_EXCLUDES=","
if [[ "$MODE" == "live" ]]; then
  while IFS=$'\t' read -r _wt _wwhy; do
    [[ "$_wt" =~ ^[0-9]+$ ]] || continue
    WAIT_EXCLUDES+="$_wt,"; excludes="${excludes:+$excludes,}$_wt"
    govern::log "#$_wt still blocked — $_wwhy; deferring (cross-run wait persists) (#119)"
  done < <(govern::waits_refresh)
else
  govern::log "[dry] would re-check governor/pending-waits.json + defer tickets whose blocker is unresolved (#119)"
fi

while :; do
  tj_heartbeat   # keep the run-id file fresh (liveness) so a prompt resume re-adopts this run's id (#3)
  # --- hard bounds: stop BEFORE starting another ticket ---
  if [[ "$done_count" -ge "$MAX_TICKETS" ]]; then govern::log "reached GOVERN_MAX_TICKETS=$MAX_TICKETS — stopping"; break; fi
  elapsed=$(( $(date +%s) - START_EPOCH ))
  if [[ "$elapsed" -ge "$MAX_RUNTIME" ]]; then govern::log "reached GOVERN_MAX_RUNTIME=${MAX_RUNTIME}s (elapsed ${elapsed}s) — stopping"; break; fi
  # Pre-flight disk guard (#48): never cascade phantom fast-fails on a full disk. If free space
  # is below the worktree headroom, stop CLEANLY with a distinct reason — a disk artifact must
  # not masquerade as worker failures and trip the bad-streak brake. Preserved worktrees are
  # slimmed on park/fail, so this rarely fires; it's the backstop when it does.
  if [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
    free_gb=$(df -k "$HOME" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    if [[ "${free_gb:-99}" -lt "${GOVERN_MIN_FREE_GB:-5}" ]]; then
      govern::log "disk low (${free_gb}GB < ${GOVERN_MIN_FREE_GB:-5}GB) — stopping cleanly. Free space or resolve escalations to reclaim parked worktrees, then re-run."
      break
    fi
  fi

  if [[ -n "$TARGET" ]]; then
    N="$TARGET"
  else
    # #92: drain the supervisor's "attempt-now" PRIORITY queue before normal severity selection,
    # so an "unblocked-now" recommendation actually moves the ticket to the front. Pop the first
    # entry that's still eligible (not excluded, not NOT-automatable, still in tickets.md); carry
    # the rest forward. Fall back to the severity-ordered selector when the queue yields nothing.
    N=""
    if [[ -n "$PRIORITY" ]]; then
      _newpri=""
      for p in ${PRIORITY//,/ }; do
        [[ -n "$p" ]] || continue
        if [[ -z "$N" && ",$excludes," != *",$p,"* && "$NA_SET" != *",$p,"* ]] \
             && grep -qE "^## #$p([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null; then
          N="$p"; govern::log "supervisor → attempting #$p now (prioritized over severity order) (#92)"
        else
          _newpri="${_newpri:+$_newpri,}$p"
        fi
      done
      PRIORITY="$_newpri"
    fi
    [[ -n "$N" ]] || N="$("$DIR/select-ticket.sh" "$excludes" 2>/dev/null || true)"
  fi
  [[ -n "$N" ]] || { govern::log "no eligible tickets — done"; break; }

  # Per-ticket CLAIM lock (#41): two concurrent drivers must never work the same ticket. Non-
  # blocking — if another driver holds it, exclude it this run and pick another (or stop in
  # single-ticket mode). Released after the ticket's outcome; on_exit frees an in-flight claim.
  # #104: take the claim in EVERY mode (dry too), not just live. The acquire/release is purely a
  # mkdir/rmdir under governor/.locks — no PR, no commit, no real side effect — so a dry dual-run
  # faithfully REHEARSES the no-double-claim safety net (two dry drivers on the same backlog with
  # NO --exclude visibly contend on .locks/ticket-N) without opening a single real PR. The
  # live-only gate stays on merge/bookkeep/worktree teardown (those DO have side effects); the
  # claim does not.
  CUR_CLAIM="$GOVERNOR_DIR/.locks/ticket-$N"
  if ! govern::lock_try "$CUR_CLAIM"; then
    govern::log "#$N already claimed by another driver — skipping"
    CUR_CLAIM=""
    [[ -n "$TARGET" ]] && break
    excludes="$excludes,$N"; continue
  fi

  # #108: cross-driver re-verify — confirm #N still exists on origin/main BEFORE spawning. With
  # parallel drivers sharing one origin (GOVERN_ALLOW_CONCURRENT=1, #41), another driver may have
  # resolved+deleted #N (and pushed) AFTER this driver last pulled, so the LOCAL tickets.md that
  # select-ticket read is stale and still lists an already-resolved ticket. The per-ticket claim
  # lock (above) is a local-FS mutex — it does NOT serialize across drivers/origin — so without
  # this fresh origin check the loop would burn a worker (and risk a duplicate PR / re-merge)
  # re-processing a ticket one driver already shipped. Fail-open (no origin / offline /
  # GOVERN_NO_PUSH → present), so a local-only repo or a network blip never wrongly skips a ticket.
  if [[ "$MODE" == "live" && -z "$TARGET" ]] && ! govern::ticket_present_on_origin "$META_DIR" "$N"; then
    govern::log "#$N no longer on origin/main (resolved+pushed by a concurrent driver) — skipping, no worker burned (#108)"
    govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""
    excludes="$excludes,$N"; continue
  fi

  # #119: pre-spawn dependency gate. If #N's body declares **Depends on:** #K and #K is STILL in
  # tickets.md (unlanded), defer #N this run instead of burning a worker building on something not yet
  # merged (the #80-class wasted run). Same in-run exclude as an escalation skip; the dep is re-derived
  # from the body each run, so #N becomes selectable automatically once #K lands — no persistence needed.
  # Skipped for an explicit single-ticket TARGET (the operator chose it deliberately, like the #60 override).
  if [[ -z "$TARGET" ]]; then
    _unmet=""
    while IFS= read -r _k; do
      [[ "$_k" =~ ^[0-9]+$ ]] || continue
      grep -qE "^## #$_k([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null && _unmet="${_unmet:+$_unmet, }#$_k"
    done < <(govern::ticket_deps "$N" "$TICKETS_FILE")
    if [[ -n "$_unmet" ]]; then
      govern::log "#$N depends on unresolved $_unmet (still in tickets.md) — deferring this run, no worker burned (#119)"
      govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""
      excludes="$excludes,$N"; continue
    fi
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

  # #90: spawn-worker tags an INFRA/auth outage (expired token, API unreachable, network down) as
  # status:"infra" — NOT a ticket fault. Retry ONCE after a short pause to ride out a transient
  # network blip; if it's still infra, the outage is real (every subsequent worker would fail
  # identically) and the `infra` case below HALTS the run with a distinct re-auth signal instead of
  # burning the backlog + tripping the generic bad-streak breaker.
  if [[ "$status" == "infra" && "$MODE" == "live" && -z "$resumed" && "${GOVERN_INFRA_RETRY:-1}" == "1" ]]; then
    ierr="$(printf '%s' "$report" | jq -r '.infra.error // "infra/auth outage"' 2>/dev/null || echo 'infra/auth outage')"
    govern::log "#$N hit an INFRA/auth outage ($ierr) — pausing ${GOVERN_INFRA_RETRY_PAUSE:-20}s, retrying once before halting (#90)"
    sleep "${GOVERN_INFRA_RETRY_PAUSE:-20}"
    report="$(GOVERN_MODE="$MODE" "$DIR/spawn-worker.sh" "$N" 2>/dev/null || true)"
    status="$(printf '%s' "$report" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"
  fi

  crossN="$(printf '%s' "$report" | jq -r '((.crossRefs.overlaps//[])+(.crossRefs.dependsOn//[]))|length' 2>/dev/null || echo 0)"
  anomaly=0

  # #55 safety net: a worker may have OPENED a PR but then failed to emit a valid JSON report
  # (so status came back failed/empty) — and/or pushed a non-standard branch. Before treating
  # this as failed/parked, check for a real open PR for this ticket; if one exists, adopt it as
  # the resolved outcome so the work is merged + bookkept instead of orphaned and re-failed.
  if [[ "$status" != "resolved" && "$MODE" == "live" && -z "$resumed" ]]; then
    found="$(govern::find_pr "$N" || true)"
    if [[ -n "$found" ]]; then
      set -- $found; frepo="$1"; fpr="$2"; furl="${3:-}"
      govern::log "#$N reported '$status' but PR $frepo#$fpr exists — adopting it as resolved (#55)"
      report="$(jq -nc --arg r "$frepo" --argjson n "$fpr" --arg u "$furl" \
        '{status:"resolved",pr:{repo:$r,number:$n,url:$u},lessonPatch:null,newTickets:[],crossRefs:{},escalation:null}')"
      status="resolved"
    fi
  fi

  # #67 VALIDATION-EVIDENCE GATE: a ticket whose deliverable is a LIVE/empirical result (a
  # "VALIDATION"/"SPIKE" ticket, a "**Type:** Validation spike" line, or "live-verify") must NOT
  # be auto-resolved on static code analysis. If the worker didn't actually run the test
  # (validation.ranLiveTest!=true or no evidence), downgrade to parked + escalate so a human (or a
  # properly-equipped re-run) produces real evidence — never silently accept a code-reading verdict.
  # Fires only on validation-type tickets, so ordinary code tickets are unaffected.
  if [[ "$status" == "resolved" && "$MODE" == "live" ]]; then
    tblock="$(awk -v n="$N" 'index($0,"## #" n " ")==1{f=1} f{print} f&&/^---$/{exit}' "$TICKETS_FILE" 2>/dev/null || true)"
    if printf '%s' "$tblock" | grep -qE '^## #[0-9]+ —.*(VALIDATION|SPIKE)|^\*\*Type:\*\*.*([Vv]alidation|[Ss]pike)|[Ll]ive-verif' 2>/dev/null; then
      ranlive="$(printf '%s' "$report" | jq -r '.validation.ranLiveTest // false' 2>/dev/null || echo false)"
      eviden="$(printf '%s' "$report" | jq -r '.validation.evidence // ""' 2>/dev/null || true)"
      if [[ "$ranlive" != "true" || -z "$eviden" ]]; then
        govern::log "#$N is a VALIDATION ticket but the worker gave no live-test evidence (ranLiveTest=$ranlive) — refusing to auto-resolve; parking for a real test (#67 gate). Any worker PR is left open for review."
        report="$(printf '%s' "$report" | jq -c '.status="parked" | .pr=null | .escalation={title:"validation ticket needs a real test",reason:"reported resolved without running the live test — a validation/spike ticket requires empirical evidence (deploy/snapshot/restore/UI run with captured output), not static code analysis",question:"run the actual test and attach evidence, OR confirm it cannot be automated and decide disposition",options:[]}' 2>/dev/null || printf '%s' "$report")"
        status="parked"; anomaly=1
      fi
    fi
  fi

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
          merged=0
          if "$DIR/merge-pr.sh" "$repo" "$pr"; then
            merged=1
          else
            # #71: a "not mergeable" failure is most often a STALE PR base (origin/main moved
            # under the PR), not a real content conflict. Try ONE 'gh pr update-branch' (rebase
            # the PR onto origin/main) + re-await-CI + re-merge before giving up — this auto-clears
            # the common case without an operator. A genuine conflict still falls through to park.
            if [[ "$MODE" == "live" ]] && gh pr update-branch "$pr" --repo "$GITHUB_ORG/$repo" >/dev/null 2>&1; then
              govern::log "merge failed $repo#$pr — rebased PR onto origin/main (gh pr update-branch); re-checking CI + retrying merge [#71]"
              st2="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || echo none)"
              if [[ "$st2" == "green" || "$st2" == "none" ]] && "$DIR/merge-pr.sh" "$repo" "$pr"; then merged=1; fi
            fi
          fi
          if [[ "$merged" == "0" ]]; then
            # Merge FAILED (conflict / failing required check) even after a rebase-onto-origin
            # attempt. Do NOT fall through as "resolved" — that would bookkeep the ticket as done
            # and DELETE its block while the PR sits unmerged (#42). Park instead: keeps the
            # ticket, leaves the PR open, preserves the worktree, and escalates to the operator.
            govern::log "merge failed $repo#$pr — PR left open; parking (ticket NOT deleted) [#42]"
            report="$(printf '%s' "$report" | jq -c --arg p "$repo#$pr" '.escalation={reason:("PR "+$p+" could not be merged (conflict or failing required check) — needs a manual rebase onto origin/main + merge"),question:("rebase "+$p+" onto origin/main, resolve conflicts, then merge"),options:[]}')"
            status="parked"
          elif [[ "$mneeded" == "true" ]]; then
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
      # Insert the escalation UNDER the "## Open" header — NOT at EOF. select-ticket.sh only
      # excludes ticket #s whose `### #N` entry sits beneath "## Open", so an EOF append (which
      # lands under "## Resolved") would NOT be skipped on a resume → the park gets re-attempted.
      _blk="$(mktemp)"
      # #58: the heading is a short slug (escalation.title if the worker gave one, else the first
      # 80 chars of reason) so the Open list stays scannable; the full prose lives under Reason.
      # #62: the Disposition field carries a machine-readable token the relay writes when the
      # operator answers (do-the-work | defer | mitigated | keep-open); escalations-apply-answers.sh
      # reads it at the next run-start to un-park / migrate-to-parked / close-as-mitigated, closing
      # the lifecycle. #121: `mitigated` closes a ticket as accepted-current-state (harm already zero).
      printf '\n### #%s — %s\n- **Reason:** %s\n- **Question:** %s\n- **Options:** %s\n- **Answer:** _(operator)_\n- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_\n- **Make this a rule?:** _(operator)_\n' \
          "$N" "$(printf '%s' "$report" | jq -r '.escalation.title // ((.escalation.reason // "parked")[0:80])')" \
          "$(printf '%s' "$report" | jq -r '.escalation.reason // ""')" \
          "$(printf '%s' "$report" | jq -r '.escalation.question // ""')" \
          "$(printf '%s' "$report" | jq -r '(.escalation.options // []) | if type=="array" then join(" / ") else tostring end')" > "$_blk"
      # #102: a "park WITH mechanical evidence" — the worker ran a scripted recipe (ranLiveTest=true
      # + evidence) and is escalating ONLY the human-judgment residue. Surface that PASS/FAIL table
      # in the escalation so the operator judges WITH the mechanical result, not a park-empty "no
      # test was run". (The mechanical 90% is already done; only the judgment 10% is left.)
      _evid="$(printf '%s' "$report" | jq -r 'if (.validation.ranLiveTest==true) and ((.validation.evidence // "")|length>0) then .validation.evidence else "" end' 2>/dev/null || true)"
      if [[ -n "$_evid" ]]; then
        printf -- '- **Mechanical evidence (recipe ran — judge the residue):** %s\n' "$_evid" >> "$_blk"
        govern::log "#$N parked WITH mechanical evidence — escalating judgment residue only (#102)"
      fi
      if grep -q '^## Open' "$ESCALATIONS_FILE" 2>/dev/null; then
        _tmp="$(mktemp)"
        awk -v bf="$_blk" '{print} /^## Open/ && !done {while ((getline l < bf) > 0) print l; close(bf); done=1}' \
          "$ESCALATIONS_FILE" > "$_tmp" && mv "$_tmp" "$ESCALATIONS_FILE"
      else
        cat "$_blk" >> "$ESCALATIONS_FILE" 2>/dev/null || true
      fi
      rm -f "$_blk"
      record "$N" parked "escalated; worktree preserved: $(wt_path "$N")"
      govern::log "#$N PARKED — escalation filed; worktree PRESERVED at $(wt_path "$N")"
      slim_worktree "$N"
      excludes="$excludes,$N"; npark=$((npark+1)); bad_streak=$((bad_streak+1))
      ;;
    infra)
      # #90: a CONFIRMED infra/auth outage (the retry above also failed, or retry was disabled). NOT
      # a ticket fault: record() drops `infra` from the cross-run history (no #60 pollution), we file
      # NO per-ticket escalation, and it does NOT touch bad_streak. HALT the whole run with a
      # DISTINCT re-auth signal — every subsequent worker would fail identically until the operator
      # re-authenticates (`claude login`) or connectivity is restored. The ticket stays in tickets.md
      # with clean history, so the next (re-authed) run picks it up normally.
      INFRA_HALT_ERR="$(printf '%s' "$report" | jq -r '.infra.error // "infra/auth outage"' 2>/dev/null || echo 'infra/auth outage')"
      INFRA_HALT=1
      record "$N" infra "infra/auth outage — not a ticket fault; worktree preserved: $(wt_path "$N")"
      slim_worktree "$N"
      [[ -n "$CUR_CLAIM" ]] && { govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""; }
      govern::log "INFRA HALT — workers cannot authenticate / reach the API ($INFRA_HALT_ERR). Re-authenticate (\`claude login\`) or restore connectivity, then re-run. #$N and the remaining backlog were NOT recorded as failed (#90)."
      break
      ;;
    *)
      record "$N" failed "see $(govern::worker_logdir "$N")/worker.jsonl; worktree preserved: $(wt_path "$N")"
      govern::log "#$N FAILED — worktree PRESERVED at $(wt_path "$N") (nothing discarded; re-run resumes)"
      slim_worktree "$N"
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
    # #57: the supervisor can defer specific tickets for the rest of THIS run (soft in-run skip —
    # not a park). Add them to the exclude set so select-ticket stops picking them this run.
    for s in $(printf '%s' "$verdict" | jq -r '(.skipThisRun // [])[]' 2>/dev/null || true); do
      if [[ "$s" =~ ^[0-9]+$ && ",$excludes," != *",$s,"* ]]; then
        excludes="$excludes,$s"; govern::log "supervisor → deferring #$s for the rest of this run (skipThisRun)"
      fi
    done
    # #92: the supervisor can also recommend a ticket be ATTEMPTED NOW (e.g. its dependency merged
    # this run → it's unblocked). Enqueue it onto PRIORITY so the next selection picks it before
    # normal severity order — turning the "unblocked-now" advice into an actual selection change,
    # not just a logged concern. Ignored if it's excluded, NOT-automatable, or already queued.
    for a in $(printf '%s' "$verdict" | jq -r '(.attemptNext // [])[]' 2>/dev/null || true); do
      [[ "$a" =~ ^[0-9]+$ ]] || continue
      # #119: an attemptNext for a wait-deferred ticket means the supervisor saw its blocker land THIS
      # run — clear the persisted wait + the in-run exclude so the priority pick can actually fire
      # (otherwise it stays wait-excluded until the next run-start re-check).
      if [[ "$WAIT_EXCLUDES" == *",$a,"* ]]; then
        [[ "$MODE" == "live" ]] && govern::waits_remove "$a"
        WAIT_EXCLUDES=",$(govern::csv_remove "$WAIT_EXCLUDES" "$a"),"
        excludes="$(govern::csv_remove "$excludes" "$a")"
        govern::log "supervisor → #$a unblocked; cleared its pending-wait (#119)"
      fi
      if [[ ",$excludes," != *",$a,"* && "$NA_SET" != *",$a,"* && ",$PRIORITY," != *",$a,"* ]]; then
        PRIORITY="${PRIORITY:+$PRIORITY,}$a"; govern::log "supervisor → will attempt #$a next (attemptNext / unblocked-now) (#92)"
      fi
    done
    # #119: persist supervisor wait-for-merge / dependency deferrals to governor/pending-waits.json so
    # they SURVIVE run-end (skipThisRun #57 is in-memory only). Each {ticket,pr,repo} / {ticket,dependsOn}
    # entry re-excludes its ticket at every subsequent run-start until the blocker lands. Also exclude it
    # for the rest of THIS run (the wait is at least as strong as a skipThisRun).
    while IFS= read -r _w; do
      [[ -n "$_w" ]] || continue
      _wt="$(printf '%s' "$_w" | jq -r '.ticket // empty' 2>/dev/null || true)"
      [[ "$_wt" =~ ^[0-9]+$ ]] || continue
      if [[ "$MODE" == "live" ]]; then
        govern::waits_add "$_w"; govern::log "supervisor → persisted wait for #$_wt → pending-waits.json (survives run-end) (#119)"
      else
        govern::log "[dry] would persist supervisor wait for #$_wt to pending-waits.json (#119)"
      fi
      [[ ",$excludes," != *",$_wt,"* ]] && excludes="${excludes:+$excludes,}$_wt"
      [[ "$WAIT_EXCLUDES" == *",$_wt,"* ]] || WAIT_EXCLUDES+="$_wt,"
    done < <(printf '%s' "$verdict" | jq -c '(.waitForMerge // [])[]' 2>/dev/null || true)
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
  # #92: pass the run's accumulated supervisor concerns ($REVIEW) so they're surfaced to the
  # relay/operator at run-end (folded into pending-escalations.json + the notify message), not
  # buried only in review.md. A concern with no matching escalation would otherwise be invisible.
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" "$REVIEW" >/dev/null 2>&1 \
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

if [[ "${INFRA_HALT:-0}" -eq 1 ]]; then
  govern::log "RUN HALTED on infra/auth outage ($INFRA_HALT_ERR) — re-authenticate (\`claude login\`) or restore connectivity, then re-run. No ticket recorded \`failed\`; affected tickets keep clean #60 history (#90)."
fi
govern::log "DONE — resolved=$nres parked=$npark failed=$nfail (processed $done_count) | state=$STATE review=$REVIEW"
[[ "$npark" -gt 0 || "$nfail" -gt 0 ]] && govern::log "preserved worktrees for parked/failed tickets remain under $WORKTREE_BASE/ — review then '$ROOT_PM run worktree:rm -- ticket-<N>'"
exit 0
