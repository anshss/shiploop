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
#   GOVERN_MAX_RUNTIME     (0)     stop starting new tickets after this many seconds; 0 = no cap (default).
#                                  (MAX_TICKETS + per-worker timeout + bad-streak still bound the run.)
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
MAX_RUNTIME="${GOVERN_MAX_RUNTIME:-0}"   # 0 = no runtime cap (default)
START_EPOCH="$(date +%s)"; INTERRUPTED=0; INFRA_HALT=0; INFRA_HALT_ERR=""
# #151: abnormal-abort + in-flight-ticket tracking. ABORTED/ABORT_RC are set by on_exit when the run
# ends on a non-zero exit that is NOT a handled interrupt or infra halt (e.g. `set -e` fired on an
# unguarded post-merge migrate/verify failure). CUR_TICKET is the ticket currently being processed
# (cleared once it reaches a recorded outcome); CUR_TICKET_MERGED accumulates its merged-but-not-yet-
# bookkept PRs — so an abort/interrupt summary names the abort cause AND surfaces the half-resolved
# ticket instead of silently dropping it.
ABORTED=0; ABORT_RC=0; CUR_TICKET=""; CUR_TICKET_MERGED=""

RUNDIR="$LOG_ROOT/run-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUNDIR"
# #75: every worker spawned this run writes its log under $RUNDIR/ticket-N/ (via govern::worker_logdir),
# so a re-run of ticket N can never read a PRIOR run's stale worker.jsonl. Exported so spawn-worker
# (a child process) inherits it. #183: defined BEFORE the lock so the holder file can record this run id.
export GOVERN_RUN_DIR="$RUNDIR"

# --- run lock. Default: single-run (one exclusive driver). GOVERN_ALLOW_CONCURRENT=1 opts into
# parallel drivers on disjoint tickets (#41): the global lock is skipped, and safety comes from
# the per-ticket CLAIM lock (no two drivers work the same ticket) + the bookkeep lock in
# govern-bookkeep.sh (no two drivers race tickets.md). Use --exclude to partition the backlog.
#
# #183: the lock is SELF-VALIDATING. The holder's run id + pid are recorded INSIDE the lock dir, so a
# second starter that finds the lock occupied checks whether that pid is still ALIVE before deciding:
#   - live, non-self holder → REFUSE (govern::die). Reliable single-run serialization, as designed.
#   - dead / unknown holder → the lock is STALE (a crashed run never reached its on_exit, or it was
#                             left behind); reclaim it automatically so NOBODY ever has to
#                             `rm -rf governor/.govern.lock` by hand. That manual clear was the
#                             footgun behind the #183 symptom: a plain `mkdir` lock with no liveness
#                             check would `die` on a stale lock, so an operator clears it — and if
#                             they misjudge a LIVE lock as stale and remove it, the next start sails
#                             through `mkdir` and you get two unflagged drivers. Pid-checked reclaim
#                             removes the manual clear entirely: a live holder is never reclaimable.
# The run ALWAYS logs which concurrency mode it took (PARALLEL / SINGLE-RUN acquired / stale-reclaimed).
LOCK="${GOVERN_LOCK:-$GOVERNOR_DIR/.govern.lock}"; TOOK_LOCK=0; CUR_CLAIM=""
govern::_lock_holder() { [[ -f "$LOCK/holder" ]] && cat "$LOCK/holder" 2>/dev/null || true; }
govern::_lock_holder_pid() { govern::_lock_holder | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'; }
govern::_stamp_lock() { printf 'run=%s pid=%s started=%s\n' "${RUNDIR##*/}" "$$" "$START_EPOCH" > "$LOCK/holder" 2>/dev/null || true; }
# Take the single-run lock, reclaiming a STALE (dead-holder) one. Returns 0 took, 1 refused.
govern::_take_single_lock() {
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
  if mkdir "$LOCK" 2>/dev/null; then govern::_stamp_lock; return 0; fi
  local hpid age stale="${GOVERN_LOCK_STALE_S:-$(( ${GOVERN_WORKER_TIMEOUT:-3600} + 3600 ))}"
  hpid="$(govern::_lock_holder_pid)"
  if [[ -n "$hpid" ]]; then
    # A holder pid is recorded: refuse iff it is a DIFFERENT, still-running process.
    if [[ "$hpid" != "$$" ]] && kill -0 "$hpid" 2>/dev/null; then return 1; fi
    govern::log "found a STALE .govern.lock (recorded holder pid $hpid is not alive) — reclaiming it"
  else
    # No holder pid (a pre-#183 lock, or a partial write): fall back to mtime — reclaim only if the
    # lock is older than the stale window, else assume a live holder and refuse (don't steal a live lock).
    age="$(govern::_lock_age "$LOCK")"
    if [[ "$age" -le "$stale" ]]; then return 1; fi
    govern::log "found an UNATTRIBUTED .govern.lock with no holder pid, ${age}s old (> ${stale}s) — reclaiming it as stale"
  fi
  rm -rf "$LOCK" 2>/dev/null || true
  if mkdir "$LOCK" 2>/dev/null; then govern::_stamp_lock; return 0; fi
  return 1   # lost a reclaim race to another fresh driver — treat as held
}
if [[ "${GOVERN_ALLOW_CONCURRENT:-0}" == "1" ]]; then
  # #183: ALWAYS make a parallel run unmistakable in the output. The danger isn't the intentional
  # `GOVERN_ALLOW_CONCURRENT=1 --exclude …` partition (claim + bookkeep locks keep that safe, #41) —
  # it's an INHERITED flag: the governor exports its env to every worker, so a run-loop launched from
  # a worker/operator shell that already has GOVERN_ALLOW_CONCURRENT=1 silently skips the single-run
  # lock with no `--exclude` partition. That is the most likely #183 root cause, so call it out loudly
  # when there's no partition signal — the operator scanning the run can then spot an unintended flag.
  if [[ -z "$EXCLUDE_INIT" && -z "$TARGET" ]]; then
    govern::log "concurrency mode: PARALLEL (GOVERN_ALLOW_CONCURRENT=1) with NO --exclude / single ticket — sharing the FULL backlog with any peer driver (per-ticket claim + bookkeep lock keep it exactly-once, #41). ⚠ If you did NOT intend parallel, this flag is likely INHERITED from a governor/worker env — unset GOVERN_ALLOW_CONCURRENT to take the exclusive single-run lock (#183)."
  else
    govern::log "concurrency mode: PARALLEL (GOVERN_ALLOW_CONCURRENT=1) — proceeding alongside other drivers on a partitioned backlog (--exclude / single ticket); per-ticket claim + bookkeep lock keep tickets.md safe (#41)"
  fi
elif govern::_take_single_lock; then
  TOOK_LOCK=1
  govern::log "concurrency mode: SINGLE-RUN — exclusive lock acquired by run ${RUNDIR##*/} pid $$ ($LOCK)"
else
  govern::die "another govern run holds $LOCK (live holder: $(govern::_lock_holder | tr -d '\n')) — wait for it to finish, or set GOVERN_ALLOW_CONCURRENT=1 to run in parallel on disjoint tickets (--exclude). Do NOT delete the lock by hand while that run is live (#183)."
fi
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
excludes="$EXCLUDE_INIT"; bad_streak=0; since_review=0; nres=0; npark=0; nfail=0; ntimeout=0; nintr=0; done_count=0
# #92: PRIORITY = comma list of ticket numbers a supervisor flagged "attempt-now" (e.g. a just-
# merged dependency unblocked one) — drained BEFORE normal severity selection so the advice changes
# behavior, not just the log. NA_SET = comma-wrapped set of "NOT govern-automatable" tickets (bold
# marker in body); select-ticket already excludes them, this set lets the loop log the why + keep a
# prioritized pick from ever resurrecting one.
PRIORITY=""; NA_SET=","

# #272: ROI enrichment for the cross-run history. Reads the just-finished worker's stream-json
# result event for per-ticket token spend + cost, and classifies churn from the current $report's
# PR repos (self-referential harness/templates work vs shipped product). Best-effort — every field
# degrades to null so a missing worker.jsonl or an un-parseable report never blocks the outcome
# record. Emits a JSON object of the extra fields to merge into the history line.
history_enrich() { # ticket -> echoes {tokens,costUsd,churn,repos}
  local n="$1" jsonl toks='null' cost='null' repos='[]' churn='null' res
  jsonl="$(govern::worker_logdir "$n")/worker.jsonl"
  if [[ -s "$jsonl" ]]; then
    res="$(grep '"type":"result"' "$jsonl" 2>/dev/null | tail -1 || true)"
    if [[ -n "$res" ]]; then
      toks="$(printf '%s' "$res" | jq -c '(.usage // {}) as $u
        | {input:($u.input_tokens//0), output:($u.output_tokens//0),
           cacheRead:($u.cache_read_input_tokens//0), cacheCreation:($u.cache_creation_input_tokens//0)}
        | .total = (.input + .output + .cacheRead + .cacheCreation)' 2>/dev/null || echo null)"
      cost="$(printf '%s' "$res" | jq -c '.total_cost_usd // null' 2>/dev/null || echo null)"
    fi
  fi
  # PR repos come from the current $report (loop-scope global). churn = has ≥1 PR AND every PR repo
  # is self-referential; false if it shipped ANY product PR; null when there is no PR to classify.
  repos="$(printf '%s' "${report:-}" | jq -c '[ (.pr // empty), (.prs // [])[] ]
    | map(.repo // empty) | map(select(. != "")) | unique' 2>/dev/null || echo '[]')"
  [[ "$repos" == "null" || -z "$repos" ]] && repos='[]'
  local nrepos nself _r
  nrepos="$(printf '%s' "$repos" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "${nrepos:-0}" -gt 0 ]]; then
    nself=0
    while IFS= read -r _r; do [[ -n "$_r" ]] && govern::is_selfref_repo "$_r" && nself=$((nself+1)); done \
      < <(printf '%s' "$repos" | jq -r '.[]' 2>/dev/null || true)
    if [[ "$nself" -eq "$nrepos" ]]; then churn=true; else churn=false; fi
  fi
  jq -nc --argjson t "$toks" --argjson c "$cost" --argjson ch "$churn" --argjson rp "$repos" \
    '{tokens:$t, costUsd:$c, churn:$ch, repos:$rp}' 2>/dev/null || echo '{}'
}

record() { # ticket status note
  printf '{"ticket":%s,"status":"%s","note":%s}\n' "$1" "$2" "$(jq -Rn --arg s "$3" '$s')" >> "$STATE"
  # #60: persist the outcome to the cross-run history (run id + epoch) — best-effort.
  # #90: NEVER record an infra/auth outage to the cross-run history — it is not the ticket's fault,
  # so it must not count toward #60 auto-escalation or be read back by govern-improve as a hard
  # ticket. (It still lands in this run's STATE above, for the human-readable session summary.)
  # #34: same for `interrupted` — a transient mid-stream connection drop (laptop sleep) is an
  # ENVIRONMENT artifact, not ticket difficulty; recording it would falsely auto-escalate a
  # perfectly-good ticket as a #60 systemic blocker.
  case "$2" in infra|interrupted) return 0;; esac
  # #272: fold in ROI fields (tokens/cost/churn) so govern-health can surface park rate + churn
  # classes + tokens-per-ticket from ONE durable file, with no worker.jsonl spelunking.
  local base extra
  base="$(jq -nc --argjson t "$1" --arg run "$(basename "$RUNDIR")" --arg st "$2" --argjson ts "$(date +%s)" \
    '{ticket:$t, run:$run, status:$st, ts:$ts}' 2>/dev/null \
    || printf '{"ticket":%s,"run":"%s","status":"%s","ts":%s}' "$1" "$(basename "$RUNDIR")" "$2" "$(date +%s)")"
  extra="$(history_enrich "$1" 2>/dev/null || echo '{}')"
  printf '%s\n' "$(jq -c --argjson e "$extra" '. + $e' <<<"$base" 2>/dev/null || printf '%s' "$base")" \
    >> "$HISTORY" 2>/dev/null || true
}
wt_path() { echo "$WORKTREE_BASE/ticket-$1"; }

# #242: every spawn-worker invocation goes through here so the driver always knows the in-flight
# worker's pid and can tear its WHOLE subtree down on a stop. Previously workers were launched via a
# blocking `$(spawn-worker)` command-substitution: a stop/SIGTERM on the driver left the
# spawn-worker.sh + child `claude -p` (+ any tool grandchildren) ALIVE — reparented to init, needing
# a manual `kill -9` sweep; a worker orphaned mid-deploy can hold a billable resource. Now we
# background the worker, record WORKER_PID, and `wait` — `wait` is reliably interrupted by a trapped
# signal (unlike a command substitution, whose trap is deferred until it completes), so the INT/TERM
# trap fires immediately and reaps the tree. Runs ONE worker at a time exactly as before, so a single
# global WORKER_PID is correct. The worker's stdout (its JSON report) is written to $SPAWN_OUT for the
# caller to read; its stderr (govern::log) flows to this function's stderr so callers can /dev/null it.
# Honors any GOVERN_* env the caller sets on the call (bash exports a call-prefix assignment into the
# function's child processes), so the GOVERN_FIX_CI / GOVERN_RESOLVE_CONFLICT re-dispatches work too.
WORKER_PID=""; SPAWN_OUT=""
spawn_worker_tracked() { # ticket -> spawn-worker stdout in $SPAWN_OUT; sets+clears WORKER_PID
  local n="$1"
  SPAWN_OUT="$(mktemp)"
  "$DIR/spawn-worker.sh" "$n" >"$SPAWN_OUT" &
  WORKER_PID=$!
  wait "$WORKER_PID" || true
  WORKER_PID=""
}
# Reap the in-flight worker's whole process subtree on a driver stop (SIGINT/SIGTERM/EXIT). SIGTERM
# to spawn-worker triggers ITS trap (which kills the worker process group cleanly), and the pid-walk
# in govern::kill_tree directly reaches the worker + grandchildren as a backstop — TERM, grace, then KILL.
govern_teardown_worker() {
  [[ -n "${WORKER_PID:-}" ]] || return 0
  govern::log "stop received — tearing down in-flight worker (spawn-worker pid $WORKER_PID) + its worker tree [#242]"
  govern::kill_tree "$WORKER_PID" "${GOVERN_KILL_GRACE_S:-12}"
  WORKER_PID=""
}

# #129: await CI then merge ONE merge-repo PR for the current ticket ($N), with the existing
# CI-fix re-dispatch loop and the #71 stale-base rebase retry. Echoes a single result token:
#   merged      — merged cleanly
#   red         — CI still red after up to $GOVERN_CI_FIX_TRIES fix re-dispatches (default 1)
#   unmergeable — CI green/none but the merge failed (conflict / failing required check), even
#                 after a rebase-onto-origin/main retry (and the #191 conflict re-dispatch)
# Reads $N, $MODE, $DIR from the loop scope. Factored out of the single-PR resolved path so the
# SAME merge discipline applies to every sibling PR of a multi-repo ticket, none orphaned.
merge_pr_for_ticket() { # repo pr -> echoes merged|red|unmergeable|error
  local repo="$1" pr="$2" st tries=0 st2
  # CI-cost: each fix re-dispatch pushes a commit that re-runs the repo's full PR CI (potentially
  # a full container build). Default to ONE retry — a second full-CI attempt on a flapping ticket
  # rarely flips it green and doubles the spend. Tune via GOVERN_CI_FIX_TRIES (0 = park on first
  # red, no fix attempt).
  local max_fix="${GOVERN_CI_FIX_TRIES:-1}"
  # FAIL-CLOSED (#34b): capture await-ci's token; a non-zero 'error' exit (or a crash with no
  # token) degrades to 'error', NEVER to 'none'/mergeable (root cause of the pre-fix auto-merge-
  # without-CI where `… || echo none` conflated a gh error with a genuinely-checkless repo).
  st="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || true)"; [[ -n "$st" ]] || st="error"
  while [[ "$st" == "red" && "$tries" -lt "$max_fix" ]]; do
    govern::log "CI red on $repo#$pr — re-dispatching worker to fix (try $((tries+1))/$max_fix)"
    GOVERN_FIX_CI="$repo#$pr" GOVERN_MODE="$MODE" spawn_worker_tracked "$N" >/dev/null 2>&1 || true
    st="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || true)"; [[ -n "$st" ]] || st="error"; tries=$((tries+1))
  done
  # CI state could not be VERIFIED (gh network/auth/5xx) → park, don't merge blind (#34b).
  if [[ "$st" == "error" ]]; then echo error; return; fi
  if [[ "$st" != "green" && "$st" != "none" ]]; then echo red; return; fi
  # NB: merge-pr.sh stdout (its live `gh pr merge` output / GOVERN_ECHO "WOULD RUN" line) is sent to
  # stderr so this function's ONLY stdout is the result token the caller captures via $().
  # GOVERN_SKIP_CI=1: we JUST confirmed green/none above — skip merge-pr.sh's redundant re-poll.
  # Capture merge-pr.sh's exit CODE explicitly so exit 5 (external-pr-blocked) short-circuits the
  # rebase/conflict-re-dispatch retries — a PR the governor is structurally forbidden to auto-merge
  # cannot be "fixed" by a rebase or a resolve-conflict worker; it's a terminal outcome for this lane.
  set +e
  GOVERN_SKIP_CI=1 "$DIR/merge-pr.sh" "$repo" "$pr" >&2
  local _mrc=$?
  set -e
  if [[ "$_mrc" == "0" ]]; then echo merged; return; fi
  if [[ "$_mrc" == "5" ]]; then echo external-blocked; return; fi
  # #71: a "not mergeable" failure is most often a STALE PR base (origin/main moved under the PR),
  # not a real content conflict. Try ONE 'gh pr update-branch' (rebase onto origin/main) +
  # re-await-CI + re-merge before giving up — auto-clears the common case without an operator.
  if [[ "$MODE" == "live" ]] && gh pr update-branch "$pr" --repo "$(govern::repo_slug "$repo")" >/dev/null 2>&1; then
    govern::log "merge failed $repo#$pr — rebased PR onto origin/main (gh pr update-branch); re-checking CI + retrying merge [#71]"
    st2="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || true)"; [[ -n "$st2" ]] || st2="error"
    if [[ "$st2" == "green" || "$st2" == "none" ]] && GOVERN_SKIP_CI=1 "$DIR/merge-pr.sh" "$repo" "$pr" >&2; then echo merged; return; fi
  fi
  # #191: CI is green/none but the merge still failed even after the #71 rebase-onto-origin/main
  # retry — a genuine CONTENT conflict (the PR and origin/main edited the same lines; e.g. two
  # interdependent un-parked PRs touching one file, landed back-to-back so the 2nd conflicts once
  # the 1st merges). Rather than leave it for a human (#42 park), re-dispatch ONE worker to merge
  # origin/main INTO the ticket-$N branch, resolve the conflict (no force-push — a merge commit),
  # build+test, and push; then re-await CI + retry the merge. Bounded by GOVERN_CONFLICT_FIX_TRIES
  # (default 1; 0 disables) so a genuinely unresolvable conflict still parks cleanly via #42 instead
  # of looping. This is what lets the governor self-clear the 2nd of N interdependent un-parked
  # tickets across at most N passes, with no manual merge.
  local max_conflict="${GOVERN_CONFLICT_FIX_TRIES:-1}" ctries=0 st3
  while [[ "$MODE" == "live" && "$ctries" -lt "$max_conflict" ]]; do
    govern::log "merge still failing $repo#$pr after the #71 rebase retry — content conflict; re-dispatching a worker to merge origin/main + resolve, then retry merge (try $((ctries+1))/$max_conflict) [#191]"
    GOVERN_RESOLVE_CONFLICT="$repo#$pr" GOVERN_MODE="$MODE" spawn_worker_tracked "$N" >/dev/null 2>&1 || true
    ctries=$((ctries+1))
    st3="$("$DIR/await-ci.sh" "$repo" "$pr" 2>/dev/null || true)"; [[ -n "$st3" ]] || st3="error"
    [[ "$st3" == "green" || "$st3" == "none" ]] || continue
    if GOVERN_SKIP_CI=1 "$DIR/merge-pr.sh" "$repo" "$pr" >&2; then echo merged; return; fi
  done
  echo unmergeable
}

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
  reason="completed normally"
  # #151: an ABNORMAL abort (set -e fired mid-run on a non-zero exit, e.g. the post-merge migrate/
  # verify step failed) must NOT read as "completed normally". Name the cause + the in-flight ticket.
  # INTERRUPTED/INFRA below override it — both are more-specific, mutually-exclusive states.
  [[ "${ABORTED:-0}" -eq 1 ]] && reason="ABORTED (exit ${ABORT_RC:-1}) — a step exited non-zero before the loop finished cleanly${CUR_TICKET:+, mid-ticket #$CUR_TICKET}; e.g. a post-merge migrate/verify step failed. See the run log + any ⚠ in-flight note below."
  [[ "$INTERRUPTED" -eq 1 ]] && reason="INTERRUPTED (crash / kill / Ctrl-C / battery / OOM)"
  [[ "${INFRA_HALT:-0}" -eq 1 ]] && reason="HALTED — infra/auth outage: ${INFRA_HALT_ERR:-unknown} (re-auth: \`claude login\`, then re-run)"
  local f="$RUNDIR/summary.md"
  {
    echo "# Governor session — $(basename "$RUNDIR")"; echo
    echo "- **Ended:** $reason"
    echo "- **Ran for:** ${m}m ${s}s"
    echo "- **Mode:** $MODE${TARGET:+ (single ticket #$TARGET)}"
    echo "- **Tickets:** processed ${done_count:-0} → ✅ resolved ${nres:-0} · ⏸ parked ${npark:-0} · ✖ failed ${nfail:-0} · ⏱ timed-out ${ntimeout:-0} · ↻ interrupted ${nintr:-0}"
    # Cost transparency: a per-run spend line — tokens (always, when the worker JSONL carried usage)
    # and dollar cost (only when the JSONL carried total_cost_usd), summed AND per ticket. Reads
    # $HISTORY, where record()/history_enrich already folded each worker's stream-json usage +
    # total_cost_usd. Best-effort + null-safe: a missing/un-parseable field degrades to tokens-only,
    # or the whole line is skipped — it NEVER invents a pricing table (a workspace whose Claude Code
    # emits no cost fields simply gets token counts). Filtered to THIS run by the .run field.
    if [[ -s "$HISTORY" ]]; then
      local _spend
      _spend="$(GOVERN_RUN_ID="$(basename "$RUNDIR")" jq -rs '
        map(select(.run == env.GOVERN_RUN_ID))
        | map(. + {_tok: ((.tokens.total) // 0),
                   _cost: (if (.costUsd|type) == "number" then .costUsd else null end)})
        | (map(._tok) | add) as $tok
        | (map(select(._cost != null) | ._cost) | add) as $cost
        | (map(select(._cost != null)) | length) as $ncost
        | length as $n
        | if $n == 0 then empty else
            "- **Spend:** "
            + (if ($cost != null and $ncost > 0) then "~$" + (((($cost*100)|round)/100)|tostring) + " · " else "" end)
            + ($tok|tostring) + " tokens across " + ($n|tostring)
            + " ticket" + (if $n == 1 then "" else "s" end)
            + (if $ncost == 0 then " (no per-ticket cost in the worker logs — token counts only)" else "" end)
            + " (" + (map("#" + (.ticket|tostring) + " "
                + (if ._cost != null then "$" + (((((._cost)*100)|round)/100)|tostring) + "/" else "" end)
                + (._tok|tostring) + "t") | join(" · ")) + ")"
          end' "$HISTORY" 2>/dev/null || true)"
      [[ -n "$_spend" ]] && echo "$_spend"
    fi
    echo
    # #272: governor self-ROI telemetry — surface park rate + churn classes + tokens-per-ticket
    # automatically at run-end (this run vs the rolling all-time trend) so a waste class like #115
    # (most tickets self-referential churn) is visible without manual log spelunking. Best-effort.
    if [[ -x "$DIR/govern-health.sh" && -s "$HISTORY" ]]; then
      echo "## Governor ROI (self-telemetry · #272)"
      echo '```'
      GOVERN_HISTORY_FILE="$HISTORY" "$DIR/govern-health.sh" --run "$(basename "$RUNDIR")" 2>/dev/null \
        || echo "(govern-health unavailable)"
      echo '```'
      echo "- Full rolling view: \`${ROOT_PM:-npm} run govern:health\`"; echo
    fi
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
    # #151: a ticket left IN FLIGHT by an abnormal abort/interrupt never got a state entry above —
    # surface it explicitly so it is never silently dropped. If its PR already merged but the post-
    # merge step failed, it is half-resolved (merged, not bookkept) and a human/re-run must reconcile.
    if [[ -n "${CUR_TICKET:-}" && ( "${ABORTED:-0}" -eq 1 || "${INTERRUPTED:-0}" -eq 1 ) ]]; then
      echo "## ⚠ In-flight ticket — reconcile by hand"
      if [[ -n "${CUR_TICKET_MERGED:-}" ]]; then
        echo "- **#$CUR_TICKET — PR(s) MERGED ($CUR_TICKET_MERGED) but a post-merge step FAILED; NOT bookkept.** Half-resolved: the PR is merged, but the \`## #$CUR_TICKET\` block is still in tickets.md with no state entry. Reconcile: confirm the merge landed, finish/repair the post-merge migrate/verify step, then bookkeep it — or just re-run the governor, which reuses the merged/open \`ticket-$CUR_TICKET\` PR and completes the bookkeeping."
      else
        echo "- **#$CUR_TICKET was in flight when the run ended abnormally** — not recorded as resolved / parked / failed. Its worktree is preserved at \`$(wt_path "$CUR_TICKET")\`; re-run the governor to resume it (an open \`ticket-$CUR_TICKET\` PR is reused, nothing duplicated)."
      fi
      echo
    fi
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
  local rc=$?
  govern_teardown_worker   # #242: backstop — never leave an in-flight worker subtree on any exit path
  # #151: distinguish a CLEAN finish (the loop reached its bottom `exit 0`) from an ABNORMAL abort —
  # a non-zero exit that is neither a handled interrupt (INTERRUPTED, exits 130) nor an infra halt
  # (INFRA_HALT, exits 0). `set -euo pipefail` can abort mid-ticket on an unguarded non-zero exit
  # (the #151 root cause: a post-merge migrate/verify command failing). Flag it so write_summary names
  # the cause + surfaces any merged-but-unbookkept in-flight ticket instead of reporting "completed
  # normally" and dropping it.
  if [[ "$rc" -ne 0 && "${INTERRUPTED:-0}" -eq 0 && "${INFRA_HALT:-0}" -eq 0 ]]; then
    ABORTED=1; ABORT_RC="$rc"
  fi
  write_summary
  # TokenJam run id: KEEP the run-id file on an INTERRUPTED / infra-halted run so a resume reuses the
  # same id (its workers still group with the original Run); REMOVE it on a clean finish so the next
  # invocation starts a fresh Run (one run id per loop invocation).
  if [[ "${INTERRUPTED:-0}" -eq 0 && "${INFRA_HALT:-0}" -eq 0 && -n "${TJ_RUN_ID_FILE:-}" ]]; then
    rm -f "$TJ_RUN_ID_FILE" 2>/dev/null || true
  fi
  [[ -n "$CUR_CLAIM" ]] && govern::lock_release "$CUR_CLAIM"   # free the in-flight ticket for a re-run (#41)
  # #183: the single-run lock dir now holds a `holder` file, so `rm -rf` (not rmdir, which fails on a
  # non-empty dir). Only this run's own lock is removed (TOOK_LOCK=1) — a PARALLEL driver never took it.
  if [[ "$TOOK_LOCK" -eq 1 ]]; then rm -rf "$LOCK" 2>/dev/null || true; fi
}
trap 'on_exit' EXIT
# #242: on a stop signal, FIRST reap the in-flight worker subtree (spawn-worker + worker + tool
# grandchildren) so a killed driver never leaves orphans, THEN exit (the EXIT trap's on_exit runs after).
trap 'INTERRUPTED=1; govern::log "INTERRUPTED — in-flight ticket kept in tickets.md + worktree preserved; re-run resumes."; govern_teardown_worker; exit 130' INT TERM

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
  # #3/#337: regenerate governor/pending-escalations.json at run-START (not only run-end) against the
  # cleaned escalations.md, so a stale/ghost snapshot left by a crashed run or a manual resolution
  # (a pending entry for an escalation no longer open, or a missing genuinely-open one) is corrected
  # BEFORE anything reads it. escalations.md ## Open is the source of truth, not this cached JSON.
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" >/dev/null 2>&1 \
    || govern::log "run-start pending-escalations regen failed (non-fatal)"
else
  govern::log "[dry] would apply recorded escalation answers (un-park / migrate-to-parked / preferences) from escalations.md"
  govern::log "[dry] would regenerate governor/pending-escalations.json at run-start from escalations.md ## Open (#3/#337)"
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

# Externalization lane (OPT-IN): once per run, file each OPEN Low-severity OSS-repo ticket as a public
# GitHub Issue (GOVERN_EXTERNALIZE_REPO) and remove it from tickets.md — seeding "good first issue"
# work for outside contributors. Gated by GOVERN_EXTERNALIZE_LANE (default 1); the underlying script
# self-skips cleanly when GOVERN_EXTERNALIZE_REPO/SUBREPO are unset, so this is a no-op for workspaces
# that haven't opted in. Runs BEFORE selection so an externalized ticket is never also picked up by a
# worker the same run. Non-fatal: a failure logs and continues — it must never stall the loop.
if [[ "${GOVERN_EXTERNALIZE_LANE:-1}" == "1" ]]; then
  if [[ "$MODE" == "live" ]]; then
    "$DIR/externalize-low-tickets.sh" >&2 || govern::log "externalization pass failed (non-fatal) — continuing"
  else
    "$DIR/externalize-low-tickets.sh" --dry >&2 || govern::log "externalization (dry) failed — continuing"
  fi
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

# Pre-run issue de-dup: NEVER let the internal governor work a ticket that is ALREADY a public GitHub
# issue. Issues on GOVERN_EXTERNALIZE_REPO are seeded for OUTSIDE contributors, not internal members —
# so a queued ticket that matches an open issue (by normalized title, or recorded in the externalized
# ledger) is EXCLUDED from selection this run and left in tickets.md (de-listing it is the operator's
# call). Read-only, non-fatal, gated by GOVERN_SKIP_ISSUE_TICKETS (default 1). No-op unless
# GOVERN_EXTERNALIZE_REPO is set — so this defaults OFF for a workspace that hasn't opted in.
if [[ "${GOVERN_SKIP_ISSUE_TICKETS:-1}" == "1" ]]; then
  if [[ "$MODE" == "live" ]]; then
    while IFS=$'\t' read -r _iss_n _iss_url; do
      [[ "$_iss_n" =~ ^[0-9]+$ ]] || continue
      excludes="${excludes:+$excludes,}$_iss_n"
      govern::log "skipping #$_iss_n — already a public issue ${_iss_url} — reserved for external contributors, not the internal governor (GOVERN_SKIP_ISSUE_TICKETS)"
    done < <(govern::tickets_already_issues "$TICKETS_FILE" 2>/dev/null)
  else
    govern::log "[dry] would exclude any ticket already filed as a public GitHub issue from selection"
  fi
fi

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
  if [[ "$MAX_RUNTIME" -gt 0 && "$elapsed" -ge "$MAX_RUNTIME" ]]; then govern::log "reached GOVERN_MAX_RUNTIME=${MAX_RUNTIME}s (elapsed ${elapsed}s) — stopping"; break; fi
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
             && grep -qE "^##[[:space:]]+#$p([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null; then
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
      grep -qE "^##[[:space:]]+#$_k([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null && _unmet="${_unmet:+$_unmet, }#$_k"
    done < <(govern::ticket_deps "$N" "$TICKETS_FILE")
    if [[ -n "$_unmet" ]]; then
      govern::log "#$N depends on unresolved $_unmet (still in tickets.md) — deferring this run, no worker burned (#119)"
      govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""
      excludes="$excludes,$N"; continue
    fi
  fi
  govern::log "=== ticket #$N (elapsed ${elapsed}s, done $done_count/$MAX_TICKETS) ==="
  CUR_TICKET="$N"; CUR_TICKET_MERGED=""   # #151: mark in-flight so an abnormal abort/interrupt surfaces #N (+ any merged-but-unbookkept PR)

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
    GOVERN_MODE="$MODE" spawn_worker_tracked "$N" 2>/dev/null || true
    report="$(cat "$SPAWN_OUT" 2>/dev/null || true)"; rm -f "$SPAWN_OUT"
    # Heartbeat the claim lock so its "age" measures time since the last phase completion, not
    # since acquire — a real ticket can legitimately run > the default stale window (worker +
    # await-ci + CI-fix re-dispatch + conflict-resolve). The pid-liveness check in lock_try is
    # the load-bearing anti-steal invariant; this heartbeat is defense-in-depth.
    [[ -n "$CUR_CLAIM" ]] && govern::lock_heartbeat "$CUR_CLAIM"
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
    GOVERN_MODE="$MODE" spawn_worker_tracked "$N" 2>/dev/null || true
    report="$(cat "$SPAWN_OUT" 2>/dev/null || true)"; rm -f "$SPAWN_OUT"
    status="$(printf '%s' "$report" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"
  fi

  # #34: a worker that died on a TRANSIENT connection drop mid-response (laptop sleep / network
  # suspend) is tagged status:"interrupted" — NOT a ticket fault. Unlike an infra outage it does NOT
  # halt the run (the drop is transient: the laptop woke, the network returned). The worktree is
  # preserved + resumable, so AUTO-RETRY the SAME ticket ONCE — the retry reuses the preserved
  # worktree and picks up where it left off — instead of burning the ticket as FAILED. Symmetric with
  # the infra-retry above, but with no pre-pause (the drop is already over). Disable with
  # GOVERN_INTERRUPT_RETRY=0.
  if [[ "$status" == "interrupted" && "$MODE" == "live" && -z "$resumed" && "${GOVERN_INTERRUPT_RETRY:-1}" == "1" ]]; then
    ierr="$(printf '%s' "$report" | jq -r '.interrupted.error // "connection closed mid-response"' 2>/dev/null || echo 'connection closed mid-response')"
    govern::log "#$N was INTERRUPTED ($ierr) — transient drop (e.g. laptop sleep); auto-retrying once from the preserved worktree before recording interrupted (#34)"
    GOVERN_MODE="$MODE" spawn_worker_tracked "$N" 2>/dev/null || true
    report="$(cat "$SPAWN_OUT" 2>/dev/null || true)"; rm -f "$SPAWN_OUT"
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

  # PR-HYGIENE BACKSTOP: whenever a PR now exists for this ticket, (a) strip any leaked internal
  # ticket-id (#N) from its title/body — a local id must not sit on the public repo — and (b) surface
  # any Claude spec/plan file that leaked into the diff (those belong in the root harness, never a
  # public PR). Deterministic net under the worker prompt; idempotent (no #N left → no-op). The branch
  # stays ticket-<N> (the governor tracks by it); only title+body are rewritten.
  if [[ "$MODE" == "live" ]]; then
    _pr_num="$(printf '%s' "$report" | jq -r '.pr.number // ""' 2>/dev/null || true)"
    _pr_url="$(printf '%s' "$report" | jq -r '.pr.url // ""' 2>/dev/null || true)"
    _pr_repo="$(printf '%s' "$report" | jq -r '.pr.repo // ""' 2>/dev/null || true)"
    if [[ -n "$_pr_num" ]]; then
      _pr_slug="$(printf '%s' "$_pr_url" | sed -nE 's#https?://github.com/([^/]+/[^/]+)/pull/.*#\1#p')"
      [[ -n "$_pr_slug" ]] || _pr_slug="$(govern::repo_slug "$_pr_repo" 2>/dev/null || true)"
      if [[ -n "$_pr_slug" ]]; then
        govern::scrub_pr_ticket_ref "$_pr_slug" "$_pr_num" "$N"
        _specs="$(govern::pr_spec_files "$_pr_slug" "$_pr_num" 2>/dev/null || true)"
        [[ -n "$_specs" ]] && govern::log "WARN $_pr_slug#$_pr_num includes Claude spec/plan artifact(s) that must NOT be on a public PR — strip before merge: $(printf '%s' "$_specs" | tr '\n' ' ')"
      fi
    fi
  fi

  # #67/#73 VALIDATION GATE: a ticket whose deliverable is a LIVE/empirical result (a
  # "VALIDATION"/"SPIKE" ticket, a "**Type:** Validation spike" line, or "live-verify") must NOT be
  # auto-resolved. Two failure modes both downgrade to parked+escalate — never a silent worker verdict:
  #   #67 — the test WASN'T run (validation.ranLiveTest!=true or no evidence): escalate for a real run.
  #   #73 — the test RAN but its OWN gate FAILED (validation.gatePassed==false, i.e. a measured NEGATIVE):
  #         shipping/shelving/reworking a negative is a product judgment the worker must not self-decide
  #         (esp. not auto-ship a default-off opt-in) — escalate the disposition with the result in hand.
  # Fires only on validation-type tickets, so ordinary code tickets are unaffected. gatePassed defaults
  # to "unknown" (absent → never force-parks; only an explicit false trips #73), so pre-#73 workers and
  # non-gated validations are unaffected.
  if [[ "$status" == "resolved" && "$MODE" == "live" ]]; then
    # Use the shared tolerant parser so a `##  #N` (double-space) or `## #N—Title` (em-dash
    # no space) heading doesn't yield an empty tblock — which would silently disable this
    # gate: the VALIDATION|SPIKE grep would miss and a code-reading verdict would resolve a
    # validation ticket without live-test evidence, defeating the #67 gate.
    tblock="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
    if printf '%s' "$tblock" | grep -qE '^##[[:space:]]+#[0-9]+[[:space:]]*[—-]?.*(VALIDATION|SPIKE)|^\*\*Type:\*\*.*([Vv]alidation|[Ss]pike)|[Ll]ive-verif' 2>/dev/null; then
      case "$(govern::validation_gate_action "$report")" in
        park-no-evidence)
          govern::log "#$N is a VALIDATION ticket but the worker gave no live-test evidence — refusing to auto-resolve; parking for a real test (#67 gate). Any worker PR is left open for review."
          report="$(printf '%s' "$report" | jq -c '.status="parked" | .pr=null | .escalation={title:"validation ticket needs a real test",reason:"reported resolved without running the live test — a validation/spike ticket requires empirical evidence (deploy/snapshot/restore/UI run with captured output), not static code analysis",question:"run the actual test and attach evidence, OR confirm it cannot be automated and decide disposition",options:[]}' 2>/dev/null || printf '%s' "$report")"
          status="parked"; anomaly=1 ;;
        park-gate-failed)
          govern::log "#$N is a VALIDATION ticket whose gate FAILED (gatePassed=false) — refusing to auto-ship a measured-NEGATIVE result; parking so the operator decides ship-off/shelve/rework (#73). Any worker PR is left open for review."
          # Stamp the flow registry as a measured NEGATIVE (validations Phase 2): correctness→FAIL,
          # effectiveness→INEFFECTIVE. Stamp from the ORIGINAL report (before we null its PR for the
          # park) so the registry keeps the SHA pins + PR-URL linkage. No-op for a non-flow ticket.
          _flow_ids=""
          if command -v govern::ticket_flow_ids >/dev/null 2>&1; then
            _flow_ids="$(govern::ticket_flow_ids "$N" "$TICKETS_FILE" 2>/dev/null || true)"
          fi
          if [[ -n "$_flow_ids" ]] && command -v govern::flows_stamp_from_report >/dev/null 2>&1; then
            govern::flows_stamp_from_report "$report" gate-park "$_flow_ids" "$(govern::meta_root)" || true
          fi
          # Phase 5 kill loop: a gate-failed FLOW ticket offers `kill` as a disposition (delete the
          # measured-worthless feature) alongside the correctness dispositions — apply-answers files the
          # removal ticket + tombstones the flow on its PR. Non-flow tickets keep the original options.
          _gate_opts='["shelve","ship-default-off","rework"]'
          [[ -n "$_flow_ids" ]] && _gate_opts='["kill","shelve","ship-default-off","rework"]'
          report="$(printf '%s' "$report" | jq -c --argjson opts "$_gate_opts" '.status="parked" | .pr=null | .escalation={title:"validation gate FAILED — decide kill/ship-off/shelve/rework",reason:("the required validation/A-B gate FAILED (measured negative) — auto-shipping a negative is not a worker decision: " + (.validation.evidence // "see report")),question:"the measured result is negative; choose the disposition — kill (delete the measured-worthless feature), ship default-OFF opt-in, shelve the branch, or rework scope + re-run. Do NOT auto-ship a gate-failed result.",options:$opts}' 2>/dev/null || printf '%s' "$report")"
          status="parked"; anomaly=1 ;;
      esac
    fi
  fi

  RESOLVED_PR_SUMMARY=""
  if [[ "$status" == "resolved" ]]; then
    mneeded="$(printf '%s' "$report" | jq -r '.migration.needed // false' 2>/dev/null || echo false)"
    mdestr="$(printf '%s' "$report" | jq -r '.migration.destructive // false' 2>/dev/null || echo false)"
    # #129: a multi-repo worker can open N PRs for one ticket (e.g. a backend PR + a frontend PR).
    # Acting only on the single reported .pr orphaned the siblings unmerged. Collect EVERY PR for
    # this ticket — reported (.pr + .prs[]) UNION every open ticket-<N> head across all repos —
    # deduped + merge-repo-first so the live merge-repo backend ships before any frontend sibling.
    pr_lines="$(govern::collect_ticket_prs "$N" "$report")"
    all_prs_label="$(printf '%s\n' "$pr_lines" | awk -F'\t' 'NF>=2{printf "%s%s#%s",sep,$1,$2; sep=", "}')"

    # #72: on a LOCAL-FIRST repo (opt-in via GOVERN_LOCAL_FIRST_REPOS) there is no deployed prod DB —
    # an ADDITIVE migration ships as code (a MIGRATIONS entry that self-applies on each user's local
    # DB open), so there is nothing to "apply to prod manually". If EVERY PR for this ticket targets
    # a local-first repo, neutralize mneeded so it opens as a normal PR instead of a spurious
    # "apply migration manually" park. DESTRUCTIVE migrations still escalate (guarded by mdestr).
    if [[ "$mneeded" == "true" && "$mdestr" != "true" && -n "$pr_lines" ]]; then
      _all_localfirst=1
      while IFS=$'\t' read -r _lfr _lfp _lfu; do
        [[ -n "$_lfr" ]] || continue
        if ! govern::is_local_first_repo "$_lfr"; then _all_localfirst=0; break; fi
      done <<< "$pr_lines"
      if [[ "$_all_localfirst" == "1" ]]; then
        govern::log "#$N's additive migration ships as auto-applying code on local-first repo(s) ${all_prs_label:-?} — no prod apply needed; proceeding as a normal PR (#72)"
        mneeded="false"
      fi
    fi

    if [[ "$mneeded" == "true" && "$mdestr" == "true" ]]; then
      # DESTRUCTIVE prod migration → never auto-merge ANY sibling; escalate (hard-stop stays).
      govern::log "#$N needs a DESTRUCTIVE prod migration ($(printf '%s' "$report" | jq -r '.migration.name // "?"')) — NOT auto-merging ${all_prs_label:-its PR(s)}; escalating"
      report="$(printf '%s' "$report" | jq -c --arg p "${all_prs_label:-?}" '.escalation={reason:"destructive prod migration — needs human review + coordinated merge/migrate",question:("review PR(s) "+$p+", apply migration manually, then merge"),options:[]}')"
      status="parked"
    elif [[ "$mneeded" == "true" && -z "${GOVERN_MIGRATE_CMD:-}" ]]; then
      # ADDITIVE prod migration but no migrate command configured → do NOT silently merge-and-forget
      # the code ahead of a schema it needs. Escalate for a manual apply (parked = work preserved).
      govern::log "#$N needs an additive prod migration but no GOVERN_MIGRATE_CMD configured — skipping prod migration; escalating for manual apply"
      report="$(printf '%s' "$report" | jq -c --arg p "${all_prs_label:-?}" '.escalation={reason:"additive prod migration required but no GOVERN_MIGRATE_CMD configured",question:("review PR(s) "+$p+", apply the additive migration to prod manually, then merge"),options:[]}')"
      status="parked"
    elif [[ -n "$pr_lines" ]]; then
      # Walk every PR merge-repo-first: merge-repo PRs auto-merge on green/none (with the #71 rebase
      # retry + CI-fix loop + #191 conflict re-dispatch, factored into merge_pr_for_ticket); frontend
      # siblings are PR-only and left open — but SURFACED in the summary as "left open", never
      # silently dropped (#129).
      merge_repo_merged=0; pr_summary=""
      while IFS=$'\t' read -r prepo pnum _purl; do
        [[ -n "$prepo" && -n "$pnum" ]] || continue
        # Trust-ladder gate (GOVERN_AUTONOMY): in observe/pr-only the governor NEVER auto-merges —
        # every PR is left open for the operator (exactly like a frontend sibling, #129). The ticket
        # still resolves (its PR is the record of the work) and gets bookkept; only the final merge is
        # withheld until the operator flips GOVERN_AUTONOMY=auto. A workspace.sh predating the ladder
        # resolves to `auto`, so this branch is a pure no-op there (backward compat).
        if ! govern::automerge_enabled; then
          govern::log "$prepo#$pnum left open — GOVERN_AUTONOMY=$(govern::autonomy) (governor opens PRs, does not auto-merge; flip to auto to enable) [autonomy]"
          pr_summary="$pr_summary $prepo#$pnum($(govern::autonomy)-left-open)"
          continue
        fi
        if govern::is_merge_repo "$prepo"; then
          if [[ "$MODE" == "dry" ]]; then
            govern::log "[dry] would await CI + merge $prepo#$pnum"
            pr_summary="$pr_summary $prepo#$pnum(dry-would-merge)"
            continue
          fi
          case "$(merge_pr_for_ticket "$prepo" "$pnum")" in
            merged)
              govern::log "merged $prepo#$pnum (#$N)"
              pr_summary="$pr_summary $prepo#$pnum(merged)"; merge_repo_merged=1
              # #151: track merged-but-not-yet-bookkept so an abort during a LATER step (e.g. the
              # additive prod migration below) surfaces #N as half-resolved instead of dropping it.
              CUR_TICKET_MERGED="${CUR_TICKET_MERGED:+$CUR_TICKET_MERGED, }$prepo#$pnum" ;;
            red)
              # CI stayed red after up to $GOVERN_CI_FIX_TRIES fix re-dispatches → this PR cannot
              # ship. Mark the ticket failed but KEEP merging the remaining siblings so the rest
              # isn't orphaned.
              govern::log "CI still red on $prepo#$pnum after fixes → #$N failed"
              pr_summary="$pr_summary $prepo#$pnum(CI-red-left-open)"
              [[ "$status" == "resolved" ]] && status="failed" ;;
            unmergeable)
              # Merge FAILED (conflict / failing required check) even after a rebase-onto-origin
              # attempt + the #191 conflict re-dispatch. Park (NOT resolve): keep the ticket block,
              # leave the PR open, escalate (#42). Don't downgrade an already-failed status back up.
              govern::log "merge failed $prepo#$pnum — PR left open; parking (ticket NOT deleted) [#42]"
              pr_summary="$pr_summary $prepo#$pnum(unmergeable-left-open)"
              report="$(printf '%s' "$report" | jq -c --arg p "$prepo#$pnum" '.escalation={reason:("PR "+$p+" could not be merged (conflict or failing required check) — needs a manual rebase onto origin/main + merge"),question:("rebase "+$p+" onto origin/main, resolve conflicts, then merge"),options:[]}')"
              [[ "$status" == "resolved" ]] && status="parked" ;;
            error)
              # CI state UNVERIFIABLE (gh network/auth/rate-limit/5xx) — we could NOT confirm the PR's
              # checks are green, so we FAIL CLOSED: leave the PR open + park, never merge blind (#34b).
              govern::log "CI state unverifiable on $prepo#$pnum (gh could not confirm CI) — PR left open; parking (ticket NOT deleted) [ci-state-unverifiable]"
              pr_summary="$pr_summary $prepo#$pnum(ci-unverifiable-left-open)"
              report="$(printf '%s' "$report" | jq -c --arg p "$prepo#$pnum" '.escalation={reason:("PR "+$p+" was NOT merged because its CI state could not be verified (gh error — network / auth / rate-limit / GitHub 5xx). Failing closed rather than merging without a confirmed-green CI."),question:("confirm "+$p+" CI is green, then merge; or investigate the gh/GitHub API failure"),options:[]}')"
              [[ "$status" == "resolved" ]] && status="parked" ;;
            external-blocked)
              # The auto-merge safety guard (govern::pr_automerge_allowed) refused this PR — the head
              # is from an external author, a fork, or a branch name outside GOVERN_MERGE_BRANCH_RE. A
              # human must merge it via gh/web; the governor structurally will NOT. Park + escalate so
              # the operator sees it and either merges by hand or rejects the PR.
              govern::log "auto-merge blocked on $prepo#$pnum — PR is external / fork / non-governor branch; parking (ticket NOT deleted) [external-pr-blocked]"
              pr_summary="$pr_summary $prepo#$pnum(external-pr-blocked)"
              report="$(printf '%s' "$report" | jq -c --arg p "$prepo#$pnum" '.escalation={reason:("PR "+$p+" was NOT auto-merged: the three-factor safety guard (own gh author + governor branch pattern + non-fork) refused it. This is INTENDED for external contributors — the governor never auto-merges a PR it did not itself open."),question:("review "+$p+" as a human and merge it via gh/web if trusted, or close it"),options:[]}')"
              [[ "$status" == "resolved" ]] && status="parked" ;;
          esac
        else
          # Frontend sibling: PR-only (a different account merges). NOT orphaned — surfaced as
          # "left open" so the operator sees it and merges it themselves (#129).
          govern::log "$prepo#$pnum left open (frontend is PR-only) [#129]"
          pr_summary="$pr_summary $prepo#$pnum(frontend-left-open)"
        fi
      done <<< "$pr_lines"

      # ADDITIVE migration: apply ONCE, after a merge-repo PR merged (the merge-repo backend is first
      # in the merge-repo-first walk, so this runs post-merge). Old running code ignores the new
      # nullable/default column; the new code arrives with the merge, so the column exists when needed.
      #
      # Your GOVERN_MIGRATE_CMD MUST fast-forward the relevant checkout to origin/main BEFORE it
      # inspects/applies migration status. A migrate tool reads the migration dirs ON DISK in the
      # working tree; if the checkout still sits at a pre-merge SHA the just-merged migration dir is
      # absent, status compares an incomplete set, falsely reports "up to date", the apply silently
      # no-ops, and verify then false-alarms as "half-applied" (the #85 stale-checkout bug). If it
      # cannot ff-pull (diverged/dirty) it should REFUSE rather than trust a stale set. Only when the
      # ticket is still cleanly resolved (no sibling merge failed it into parked/failed).
      if [[ "$mneeded" == "true" && "$status" == "resolved" ]]; then
        if [[ "$MODE" == "dry" ]]; then
          govern::log "[dry] would apply additive prod migration for #$N after backend merge"
        elif [[ "$merge_repo_merged" == "1" ]]; then
          govern::log "applying additive prod migration for #$N via GOVERN_MIGRATE_CMD"
          # #151: capture output but NEVER let a non-zero migrate exit abort the whole run via `set -e`.
          # A quota/billing/build failure exits non-zero; the intent here is to CLASSIFY it (verify +
          # grep below) and PARK #N with a clear escalation — NOT crash the loop mid-ticket and mislabel
          # the run "completed normally" while leaving #N merged-but-unbookkept.
          mout="$( cd "$WS_ROOT" && eval "$GOVERN_MIGRATE_CMD" 2>&1 )" || true
          # #184/#151-safe: read the VERIFY output first (the authoritative post-apply state). Capture
          # its exit code without aborting the loop via `set -e` — `&& vrc=0 || vrc=$?` keeps control on
          # the classify path. Skip verify (treat as pass) when no GOVERN_VERIFY_CMD is configured.
          if [[ -n "${GOVERN_VERIFY_CMD:-}" ]]; then
            vout="$( cd "$WS_ROOT" && eval "$GOVERN_VERIFY_CMD" 2>&1 )" && vrc=0 || vrc=$?
          else
            vout=""; vrc=0
          fi
          if [[ $vrc -eq 0 ]]; then
            govern::log "prod migration applied + verified for #$N"
          else
            # Classify the failure so the operator gets the RIGHT next action. Read the VERIFY output
            # first (authoritative post-apply state), then fall back to the apply output. FAILED/half-
            # applied needs a `migrate resolve` (NOT another deploy); a stale/diverged checkout that
            # couldn't ff-pull needs reconciling first; a still-NOT-applied migration after a heal means
            # the apply genuinely failed (quota/billing/build); anything else is a generic verify miss.
            # The markers below match what the recommended migrate/verify helper emits — emit the same
            # strings from your GOVERN_MIGRATE_CMD/GOVERN_VERIFY_CMD to light up the specific guidance.
            mverify="$vout"$'\n'"$mout"
            if printf '%s' "$mverify" | grep -qiE 'FAILED / half-applied|failed state|migrate resolve'; then
              esc_reason='prod migration is in a FAILED / half-applied state after merge — needs a `migrate resolve` (do NOT re-run the migrate step); inspect migration status on prod'
            elif printf '%s' "$mverify" | grep -qiE 'ff-pull FAILED|BEHIND origin/main|STALE on-disk'; then
              esc_reason='could not fast-forward the merged checkout to origin/main before applying the migration (local main diverged/dirty, so the migration dir may be absent on disk) — reconcile the checkout, then re-run the migrate step (#85)'
            elif printf '%s' "$mverify" | grep -qiE 'NOT applied|not yet been applied|have not'; then
              esc_reason='additive prod migration is still NOT applied after the post-merge heal (the apply step failed — e.g. billing/quota/build) — re-run the migrate step once the cause is cleared (#184)'
            else
              esc_reason='additive prod migration applied/verify FAILED after merge — check migration status on prod'
            fi
            govern::log "prod migration/verify FAILED for #$N — escalating ($esc_reason)"
            report="$(printf '%s' "$report" | jq -c --arg r "$esc_reason" '.escalation={reason:$r,question:"finish/repair the migration manually",options:[]}')"
            status="parked"
          fi
        else
          # mneeded but no merge-repo PR merged (e.g. only a frontend sibling exists) — the additive
          # migration never got applied. Don't silently resolve: escalate so a human applies it.
          govern::log "#$N needs an additive prod migration but no merge-repo PR merged — escalating (migration NOT applied)"
          report="$(printf '%s' "$report" | jq -c '.escalation={reason:"ticket reported an additive prod migration but no merge-repo PR merged this run, so the migration was not applied — apply it manually or re-run once a merge-repo PR is open",question:"apply the additive migration to prod, then bookkeep",options:[]}')"
          status="parked"
        fi
      fi
      RESOLVED_PR_SUMMARY="$(printf '%s' "${pr_summary# }")"
    fi
  fi

  case "$status" in
    resolved)
      if [[ "$MODE" == "dry" ]]; then govern::log "[dry] would bookkeep #$N"
      else printf '%s' "$report" | "$DIR/govern-bookkeep.sh" "$N" >&2 || govern::log "bookkeep failed #$N"; fi
      # #129: record EVERY PR + its disposition (merged / frontend-left-open) so the session summary
      # lists them all — no sibling PR silently dropped. Fall back to the single .pr.url for an
      # ordinary one-PR ticket.
      _rnote="${RESOLVED_PR_SUMMARY:-$(printf '%s' "$report" | jq -r '.pr.url // ""' 2>/dev/null || true)}"
      # #241: a resolved VALIDATION ticket carries empirical evidence (report.json / evidence dir) in
      # validation.evidence — thread it into the state.jsonl note so a genuine REAL-PASS is never
      # recorded as an evidence-less pass (the #231 symptom: a full report.json + evidence dir but an
      # EMPTY note). The PASS/FAIL verdict + evidence path now travel WITH the recorded outcome.
      _vnote="$(printf '%s' "$report" | jq -r 'if (.validation.ranLiveTest==true) and ((.validation.evidence // "")|length>0) then .validation.evidence else "" end' 2>/dev/null || true)"
      [[ -n "$_vnote" ]] && _rnote="${_rnote:+$_rnote — }validation evidence: $_vnote"
      record "$N" resolved "$_rnote"
      nres=$((nres+1)); since_review=$((since_review+1)); bad_streak=0
      # A cleanly-resolved worktree is torn down (live, real worktree only). This ALSO fires for a
      # resume-adopted resolution (the "found existing PR — resuming" path): a resumed ticket is
      # bookkept + recorded resolved identically to a fresh one, and worktree:rm --force is a no-op if
      # the dir is already gone — so gating this on `-z "$resumed"` only LEAKED the worktree of every
      # resumed ticket (Leak A). worktree:rm now also kills the slot's orphaned stack (Leak B).
      if [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
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
      # #312: stamp `Opened` (date + run id) so govern-health.sh can age unanswered escalations and
      # flag stale ones ("needs operator attention") instead of the supervisor rediscovering them by hand.
      printf '\n### #%s — %s\n- **Opened:** %s (run %s)\n- **Reason:** %s\n- **Question:** %s\n- **Options:** %s\n- **Answer:** _(operator)_\n- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_\n- **Make this a rule?:** _(operator)_\n' \
          "$N" "$(printf '%s' "$report" | jq -r '.escalation.title // ((.escalation.reason // "parked")[0:80])')" \
          "$(date +%F)" "$(basename "$RUNDIR")" \
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
      # #14: commit the park escalation SAME-STEP — a dirty escalations.md left at run-end aborts the
      # next run's preflight rebase (the recurring-orphan self-block). Scoped + CAS-safe + push-guarded.
      [[ "$MODE" == "live" ]] && govern::_commit_escalations "park escalation #$N"
      record "$N" parked "escalated; worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
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
    timeout)
      # #241: the worker was HARD-KILLED by GOVERN_WORKER_TIMEOUT before it could write a verdict.
      # This is INCOMPLETE, not a genuine FAIL — the killed worker may have done real, green work and
      # simply never reached the report write. Recording it as `failed` would mask a working feature as
      # broken (false launch-blocking signal) and waste re-runs treating "the trick is broken". So
      # record a DISTINCT `timeout` status: worktree preserved (re-run resumes), NOT counted as a
      # feature failure. It still counts toward the in-run bad-streak (a run that only ever times out
      # must stop) and the cross-run #60 streak (consecutive_fails counts `timeout`), so a ticket that
      # times out run after run is auto-escalated — but it is never blamed as a broken feature.
      record "$N" timeout "killed mid-run before verdict — INCOMPLETE, not failed; re-run resumes. worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
      govern::log "#$N TIMEOUT — killed before verdict; recorded INCOMPLETE (not failed), worktree PRESERVED at $(wt_path "$N") (re-run resumes) [#241]"
      slim_worktree "$N"
      excludes="$excludes,$N"; ntimeout=$((ntimeout+1)); bad_streak=$((bad_streak+1))
      ;;
    interrupted)
      # #34: the worker died on a TRANSIENT connection drop mid-response (laptop sleep / network
      # suspend) and the auto-retry above ALSO dropped — NOT a ticket fault and NOT a persistent
      # infra outage. record() drops `interrupted` from the cross-run history (no #60 pollution — the
      # ticket isn't hard, the laptop slept), and we do NOT halt the run (the drop is transient,
      # unlike an infra outage). The worktree is PRESERVED + resumable so any real pre-drop work
      # survives and a re-run picks it up. DESIGN DECISION (LOCKED): it DOES count toward the in-run
      # bad-streak so a continuously-sleeping laptop (clamshell-on-battery, which no assertion can
      # defend) still trips the circuit breaker and stops the run cleanly after MAX_BAD_STREAK — yet
      # it stays absent from cross-run history and is never labeled `failed`.
      record "$N" interrupted "connection dropped mid-response (transient, e.g. laptop sleep); NOT failed — re-run resumes. worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
      govern::log "#$N INTERRUPTED — connection dropped mid-response (transient, e.g. laptop sleep) even after one auto-retry; recorded interrupted (NOT failed), worktree PRESERVED at $(wt_path "$N") (re-run resumes) [#34]"
      slim_worktree "$N"
      excludes="$excludes,$N"; nintr=$((nintr+1)); bad_streak=$((bad_streak+1))
      ;;
    *)
      record "$N" failed "see $(govern::worker_logdir "$N")/worker.jsonl; worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
      govern::log "#$N FAILED — worktree PRESERVED at $(wt_path "$N") (nothing discarded; re-run resumes)"
      slim_worktree "$N"
      excludes="$excludes,$N"; nfail=$((nfail+1)); bad_streak=$((bad_streak+1))
      ;;
  esac

  # release this ticket's claim now its outcome is recorded (#41)
  [[ -n "$CUR_CLAIM" ]] && { govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""; }
  # #151: #N reached a recorded terminal outcome (resolved/parked/failed/timeout) above — clear the
  # in-flight marker so a later CLEAN break (circuit-breaker / MAX_TICKETS / supervisor-halt) is not
  # wrongly reported as having a half-resolved ticket in flight.
  CUR_TICKET=""; CUR_TICKET_MERGED=""

  [[ "$bad_streak" -ge "$MAX_BAD_STREAK" ]] && anomaly=1

  # Optional periodic out-of-band orphan-resource reap, on the supervisor cadence. A per-worker
  # sweep (spawn-worker) only covers a worker the governor observed exit — NOT a session that died
  # UNCLEANLY (whose SessionEnd never fired). If the workspace ships a scripts/reap-orphan-deploys.sh
  # (deploy/cloud infra — absent by default), call it here so a long-running governor bounds an
  # orphan's lifetime. Guarded on existence + always exits 0, so a reaper hiccup never perturbs the loop.
  if [[ "$MODE" == "live" && ( "$anomaly" -eq 1 || "$since_review" -ge "$SUP_EVERY" ) \
        && -f "$DIR/../reap-orphan-deploys.sh" ]]; then
    bash "$DIR/../reap-orphan-deploys.sh" --quiet 2>/dev/null || true
  fi

  if [[ "$anomaly" -eq 1 || "$since_review" -ge "$SUP_EVERY" ]]; then
    govern::log "supervisor review (anomaly=$anomaly, since_review=$since_review)"
    verdict="$("$DIR/govern-supervise.sh" "$RUNDIR" 2>/dev/null || echo '{"verdict":"ok"}')"
    since_review=0
    # Phase 5 flow advisories (ADVISORY ONLY — never auto-files, billable safety): the periodic pass
    # surfaces (a) MEASURING flows whose sample window has plausibly elapsed → file a collect run, (b)
    # `Revalidate: every Nd` flows now past due, and (c) passive "0 usage" evidence where an analytics
    # adapter is wired. Logged + appended to the run review for the operator; filing a validation stays a
    # human act. Guarded on the parser + always non-fatal so a registry hiccup never perturbs the loop.
    if [[ "$MODE" == "live" ]] && command -v govern::flows_due_advisories >/dev/null 2>&1; then
      _fadv="$(govern::flows_due_advisories "$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")" 2>/dev/null || true)"
      if command -v govern::flows_passive_evidence >/dev/null 2>&1; then
        _fpas="$(govern::flows_passive_evidence "$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")" 2>/dev/null || true)"
        [[ -n "$_fpas" ]] && _fadv="${_fadv:+$_fadv$'\n'}$_fpas"
      fi
      if [[ -n "$_fadv" ]]; then
        printf -- '- after #%s (flow advisories):\n' "$N" >> "$REVIEW"
        printf '%s\n' "$_fadv" | while IFS= read -r _l; do
          [[ -n "$_l" ]] || continue
          govern::log "flow advisory: $_l"
          printf -- '  - %s\n' "$_l" >> "$REVIEW"
        done
      fi
    fi
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

# #337: the AUTHORITATIVE run-end pending-escalations.json emit is DEFERRED to AFTER the run-end
# escalation writers (self-improve / self-apply). Emitting it here (before self-improve/self-apply
# could file a fresh escalation) left pending stale. escalations.md ## Open is the source of
# truth; the single final emit below (search "#337: authoritative run-end emit") writes pending
# exactly once, last.

# Self-improvement (observe → propose, never auto-apply): when a run hit friction, a fresh
# read-only reviewer proposes concrete harness improvements into governor/improvements.md.
if [[ "${GOVERN_IMPROVE:-1}" == "1" && "$MODE" == "live" ]] \
   && { [[ "${nfail:-0}" -gt 0 ]] || [[ "${npark:-0}" -gt 0 ]] || [[ -s "$REVIEW" ]]; }; then
  govern::log "self-improvement review → governor/improvements.md"
  "$DIR/govern-improve.sh" "$RUNDIR" >/dev/null 2>&1 || govern::log "improve step skipped (error)"
  # CLASSIFIED promotion bridge: auto-file the SAFE/additive proposals govern-improve just appended
  # as a ticket (via file-ticket.sh) so the governor drains them like any ticket, removing the manual
  # promote step. Rail-touching / OPERATOR-DECISION proposals (GOVERN_MAX_* bounds, merge allowlist,
  # permission mode, green-or-none gate) are NEVER auto-queued — they stay human-gated in
  # improvements.md. Default ON; GOVERN_IMPROVE_TRIAGE=0 to disable. Scoped to THIS run's block by run-id.
  if [[ "${GOVERN_IMPROVE_TRIAGE:-1}" == "1" ]]; then
    "$DIR/govern-improve-triage.sh" "$(basename "$RUNDIR")" >/dev/null 2>&1 \
      || govern::log "improve-triage step skipped (error)"
  fi
fi

# Opt-in guarded auto-apply (GOVERN_SELF_APPLY=1): apply ONE proposal under strict guards; the
# change takes effect next run. Default off — observe→propose is the default posture.
if [[ "${GOVERN_SELF_APPLY:-0}" == "1" && "$MODE" == "live" ]]; then
  "$DIR/govern-self-apply.sh" "$RUNDIR" 2>&1 | sed 's/^/[self-apply] /' || true
fi

# #337: authoritative run-end emit — LAST, after every run-end escalation writer (park loop, the
# self-improve/self-apply block above), so governor/pending-escalations.json reflects the FINAL
# escalations.md ## Open. This is the #62 operator hand-off: the launching /govern relay reads
# this JSON and presents the still-unanswered entries via AskUserQuestion; the next run-start
# applies the recorded answers. Also fires GOVERN_NOTIFY_CMD when pending exist so a no-session
# run still surfaces a signal. #92: pass $REVIEW so the run's supervisor concerns ride alongside.
if [[ "$MODE" == "live" ]]; then
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" "$REVIEW" >/dev/null 2>&1 \
    || govern::log "escalations-emit-pending failed (non-fatal)"
fi

if [[ "${INFRA_HALT:-0}" -eq 1 ]]; then
  govern::log "RUN HALTED on infra/auth outage ($INFRA_HALT_ERR) — re-authenticate (\`claude login\`) or restore connectivity, then re-run. No ticket recorded \`failed\`; affected tickets keep clean #60 history (#90)."
fi
# #272: emit the governor ROI (park rate + churn + tokens/ticket) to the run log at run-end too, so
# it's visible in a tailed session even without opening summary.md. Best-effort, never fatal.
if [[ -x "$DIR/govern-health.sh" && -s "$HISTORY" ]]; then
  GOVERN_HISTORY_FILE="$HISTORY" "$DIR/govern-health.sh" --run "$(basename "$RUNDIR")" 2>/dev/null \
    | while IFS= read -r _hl; do govern::log "health | $_hl"; done || true
fi
govern::log "DONE — resolved=$nres parked=$npark failed=$nfail timed-out=$ntimeout interrupted=$nintr (processed $done_count) | state=$STATE review=$REVIEW"
[[ "$npark" -gt 0 || "$nfail" -gt 0 ]] && govern::log "preserved worktrees for parked/failed tickets remain under $WORKTREE_BASE/ — review then '${ROOT_PM:-npm} run worktree:rm -- ticket-<N>'"

# Auto-trigger sync-port at run-end IFF (a) the mechanism script is present in
# this workspace AND (b) the workspace opted in via GOVERN_UPSTREAM_HARNESS_REPO.
# Best-effort — a failure here logs but never overrides the run's exit code.
# Set GOVERN_SYNC_PORT_ON_END=0 to disable; --dry-run mode of the governor
# skips it too (nothing was resolved to sync).
if [[ "${GOVERN_SYNC_PORT_ON_END:-1}" == "1" \
   && -n "${GOVERN_UPSTREAM_HARNESS_REPO:-}" \
   && -x "$DIR/sync-port.sh" \
   && "${DRY_RUN:-0}" -ne 1 ]]; then
  govern::log "sync-port: auto-triggering at run-end (GOVERN_UPSTREAM_HARNESS_REPO=$GOVERN_UPSTREAM_HARNESS_REPO)"
  "$DIR/sync-port.sh" 2>&1 | while IFS= read -r _sl; do govern::log "sync-port | $_sl"; done \
    || govern::log "sync-port: exited non-zero (see escalations.md for details, if any)"
fi
exit 0
