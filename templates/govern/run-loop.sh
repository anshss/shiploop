#!/usr/bin/env bash
# Governor v2, pure-bash driver. Spends ~zero Claude context itself; Claude is invoked only in
# fresh, bounded sessions: the per-ticket worker (spawn-worker).
#
# NAMED DISPATCH IS THE ONLY FRONT DOOR. You name the tickets; the driver dispatches exactly those,
# at the least spend, with every gate on. There is no backlog sweep and no grind-until-empty loop:
# both fleets that ran one abandoned it, because a sweep spends on QUEUE-ORDER priorities while the
# operator has OPERATOR priorities. Queue order is not a work order.
#
# Usage: run-loop.sh [--dry-run] [--exclude N,N,...] [--parallel[=N]|--serial] <ticket-number> ...
#   <number>         → work that one ticket. Sequential and unbatched, always: naming exactly one
#                       ticket means "just this one", so there is nothing to fan out or group.
#   <N> <N> <N> ...  → work EXACTLY that ticket SET. The set is partitioned into LOCALITY DISPATCH_GROUPS
#                       (shared measured file paths, GOVERN_BATCH_MAX per group) so two concurrent
#                       workers are never put on the same file; groups run in severity order.
#                       A ticket not found / not eligible is skipped with a logged reason, never
#                       silently. Duplicates are folded.
#   (no ticket)      → usage + exit 2. Nothing is selected for you.
#   --dry-run        → worker runs plan-mode; merge + bookkeep are skipped (logged)
#   --exclude N,N    → drop these ticket numbers from the named set (e.g. a peer session owns them)
#   --parallel[=N]   → work the named set CONCURRENTLY, up to N locality DISPATCH_GROUPS at once. This
#                       process becomes an ORCHESTRATOR: each child is a full driver handed one
#                       group's ticket numbers (so every gate below still runs in the child), and
#                       this process waits for all of them, folds their per-ticket rows into this
#                       run's state.jsonl, logs one aggregate tally, and fires the run-end blocks
#                       ONCE for the whole dispatch.
#   --serial         → opt back OUT of parallel: one group at a time.
#   --orchestrated   → INTERNAL, set by the orchestrator on each child it spawns: "the run-start
#                       reconcile and the run-end blocks belong to the parent". Never pass it by hand.
#
# Concurrency precedence (highest wins):
#   1. --serial                     → sequential (always wins)
#   2. --parallel=N                 → parallel, cap N (flag beats env)
#   3. --parallel (bare)            → parallel, cap = GOVERN_PARALLEL, else GOVERN_PARALLEL_DEFAULT,
#                                     else the group count
#   4. GOVERN_PARALLEL=N (env only) → parallel, cap N
#   5. nothing given                → GOVERN_PARALLEL_DEFAULT (scripts/lib/workspace.sh). Unset or
#      1 = sequential; N > 1 = parallel at cap N.
#   Naming EXACTLY ONE ticket, or resolving to a single locality group, collapses to the sequential
#   driver: a cap-1 orchestrator is a process layer around the loop it wraps.
#
# GOVERN_ALLOW_CONCURRENT=1 → run alongside another driver (parallel sessions on disjoint
#   tickets, #41): skips the single-run lock; safety comes from the per-ticket claim lock
#   (governor/.locks/ticket-N) + the bookkeep lock in govern-bookkeep.sh.
#
# GATES, all of which run on EVERY named dispatch (they used to be skipped whenever a ticket was
# named, which left the operator's real path the unprotected one):
#   claim lock · cross-driver re-verify (#108) · Depends-on gate (#119) · staleness gate (#4.5) ·
#   upstream-drift pregate · failure-streak breaker (#60) · run-start preflight-main +
#   preflight-base-ci. An operator naming a ticket wants it DONE, not dispatched onto a red base,
#   onto an unlanded dependency, or into a fix another fleet already shipped.
#
# Hard bounds (so a dispatch always ends; tune via env):
#   GOVERN_MAX_TICKETS     (20)    stop after this many tickets processed this run
#   GOVERN_MAX_BAD_STREAK  (4)     stop after this many CONSECUTIVE parked/failed
#   GOVERN_MAX_RUNTIME     (0)     stop starting new tickets after this many seconds; 0 = no cap.
#   GOVERN_WORKER_TIMEOUT  (3600)  per-worker wall-clock cap (enforced in spawn-worker)
#   GOVERN_SKIP_BASE_CHECK (0)     1 = skip the run-start base-branch CI check (#49)
#
# The supervisor is NOT on this path. govern-supervise.sh is a manual audit (`govern:audit`) and
# costs zero model spend unless you invoke it.
#
# Progress preservation (acts like a human reopening sessions, never throws away work):
#   - only a cleanly RESOLVED ticket's worktree is torn down; failed/parked/timed-out worktrees
#     are KEPT on disk (uncommitted work survives) and their path is logged.
#   - before spawning, an existing open PR for the ticket (branch ticket-<N>) is detected and the
#     run RESUMES from it (CI→merge→bookkeep) instead of opening a duplicate PR.
#   - a clean interrupt (SIGINT/SIGTERM) leaves the in-flight ticket in tickets.md + its worktree,
#     so a re-run continues.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

MODE=live; TARGETS=(); EXCLUDE_INIT=""; PARALLEL=0; PARALLEL_N=""; SERIAL=0; ORCHESTRATED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      MODE=dry;;
    # INTERNAL (set only by govern::_parallel_spawn, never by a human): "an orchestrator already ran
    # this run's run-start reconcile — don't repeat it". See the RECONCILE block below.
    --orchestrated) ORCHESTRATED=1;;
    --exclude)      shift; EXCLUDE_INIT="${EXCLUDE_INIT:+$EXCLUDE_INIT,}${1//[^0-9,]/}";;
    --exclude=*)    EXCLUDE_INIT="${EXCLUDE_INIT:+$EXCLUDE_INIT,}${1#--exclude=}"; EXCLUDE_INIT="${EXCLUDE_INIT//[^0-9,]/}";;
    --parallel)     PARALLEL=1;;
    --parallel=*)   PARALLEL=1; PARALLEL_N="${1#--parallel=}"; PARALLEL_N="${PARALLEL_N//[^0-9]/}";;
    --serial|--no-parallel) SERIAL=1;;
    # Ticket SET fix: collect EVERY numeric arg into TARGETS instead of overwriting a single
    # TARGET — `run-loop.sh 152 153 154 155` previously kept only the LAST number (155) and
    # silently worked one ticket while the run reported success. A repeated number is folded
    # (no-op), never a second pass over the same ticket.
    [0-9]*)         case ",$(IFS=,; echo "${TARGETS[*]:-}")," in *",$1,"*) ;; *) TARGETS+=("$1");; esac;;
    *) govern::die "unknown arg: $1";;
  esac
  shift
done
# NAMED DISPATCH IS MANDATORY. No tickets named = nothing to do; there is no backlog selection to
# fall back on. Exit 2 (usage error), never 0: a bare invocation in a script or a cron line must
# fail loudly rather than look like a successful empty run.
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  cat >&2 <<'USAGE'
usage: run-loop.sh [--dry-run] [--exclude N,N,...] [--parallel[=N]|--serial] <ticket-number> ...

Name the ticket(s) to work. There is no backlog sweep: you choose what matters, and each
dispatched ticket gets done at the least spend, with every gate on.

  run-loop.sh 42                 one ticket, sequential and unbatched
  run-loop.sh 42 43 44           that exact set, grouped by file locality
  run-loop.sh --dry-run 42       plan-mode worker; no merge, no bookkeep

  govern:audit                   manual supervisor review (zero spend unless invoked)
  govern:budgets                 enforce the CLAUDE.md / lessons / learnings budgets
  govern:trim                    evidence-based CLAUDE.md trim (auto-moves proven-dead blocks, proposes the rest)
USAGE
  exit 2
fi
# --exclude drops numbers from the NAMED set (a peer session already owns them). Applied here, once,
# so every later reader sees the set the operator actually asked this process to work.
if [[ -n "$EXCLUDE_INIT" ]]; then
  _kept=()
  for _t in "${TARGETS[@]}"; do
    case ",$EXCLUDE_INIT," in *",$_t,"*) govern::log "excluding #$_t from the named set (--exclude)";; *) _kept+=("$_t");; esac
  done
  TARGETS=(${_kept[@]+"${_kept[@]}"})
  [[ "${#TARGETS[@]}" -gt 0 ]] || govern::die "--exclude removed every named ticket; nothing to dispatch"
fi
# --parallel bare (no =N) falls back to GOVERN_PARALLEL, then a set-sized/default cap.
# An explicit `--parallel=N` always wins over GOVERN_PARALLEL (flag > env, per the CLI contract
# every other flag here follows). GOVERN_PARALLEL alone (no --parallel flag at all) also turns
# parallel mode ON: an operator scripting via env-only shouldn't need the flag too.
[[ "$PARALLEL" -eq 0 && -n "${GOVERN_PARALLEL:-}" ]] && PARALLEL=1
if [[ "$PARALLEL" -eq 1 && -z "$PARALLEL_N" ]]; then
  PARALLEL_N="${GOVERN_PARALLEL:-}"
  PARALLEL_N="${PARALLEL_N//[^0-9]/}"
fi
# TARGET: single-value alias, used only for log/summary strings that read naturally in the
# one-ticket case. Every behavioural branch reads TARGETS / the resolved locality groups.
TARGET=""; [[ "${#TARGETS[@]}" -eq 1 ]] && TARGET="${TARGETS[0]}"
# GOVERN_PARALLEL_DEFAULT: the per-workspace DEFAULT concurrency, set in scripts/lib/workspace.sh
# (or the env). Unset or 1 = sequential; N > 1 = fan out at cap N over the named set's locality
# groups. The fallback is 4, not 1, and that is load-bearing: `/shiploop:update` PRESERVES a
# workspace's scripts/lib/workspace.sh, so an EXISTING fleet can never pick up a new default from
# the template; this fallback is the only path that reaches them. An explicit knob (including 1)
# always wins, and `--serial` opts out for any single run.
# The carve-out is EXACTLY ONE named ticket: "just this one" means sequential and unbatched, always.
PARALLEL_DEFAULT="${GOVERN_PARALLEL_DEFAULT:-4}"; PARALLEL_DEFAULT="${PARALLEL_DEFAULT//[^0-9]/}"
PARALLEL_DEFAULT="${PARALLEL_DEFAULT:-4}"
if [[ "$SERIAL" -eq 0 && "$PARALLEL" -eq 0 && "${#TARGETS[@]}" -gt 1 && "$PARALLEL_DEFAULT" -gt 1 ]]; then
  PARALLEL=1
fi
# Provisional cap: the named-set size is the upper bound. It is clamped to the actual LOCALITY GROUP
# count once the set is partitioned (see the dispatch block) so the fleet is sized in groups, never
# in tickets: two tickets that share a file are one worker, not two racing on the same lines.
if [[ "$PARALLEL" -eq 1 && -z "$PARALLEL_N" ]]; then
  if [[ "$PARALLEL_DEFAULT" -gt 1 ]]; then PARALLEL_N="$PARALLEL_DEFAULT"; else PARALLEL_N="${#TARGETS[@]}"; fi
fi
# --serial, --parallel=1, GOVERN_PARALLEL=1 and a single named ticket all mean the same thing:
# the sequential driver. A cap-1 orchestrator is a process layer around the loop it wraps.
if [[ "$SERIAL" -eq 1 || "${#TARGETS[@]}" -eq 1 || ( "$PARALLEL" -eq 1 && "${PARALLEL_N:-1}" -le 1 ) ]]; then PARALLEL=0; PARALLEL_N=1; fi
# Human-readable target descriptor for logs/summary: " (single ticket #N)" · " (target set: #A #B · 2)".
# Called at run-start AND at write_summary time (run-end), so it reads TARGETS live; TARGETS is never
# drained and stays a stable record of what was ASKED for.
govern::target_set_desc() {
  local d=""
  case "${#TARGETS[@]}" in
    0) ;;
    1) d=" (single ticket #${TARGETS[0]})";;
    *) d="$(printf ' (target set: %s · %d)' "$(printf '#%s ' "${TARGETS[@]}" | sed 's/ $//')" "${#TARGETS[@]}")";;
  esac
  [[ "${PARALLEL:-0}" -eq 1 ]] && d="$d [parallel, up to ${PARALLEL_N:-?} concurrent group(s)]"
  printf '%s' "$d"
}
MAX_TICKETS="${GOVERN_MAX_TICKETS:-20}"
MAX_BAD_STREAK="${GOVERN_MAX_BAD_STREAK:-4}"
MAX_RUNTIME="${GOVERN_MAX_RUNTIME:-0}"   # 0 = no runtime cap (default)
# #23 locality batching. Max tickets handed to ONE worker as a locality group. 1 = today's behavior
# (one ticket per worker) and is the DELIBERATELY CONSERVATIVE default: batching and parallelism pull
# against each other — past a point, bigger groups trade wall-clock for the token saving — so the
# aggressiveness is an explicit operator knob, not a hard-coded policy. Only ever applies to a BACKLOG
# pull; an explicit ticket set is dispatched exactly as the operator named it.
# §5.3: raised off 1 only AFTER the batch key was re-keyed onto MEASURED file overlap. Raising the cap
# while the key was still a leaf-directory name derived from `Where:` prose would have made things
# strictly worse — arbitrary grouping shares no discovery yet still pays full context accumulation,
# and accumulation is superlinear, so a bad 3-batch costs more than 3 workers. It stays SMALL for the
# same reason: a 5-ticket batch is nowhere near 5× cheaper than 5 workers. Tickets with no measured
# paths are never batched at all, so this only engages where the scout actually surveyed files.
BATCH_MAX="${GOVERN_BATCH_MAX:-2}"; BATCH_MAX="${BATCH_MAX//[^0-9]/}"; [[ -n "$BATCH_MAX" ]] || BATCH_MAX=1
[[ "$BATCH_MAX" -ge 1 ]] || BATCH_MAX=1
START_EPOCH="$(date +%s)"; INTERRUPTED=0; INFRA_HALT=0; INFRA_HALT_ERR=""
# #151: abnormal-abort + in-flight-ticket tracking. ABORTED/ABORT_RC are set by on_exit when the run
# ends on a non-zero exit that is NOT a handled interrupt or infra halt (e.g. `set -e` fired on an
# unguarded post-merge migrate/verify failure). CUR_TICKET is the ticket currently being processed
# (cleared once it reaches a recorded outcome); CUR_TICKET_MERGED accumulates its merged-but-not-yet-
# bookkept PRs — so an abort/interrupt summary names the abort cause AND surfaces the half-resolved
# ticket instead of silently dropping it.
ABORTED=0; ABORT_RC=0; CUR_TICKET=""; CUR_TICKET_MERGED=""

# PID suffix (not just the second-resolution timestamp): a --parallel orchestrator spawns several
# children within the same wall-clock second, and each computes its own RUNDIR independently — the
# suffix keeps their run directories from colliding, and lets the orchestrator find a given child's
# RUNDIR afterward by globbing on that child's known pid (see govern::_parallel_run below).
RUNDIR="$LOG_ROOT/run-$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$RUNDIR"
# #75: every worker spawned this run writes its log under $RUNDIR/ticket-N/ (via govern::worker_logdir),
# so a re-run of ticket N can never read a PRIOR run's stale worker.jsonl. Exported so spawn-worker
# (a child process) inherits it. #183: defined BEFORE the lock so the holder file can record this run id.
export GOVERN_RUN_DIR="$RUNDIR"

# --- run lock. Default: single-run (one exclusive driver). GOVERN_ALLOW_CONCURRENT=1 opts into
# parallel drivers on disjoint tickets (#41): the global lock is skipped, and safety comes from
# the per-ticket CLAIM lock (no two drivers work the same ticket) + the bookkeep lock in
# govern-bookkeep.sh (no two drivers race tickets.md). Use --exclude to partition the named set.
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
# #23: the co-batched tickets of the in-flight locality group, and the claim locks held for them.
# BATCH never includes the primary #N (whose claim is CUR_CLAIM). Every ticket in BATCH is one this
# driver successfully claimed — the group holds a claim on every ticket in it, so the exactly-once
# guarantee the per-ticket claim lock gives a single ticket holds identically for a group.
BATCH=(); BATCH_CLAIMS=()
release_batch_claims() {
  local l
  for l in ${BATCH_CLAIMS[@]+"${BATCH_CLAIMS[@]}"}; do govern::lock_release "$l"; done
  BATCH_CLAIMS=()
}
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
  if [[ -z "$EXCLUDE_INIT" && "${#TARGETS[@]}" -eq 0 ]]; then
    govern::log "concurrency mode: PARALLEL (GOVERN_ALLOW_CONCURRENT=1) with NO --exclude / single ticket — sharing the named set with any peer driver (per-ticket claim + bookkeep lock keep it exactly-once, #41). ⚠ If you did NOT intend parallel, this flag is likely INHERITED from a governor/worker env — unset GOVERN_ALLOW_CONCURRENT to take the exclusive single-run lock (#183)."
  else
    govern::log "concurrency mode: PARALLEL (GOVERN_ALLOW_CONCURRENT=1) — proceeding alongside other drivers on a partitioned named set (--exclude / single ticket); per-ticket claim + bookkeep lock keep tickets.md safe (#41)"
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
HISTORY="$TICKET_HISTORY_FILE"   # common.sh (spawn-worker's retry-class retry classifier reads the same ledger)
# CROSS-DRIVER attempted set — the run-scoped twin of `$excludes`, which is per-PROCESS in-memory
# state and therefore invisible to a sibling driver. Under the parallel default (cap 4) the claim
# lock only keeps two drivers off a ticket WHILE one holds it: a ticket that ends non-resolved
# (timeout / budget-exceeded / failed / parked) is STILL in tickets.md, its claim is released the
# moment its outcome is recorded, and a sibling that reaches selection after that release re-picks
# it and burns a SECOND full worker on a ticket this run has already answered. That is real spend,
# and it also writes a second state.jsonl/ticket-history row for one ticket in one run — which
# double-counts the #60 consecutive-failure streak and makes "what did this run do" ambiguous.
# So: every recorded outcome appends its ticket number here, and each driver folds the file back
# into its own $excludes before selecting. The path is EXPORTED, so the orchestrator's children
# inherit the ORCHESTRATOR's file and the set is shared across the whole fan-out; a plain
# sequential run gets its own file and the fold is a harmless no-op (its $excludes already has it).
# Append-only single-line writes → O_APPEND is atomic enough; a read that races an append simply
# picks the number up on the next iteration, and the claim lock still covers the in-flight window.
# Gated on --orchestrated, NOT on the bare env var: an exported path must only be adopted by a child
# this run's orchestrator actually spawned. Any OTHER run-loop launched inside a live governor session
# (a worker running the test suite, an operator's ad-hoc `run-loop.sh <N>`) also inherits the parent's
# environment — the documented "the test suite inherits the live run's env" hazard — and must get its
# OWN file rather than silently adopting an unrelated run's answered set.
if [[ "$ORCHESTRATED" -eq 1 && -n "${GOVERN_RUN_ATTEMPTED_FILE:-}" ]]; then
  RUN_ATTEMPTED_FILE="$GOVERN_RUN_ATTEMPTED_FILE"
else
  RUN_ATTEMPTED_FILE="$RUNDIR/attempted.txt"
fi
export GOVERN_RUN_ATTEMPTED_FILE="$RUN_ATTEMPTED_FILE"
: >> "$RUN_ATTEMPTED_FILE" 2>/dev/null || true   # `>>` never truncates a file inherited from a parent
excludes="$EXCLUDE_INIT"; bad_streak=0; nres=0; npark=0; nfail=0; ntimeout=0; nbudget=0; nintr=0; nabort=0; done_count=0
# NA_SET = comma-wrapped set of "NOT govern-automatable" tickets (bold marker in body).
# select-ticket already excludes them; this set lets the loop log the human-readable why.
NA_SET=","

# #272: ROI enrichment for the cross-run history. Records what the ticket SPENT (tokens + cost), the
# sizing DECISION that produced that spend (#19: model / effort / attempt), and a churn classification
# from the current $report's PR repos (self-referential harness/templates work vs shipped product).
# Best-effort — every field degrades to null so a missing log or an un-parseable report never blocks
# the outcome record. Emits a JSON object of the extra fields to merge into the history line.
#
# #19 — cost WITHOUT the decision is unlearnable: a row saying "$9.66" with no tier can't answer "does
# this class of ticket actually succeed at sonnet?", so any scope→tier sizing table stays hand-tuned
# forever. spawn-worker.sh now appends one `attempts.jsonl` row per spawn carrying both, and this reads
# it. Spend is SUMMED across the run's attempts (an in-run re-dispatch's tokens belong to this ticket
# too, and the prior attempt's stream is rotated aside so it can't be double-counted); the DECISION
# fields come from the LAST attempt — the one that produced the outcome being recorded.
history_enrich() { # ticket -> echoes {tokens,costUsd,model,effort,attempt,usageSource,churn,repos}
  local n="$1" logdir jsonl attempts_file extra='{}' repos='[]' churn='null'
  logdir="$(govern::worker_logdir "$n")"
  jsonl="$logdir/worker.jsonl"; attempts_file="$logdir/attempts.jsonl"
  if [[ -s "$attempts_file" ]]; then
    extra="$(jq -sc '
      ([ .[] | select(.tokens != null) ]) as $wt
      | { tokens: (if ($wt|length) == 0 then null else
            ($wt | reduce .[] as $r ({input:0,output:0,cacheRead:0,cacheCreation:0,total:0};
              {input:        (.input        + ($r.tokens.input        // 0)),
               output:       (.output       + ($r.tokens.output       // 0)),
               cacheRead:    (.cacheRead    + ($r.tokens.cacheRead    // 0)),
               cacheCreation:(.cacheCreation+ ($r.tokens.cacheCreation// 0)),
               total:        (.total        + ($r.tokens.total        // 0))})) end),
          costUsd: ([ .[].costUsd | select(. != null) ] | if length == 0 then null else add end),
          model:       (.[-1].model       // null),
          effort:      (.[-1].effort      // null),
          attempt:     (.[-1].attempt     // length),
          usageSource: (.[-1].usageSource // null) }' "$attempts_file" 2>/dev/null || echo '{}')"
  else
    # No ledger — a pre-#19 log dir, or a run that recorded an outcome WITHOUT spawning a worker (a
    # resumed ticket, or the #60 auto-park that never spawns). Fall back to reading the stream directly;
    # govern::stream_usage also recovers a killed attempt's tokens from its per-turn usage events, so
    # a failed/timed-out row is no longer null just because there is no final `result` event.
    extra="$(govern::stream_usage "$jsonl" 2>/dev/null || echo '{}')"
  fi
  [[ -n "$extra" ]] || extra='{}'
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
  # Explicit null defaults first, so a row from an OLD log dir still carries every key (consumers can
  # then `select(.model != null)` instead of guessing whether the key exists).
  jq -nc --argjson e "$extra" --argjson ch "$churn" --argjson rp "$repos" \
    '{tokens:null, costUsd:null, model:null, effort:null, attempt:null, usageSource:null}
     + $e + {churn:$ch, repos:$rp}' 2>/dev/null || echo '{}'
}

# Fold the CROSS-DRIVER attempted set into this driver's own $excludes. Called once per loop
# iteration, immediately before selection, so a ticket a SIBLING driver already answered this run is
# invisible to the selector here — the sequential loop's own bookkeeping is unchanged (it has always
# appended $N to $excludes itself, so for a single driver every number read back is already present).
sync_attempted_excludes() {
  [[ -s "$RUN_ATTEMPTED_FILE" ]] || return 0
  local a
  while IFS= read -r a; do
    [[ "$a" =~ ^[0-9]+$ ]] || continue
    [[ ",$excludes," == *",$a,"* ]] && continue
    excludes="${excludes:+$excludes,}$a"
    govern::log "#$a already answered by another driver this run — skipping (no second worker) [#19]"
  done < "$RUN_ATTEMPTED_FILE"
  return 0
}

record() { # ticket status note
  printf '{"ticket":%s,"status":"%s","note":%s}\n' "$1" "$2" "$(jq -Rn --arg s "$3" '$s')" >> "$STATE"
  # Mark the ticket ANSWERED for the whole run, across every driver (see RUN_ATTEMPTED_FILE above).
  # Written for EVERY status, including `infra`/`interrupted` which return before the history write:
  # they are dropped from the CROSS-RUN history on purpose (not the ticket's fault), but within THIS
  # run they have still consumed a worker, so a sibling must not immediately re-spawn on them either.
  printf '%s\n' "$1" >> "$RUN_ATTEMPTED_FILE" 2>/dev/null || true
  # Fleet event log (off unless GOVERN_EVENTS=1). Only `parked` is emitted here: every other status
  # already has a worker_done event from spawn-worker, and duplicating them would make the fold
  # double-count. A park is the one outcome an operator is asked to act on, so it gets its own type.
  if [[ "$2" == "parked" ]]; then govern::event ticket_parked "ticket=$1" "note=$3"; fi
  # #60: persist the outcome to the cross-run history (run id + epoch) — best-effort.
  # #90: NEVER record an infra/auth outage to the cross-run history — it is not the ticket's fault,
  # so it must not count toward #60 auto-escalation or be read back by govern-improve as a hard
  # ticket. (It still lands in this run's STATE above, for the human-readable session summary.)
  # #34: same for `interrupted` — a transient mid-stream connection drop (laptop sleep) is an
  # ENVIRONMENT artifact, not ticket difficulty; recording it would falsely auto-escalate a
  # perfectly-good ticket as a #60 systemic blocker.
  case "$2" in infra|interrupted) return 0;; esac
  # #23: same exemption, opt-in via a 4th arg, for a ticket that was CO-BATCHED into another ticket's
  # worker and simply didn't get finished. It never had a worker of its own, so it is not evidence of
  # ticket difficulty — recording it would let two unlucky batches auto-escalate a perfectly good
  # ticket as a #60 systemic blocker. It still lands in this run's STATE above, for the summary.
  [[ "${4:-}" == "no-history" ]] && return 0
  # #272: fold in ROI fields (tokens/cost/churn) so govern-health can surface park rate + churn
  # classes + tokens-per-ticket from ONE durable file, with no worker.jsonl spelunking.
  local base extra
  base="$(jq -nc --argjson t "$1" --arg run "$(basename "$RUNDIR")" --arg st "$2" --argjson ts "$(date +%s)" \
    '{ticket:$t, run:$run, status:$st, ts:$ts}' 2>/dev/null \
    || printf '{"ticket":%s,"run":"%s","status":"%s","ts":%s}' "$1" "$(basename "$RUNDIR")" "$2" "$(date +%s)")"
  # retry-class: stamp the FAILURE SIGNATURE the driver observed (set by the branches that know it — e.g. a
  # park because CI stayed red is a `ci` signature, not a model-tier failure). spawn-worker's retry
  # classifier reads this back on the NEXT attempt and escalates the axis that actually failed
  # instead of always jumping to GOVERN_WORKER_MODEL. Absent → the classifier falls back to the
  # status alone, and an unrecognized status escalates exactly as it did before the classifier.
  if [[ -n "${RETRY_CLASS_HINT:-}" ]]; then
    base="$(jq -c --arg rc "$RETRY_CLASS_HINT" '. + {retryClass:$rc}' <<<"$base" 2>/dev/null || printf '%s' "$base")"
  fi
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
spawn_worker_tracked() { # ticket [batched-ticket...] -> spawn-worker stdout in $SPAWN_OUT; sets+clears WORKER_PID
  local n="$1"; shift
  SPAWN_OUT="$(mktemp)"
  # #21 scout-then-SURVEY: MEASURE #n's scope with a cheap haiku pass BEFORE dispatch. The scout no
  # longer decides a TIER — that verdict was deleted (§5.2: 4 of the 5 verdicts it ever cached were
  # opus/high, and its HARD gate was a disjunction where `testsCover==false` alone forced opus, which
  # is a rubber stamp rather than arbitrage). Tier is now the cheap floor GOVERN_WORKER_MODEL plus
  # escalate-once-on-measured-failure. What the survey still produces is MEASUREMENT that several
  # mechanisms consume: verified `targetPaths` (the batch key and the staleness gate's path list), the
  # warm-start findings block, and the `deterministic` patch checked immediately below.
  # This is the ONE chokepoint every spawn goes through (plain dispatch, retry, CI-fix and
  # conflict-resolve re-dispatch alike), and the survey is cached on the run dir — so the retries
  # below reuse it rather than re-scouting from scratch. Best-effort by construction: a failure caches
  # nothing and every consumer degrades to its no-measurement path. Skipped in dry mode (an
  # observation run must stay free of model calls) and under GOVERN_SCOUT=0.
  if [[ "${GOVERN_SCOUT:-1}" != "0" && "${MODE:-live}" != "dry" ]]; then
    "$DIR/scout-ticket.sh" "$n" >/dev/null || true
  fi
  # Not every ticket earns a full-autonomy worker. When the parent session has EXPLICITLY asserted it
  # is already warm on this exact ticket (govern::warm_assertion — a per-invocation GOVERN_WARM naming
  # one ticket number, never a heuristic), the worker is handed the STATED CHANGE instead of exploring
  # its way to it, and runs cheap. spawn-worker.sh owns that branch (it both sizes the worker and
  # assembles the prompt, so tier and brief cannot disagree); what run-loop owns is the case
  # spawn-worker cannot express — NOT SPAWNING AT ALL. Every ticket with no warm assertion dispatches
  # byte-identically to before.
  if govern::warm_assertion "$n"; then
    if [[ -z "${GOVERN_WARM_TEXT//[[:space:]]/}" ]]; then
      # NO WORKER. The parent asserted it is warm on this ticket but stated no change to make, so
      # there is nothing for a worker to execute. PARK with the assertion recorded — never
      # auto-resolve: "the parent thinks nothing is needed" is a claim for a human to confirm, and a
      # silently dropped ticket is the one outcome this must not produce. The ticket stays in the
      # queue. Synthesised here rather than spawned so the whole downstream park/escalation path is
      # reused unchanged.
      govern::log "worker #$n: NO-DISPATCH — the parent asserted it is warm on this ticket and named no change; parking with the assertion instead of spawning a worker"
      jq -nc --arg t "$n" '{status:"parked", pr:null, prs:[], newTickets:[], crossRefs:{overlaps:[],dependsOn:[]}, migration:null,
        validation:{required:false,ranLiveTest:false,evidence:""},
        escalation:{title:"warm parent dispatched no worker",
          reason:"the session driving this run asserted it is already warm on #\($t) and named no change to make, so no worker was spawned (GOVERN_WARM with an empty stated change)",
          question:"confirm nothing is needed and close the ticket, or restate the change so a worker can execute it",
          options:[]}}' > "$SPAWN_OUT" 2>/dev/null || printf '{"status":"parked","escalation":null}' > "$SPAWN_OUT"
      return 0
    fi
    govern::log "worker #$n: EXECUTE-ONLY dispatch — the parent asserted it is warm on this ticket; the worker gets the stated change and runs at the cheap tier (GOVERN_EXECUTE_ONLY=0 to disable this branch)"
  fi
  # §4.2 DETERMINISTIC LANE — model → no model, the one arbitrage with no ceiling. Tier arbitrage is
  # bounded (opus→sonnet is ~5×); resolving a ticket with ZERO model turns is not. A real share of any
  # backlog is mechanical: flip a default, add a key, bump a version, delete a stale line, apply a
  # known rename. The scout above already read the real code, so the patch rides on an EXISTING model
  # call — this lane adds none of its own.
  #
  # Placed AFTER the warm-assertion branch so an explicit parent assertion always wins, and skipped
  # for a locality batch ($# > 0) because the report it emits carries no per-ticket `tickets` array
  # and bookkeeping would mark the batch-mates resolved without them ever being touched.
  # Conservative by construction: ANY ambiguity exits non-zero and we fall through to a real worker,
  # which is exactly the status quo. Ships inert (GOVERN_DETERMINISTIC=0).
  if [[ "$#" -eq 0 && "${GOVERN_DETERMINISTIC:-0}" == "1" ]]; then
    # Build the flag list as an array — a bare `[[ ]] && printf` inside a command substitution returns
    # the conditional's status and can abort this function under `set -e` (a known trap in this tree).
    local -a det_flags=()
    [[ "${MODE:-live}" == "dry" ]] && det_flags+=(--dry-run)
    if "$DIR/deterministic-apply.sh" ${det_flags[@]+"${det_flags[@]}"} "$n" >"$SPAWN_OUT" 2>/dev/null; then
      govern::log "worker #$n: ZERO-MODEL resolution — the scout named a deterministic transformation, the patch applied and verified, no worker was spawned"
      return 0
    fi
    govern::log "worker #$n: deterministic lane declined (not confidently mechanical) — dispatching a normal worker"
  fi
  # #23: extra args are the co-batched tickets of #n's locality group (empty for a plain single spawn).
  "$DIR/spawn-worker.sh" "$n" "$@" >"$SPAWN_OUT" &
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
        elif ($e.status=="failed" or $e.status=="timeout" or $e.status=="budget-exceeded" or $e.status=="early-abort") then {n:(.n+1),stop:false}
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
    echo "- **Mode:** $MODE$(govern::target_set_desc)"
    echo "- **Tickets:** processed ${done_count:-0} → ✅ resolved ${nres:-0} · ⏸ parked ${npark:-0} · ✖ failed ${nfail:-0} · ⏱ timed-out ${ntimeout:-0} · 💸 budget-exceeded ${nbudget:-0} · ↻ interrupted ${nintr:-0}"
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
  release_batch_claims                                         # …and every co-batched ticket's claim (#23)
  # #183: the single-run lock dir now holds a `holder` file, so `rm -rf` (not rmdir, which fails on a
  # non-empty dir). Only this run's own lock is removed (TOOK_LOCK=1) — a PARALLEL driver never took it.
  if [[ "$TOOK_LOCK" -eq 1 ]]; then rm -rf "$LOCK" 2>/dev/null || true; fi
}
trap 'on_exit' EXIT
# #242: on a stop signal, FIRST reap the in-flight worker subtree (spawn-worker + worker + tool
# grandchildren) so a killed driver never leaves orphans, THEN exit (the EXIT trap's on_exit runs after).
trap 'INTERRUPTED=1; govern::log "INTERRUPTED — in-flight ticket kept in tickets.md + worktree preserved; re-run resumes."; govern_teardown_worker; exit 130' INT TERM

govern::log "run $RUNDIR (mode=$MODE, target=${TARGET:-set}, max=$MAX_TICKETS, bad-streak=$MAX_BAD_STREAK, runtime=${MAX_RUNTIME}s)"
# Fleet event log (off unless GOVERN_EVENTS=1) — the first line of a run, so every reader knows a
# fleet exists before any worker has been spawned.
govern::event run_started "mode=$MODE" "target=${TARGET:-set}" "max_tickets=$MAX_TICKETS" \
  "runtime=$MAX_RUNTIME" "parallel=$([[ "$PARALLEL" -eq 1 ]] && printf '%s' "$PARALLEL_N" || printf '1')" \
  "rundir=$RUNDIR" "pid=$$"
# Ticket-SET fix: log the FULL parsed target set at run start, unconditionally, so a truncation
# bug like the one this fixes (four numbers given, only the last kept) can never be silent again —
# the operator can always diff what they typed against this line.
govern::log "targets:$(govern::target_set_desc)"
# Announce the RESOLVED concurrency mode unconditionally, before anything can short-circuit (an
# a target that turns out ineligible), so "which mode
# am I actually in, and at what cap" must never be something the operator has to infer from whether
# later fan-out lines happened to appear.
if [[ "$PARALLEL" -eq 1 ]]; then
  govern::log "concurrency: parallel — up to $PARALLEL_N group(s) at once (provisional cap; clamped to the locality-group count below. --serial or --parallel=1 for one-at-a-time)"
else
  govern::log "concurrency: serial — one group at a time (--parallel[=N] to fan out)"
fi

# Meta-repo checkout root that owns the queue/ folder (== origin/main for the harness lane). Resolved
# via the git toplevel (NOT dirname "$TICKETS_FILE", which is now the queue/ subfolder) so the
# run-start preflight (#71) and the per-ticket cross-driver re-verify (#108) operate on the repo root.
META_DIR="$(govern::meta_root)"

# ── run-start reconcile: ONCE PER RUN, never once per driver ────────────────────────────────
# The three run-start steps below (escalations-apply-answers → escalations-emit-pending →
# preflight-main) plus the NA-skip streak bookkeeping are WHOLE-RUN state
# reconciliation against the SINGLE shared meta checkout: they fetch/rebase/push main, rewrite
# escalations.md / pending-escalations.json / tickets.md, and file GitHub issues. Nothing serializes
# them — the bookkeep lock only covers tickets.md edits — so when the orchestrator fanned out N full
# drivers, all N re-ran the same git work against the same checkout concurrently (N-1 of
# them pure waste, and a real interleaving hazard: two `git pull --rebase` + `git push` racing in one
# worktree). GOVERN_PARALLEL_STAGGER_S only narrowed the window, it never closed it.
#
# The orchestrator ALREADY runs this block itself, before it spawns anything (it is the same
# top-of-script path), and it holds the single-run lock while doing so. So the correct shape is:
# orchestrator reconciles once → children skip it via the internal --orchestrated flag. One reconcile
# per run is both correct and cheaper. Everything AFTER this block (waits refresh, issue de-dup,
# selection) stays per-driver: those compute each driver's own exclusion set and take no git action.
RECONCILE=1
if [[ "$ORCHESTRATED" -eq 1 ]]; then
  RECONCILE=0
  govern::log "run-start reconcile: skipped — the orchestrator already ran it once for this run"
fi

# #62: close the escalation lifecycle BEFORE selecting tickets — apply any operator answers the
# relay recorded into escalations.md since the last run. "do-the-work" un-parks (the ticket
# becomes selectable again this run); "defer" migrates the ticket to tickets-parked.md; a
# "make this a rule" answer grows preferences.md. Without this, answers stay inert file text and
# parked decisions never migrate (the gap #62 fixes). Live only; dry-run logs intent.
if [[ "$RECONCILE" -eq 1 && "$MODE" == "live" ]]; then
  "$DIR/escalations-apply-answers.sh" >&2 || govern::log "escalations-apply-answers failed (non-fatal) — continuing"
  # #3/#337: regenerate governor/pending-escalations.json at run-START (not only run-end) against the
  # cleaned escalations.md, so a stale/ghost snapshot left by a crashed run or a manual resolution
  # (a pending entry for an escalation no longer open, or a missing genuinely-open one) is corrected
  # BEFORE anything reads it. escalations.md ## Open is the source of truth, not this cached JSON.
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" >/dev/null 2>&1 \
    || govern::log "run-start pending-escalations regen failed (non-fatal)"
elif [[ "$RECONCILE" -eq 1 ]]; then
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
if [[ "$RECONCILE" -eq 1 && "$MODE" == "live" ]]; then
  "$DIR/preflight-main.sh" "$META_DIR" \
    || govern::die "run-start preflight: could NOT reconcile the meta-repo main checkout with origin/main — see the SPECIFIC reason logged just above (an uncommitted runtime artifact to commit/stash, a genuine rebase conflict, or a rejected push), not necessarily a divergence. Until reconciled, the harness lane would cut PRs off a stale base (#71). Resolve it — e.g. cd '$META_DIR' && git status && git pull --rebase origin main && git push — then re-run."
elif [[ "$RECONCILE" -eq 1 ]]; then
  govern::log "[dry] would preflight-reconcile meta main with origin/main before the harness lane (#71)"
fi

# #49: run-start preflight — refuse to dispatch this run's whole wave of workers onto an
# unambiguously CI-red base branch. Measured: ticket #46 was dispatched while main was red; its
# PR inherited the broken baseline and was recorded 'failed' after a full worker session — under
# --parallel (the default) a red baseline fails EVERY concurrent worker in the wave, not just one.
# Cheap (one `gh run list` per repo, no tokens), so check it here rather than discover it via
# await-ci.sh after N workers have each opened a PR. Fail-open by design (see preflight-base-ci.sh):
# gh missing/unauthenticated, no CI configured, no runs yet, an in-progress run, or an API error all
# proceed unchanged. GOVERN_SKIP_BASE_CHECK=1 opts out (e.g. the ticket being worked IS the CI fix).
if [[ "$RECONCILE" -eq 1 && "$MODE" == "live" ]]; then
  "$DIR/preflight-base-ci.sh" \
    || govern::die "run-start preflight: base branch CI is RED — see the failing run URL logged just above (#49). Fix it first (or dispatch the ticket that fixes it), or set GOVERN_SKIP_BASE_CHECK=1 to proceed anyway."
elif [[ "$RECONCILE" -eq 1 ]]; then
  govern::log "[dry] would check the base branch's latest CI conclusion before dispatching workers, and refuse to proceed on an unambiguous red (#49)"
fi

# The externalization lane is NOT on the dispatch path. It is a whole-QUEUE grooming pass (file every
# open Low-severity ticket as a public GitHub issue and drop it from tickets.md), which is exactly the
# queue-order spend named dispatch exists to stop paying on every run. The script is unchanged and
# still shipped; run it deliberately: `npm run govern:externalize` (add --dry to rehearse).

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
  # The streak counter + its one-time nudge are per-RUN state, so only the reconciling driver may
  # touch them: N fan-out children each bumping would inflate the streak ~N× per run and race the
  # nudge's has_open_escalation guard into filing duplicates. Children still LOG the skip and
  # still exclude the ticket — only the shared bookkeeping is orchestrator-only.
  if [[ "$RECONCILE" -eq 1 && "$MODE" == "live" ]]; then
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
[[ "$RECONCILE" -eq 1 && "$MODE" == "live" ]] && govern::na_skip_prune "$NA_SET"

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

# #119: cross-run wait-for-merge deferrals recorded in governor/pending-waits.json. Nothing WRITES
# that file any more (its only writer was the periodic supervisor, deleted with the sweep), but a
# fleet upgrading from an earlier version can carry one, so the run-start re-check stays: a wait whose
# PR is still OPEN (or whose depended-on ticket is still in tickets.md) re-excludes its ticket and
# says so; a cleared wait is dropped, which is how a stale file drains itself to empty over time.
if [[ "$MODE" == "live" ]]; then
  while IFS=$'\t' read -r _wt _wwhy; do
    [[ "$_wt" =~ ^[0-9]+$ ]] || continue
    excludes="${excludes:+$excludes,}$_wt"
    govern::log "#$_wt still blocked — $_wwhy; deferring (cross-run wait persists) (#119)"
  done < <(govern::waits_refresh)
else
  govern::log "[dry] would re-check governor/pending-waits.json + defer tickets whose blocker is unresolved (#119)"
fi

# Self-improvement (observe → propose, never auto-apply): when a run hit friction, a fresh
# read-only reviewer proposes concrete harness improvements into governor/improvements.md.
#
# ONE PASS PER DISPATCH, NOT ONE PER DRIVER. This used to fire at the end of every driver, so an
# N-way parallel run produced N reviews of N slices of the same run and filed N near-identical
# tickets (#75 and #76 are the same wall-clock run, two drivers, two duplicates). A whole-dispatch
# pass belongs in the ORCHESTRATOR, over the AGGREGATED state after reaping. It is called from the
# run-end block at the bottom of this file, which children skip via --orchestrated.
govern::_improve_final() { # <rundir> <label> <nfail> <npark> <review-file>
  local rundir="$1" label="$2" _nfail="${3:-0}" _npark="${4:-0}" review="${5:-}"
  [[ "${GOVERN_IMPROVE:-1}" == "1" && "$MODE" == "live" ]] || return 0
  [[ "$_nfail" -gt 0 || "$_npark" -gt 0 || -s "$review" ]] || return 0
  govern::log "self-improvement review ($label) → governor/improvements.md"
  "$DIR/govern-improve.sh" "$rundir" >/dev/null 2>&1 || govern::log "improve step skipped (error)"
  # CLASSIFIED promotion bridge: auto-file the SAFE/additive proposals govern-improve just appended
  # as a ticket (via file-ticket.sh) so the governor drains them like any ticket, removing the manual
  # promote step. Rail-touching / OPERATOR-DECISION proposals (GOVERN_MAX_* bounds, merge allowlist,
  # permission mode, green-or-none gate) are NEVER auto-queued — they stay human-gated in
  # improvements.md. Default ON; GOVERN_IMPROVE_TRIAGE=0 to disable. Scoped to THIS run's block by run-id.
  if [[ "${GOVERN_IMPROVE_TRIAGE:-1}" == "1" ]]; then
    "$DIR/govern-improve-triage.sh" "$(basename "$rundir")" >/dev/null 2>&1 \
      || govern::log "improve-triage step skipped (error)"
  fi
  return 0
}

# ── resolve the named set into LOCALITY DISPATCH_GROUPS ───────────────────────────────────────────────────
# Two things happen here, once, before anything is dispatched:
#   1. ELIGIBILITY + ORDER. select-ticket.sh filters the named set (open escalation, NOT-automatable,
#      sync-port collision) and orders what survives by severity. Every named ticket that does NOT
#      survive is named in the log with why, so a target the operator asked for can never silently
#      vanish.
#   2. LOCALITY PARTITION. The survivors are partitioned by MEASURED file overlap (the scout's
#      targetPaths), at most GOVERN_BATCH_MAX per group, dependency-related tickets kept apart. This
#      is the #55 fix: `run-loop.sh 24 25 26 --parallel` used to spawn three ungrouped drivers even
#      with GOVERN_BATCH_MAX=3, putting concurrent workers on the same file. Now a group is one
#      worker and one PR, and the fleet is sized in DISPATCH_GROUPS, never in tickets.
# EXACTLY ONE named ticket is the carve-out: no grouping, no orchestrator, no batching. "Just this
# one" is an instruction, not an optimization opportunity.
# NB: the array is DISPATCH_GROUPS, not GROUPS. `GROUPS` is a bash special variable (the caller's
# supplementary group ids); assigning to it is silently ignored, so a group array named GROUPS
# dispatches the operator's unix gids as ticket numbers. Measured, not theoretical.
DISPATCH_GROUPS=()
ELIGIBLE_CSV=""
while IFS= read -r _et; do
  [[ "$_et" =~ ^[0-9]+$ ]] || continue
  ELIGIBLE_CSV="${ELIGIBLE_CSV:+$ELIGIBLE_CSV,}$_et"
done < <("$DIR/select-ticket.sh" "$excludes" "$(IFS=,; echo "${TARGETS[*]}")" 2>/dev/null || true)
for _t in "${TARGETS[@]}"; do
  case ",$ELIGIBLE_CSV," in *",$_t,"*) continue;; esac
  if grep -qE "^##[[:space:]]+#$_t([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null; then
    govern::log "target #$_t not eligible (excluded / open escalation / not-automatable / sync-port collision) — skipping"
  else
    govern::log "target #$_t not found in tickets.md — skipping"
  fi
done
if [[ -z "$ELIGIBLE_CSV" ]]; then
  govern::log "no named ticket is eligible — nothing dispatched"
elif [[ "${#TARGETS[@]}" -eq 1 || "$BATCH_MAX" -le 1 ]]; then
  for _t in ${ELIGIBLE_CSV//,/ }; do DISPATCH_GROUPS+=("$_t"); done
else
  while IFS= read -r _g; do
    [[ -n "$_g" ]] && DISPATCH_GROUPS+=("$_g")
  done < <(govern::locality_groups "$BATCH_MAX" "$ELIGIBLE_CSV" "$TICKETS_FILE" 2>/dev/null || true)
  # Fail-open: if the partitioner produced nothing (no scout cache, a parse hiccup), fall back to
  # one ticket per group rather than dispatching nothing.
  if [[ "${#DISPATCH_GROUPS[@]}" -eq 0 ]]; then
    for _t in ${ELIGIBLE_CSV//,/ }; do DISPATCH_GROUPS+=("$_t"); done
  fi
  for _g in "${DISPATCH_GROUPS[@]}"; do
    case "$_g" in *,*) govern::log "locality group: $(printf '#%s ' ${_g//,/ })— one worker, one PR (GOVERN_BATCH_MAX=$BATCH_MAX)";; esac
  done
fi
# Clamp the fan-out to the actual group count and collapse a single group back onto the sequential
# driver: an orchestrator-of-one is a process layer around the loop it wraps.
if [[ "$PARALLEL" -eq 1 ]]; then
  [[ "$PARALLEL_N" -le "${#DISPATCH_GROUPS[@]}" ]] || PARALLEL_N="${#DISPATCH_GROUPS[@]}"
  if [[ "${#DISPATCH_GROUPS[@]}" -le 1 ]]; then PARALLEL=0; PARALLEL_N=1; fi
fi
govern::log "dispatching ${#DISPATCH_GROUPS[@]} locality group(s) from ${#TARGETS[@]} named ticket(s)$( [[ "$PARALLEL" -eq 1 ]] && printf ', up to %s concurrent' "$PARALLEL_N" )"

# ── --parallel orchestrator ──────────────────────────────────────────────────────────────────────
# Composes the SAME machinery a manual "launch N drivers, each with GOVERN_ALLOW_CONCURRENT=1"
# recipe always used: the per-ticket claim lock + the bookkeep lock (both documented above) are what
# make concurrent drivers exactly-once safe. This adds nothing new to that safety model, it only
# drives the fan-out/wait/aggregate a human would otherwise do across N terminals.
#
# ONE CHILD PER LOCALITY GROUP, and each child is a FULL driver handed that group's ticket numbers.
# This is #55 option (b): rather than re-implement every gate in the orchestrator, the child runs the
# ordinary named-dispatch path, so the claim lock, the cross-driver re-verify, the Depends-on gate,
# the staleness gate, the upstream-drift pregate and the #60 failure-streak breaker all still fire.
# The orchestrator owns only what must happen ONCE for the whole dispatch: the run-start reconcile
# (before spawning) and the run-end blocks (after reaping).
#
# Reaps children FIFO (oldest first) with a plain `wait <pid>` — no `wait -n` — so a pid is never
# waited on twice and this works on any bash new enough for arrays.
PARALLEL_PIDS=(); PARALLEL_TIX=(); PARALLEL_RC=0
PARALLEL_TRES=0; PARALLEL_TPARK=0; PARALLEL_TFAIL=0; PARALLEL_TTIME=0; PARALLEL_TINTR=0
PARALLEL_TICKETS=0; PARALLEL_DRIVERS=0
govern::_parallel_reap_one() {
  local pid="${PARALLEL_PIDS[0]}" lbl="${PARALLEL_TIX[0]}" rd st rows=0
  PARALLEL_PIDS=("${PARALLEL_PIDS[@]:1}"); PARALLEL_TIX=("${PARALLEL_TIX[@]:1}")
  if wait "$pid"; then :; else PARALLEL_RC=1; fi
  rd="$(ls -d "$LOG_ROOT"/run-*-"$pid" 2>/dev/null | head -1 || true)"
  if [[ -n "$rd" && -f "$rd/state.jsonl" ]]; then
    # Fold the child's per-ticket rows into THIS run's state.jsonl, so the orchestrator's run dir
    # stays the single place to read what a dispatch did — otherwise "the run's outcomes" would be
    # scattered across N child run dirs and every reader (summary, an operator, a test) would have
    # to know the fan-out shape to find them.
    cat "$rd/state.jsonl" >> "$STATE" 2>/dev/null || true
    while IFS= read -r st; do
      [[ -n "$st" ]] || continue
      rows=$((rows+1))
      case "$st" in
        resolved)    PARALLEL_TRES=$((PARALLEL_TRES+1));;
        parked)      PARALLEL_TPARK=$((PARALLEL_TPARK+1));;
        failed)      PARALLEL_TFAIL=$((PARALLEL_TFAIL+1));;
        timeout)     PARALLEL_TTIME=$((PARALLEL_TTIME+1));;
        interrupted) PARALLEL_TINTR=$((PARALLEL_TINTR+1));;
        *) rows=$((rows-1)); govern::log "parallel: driver $lbl (pid $pid) left an unrecognized status '$st' — not tallied, see $rd";;
      esac
    done < <(jq -r '.status // empty' "$rd/state.jsonl" 2>/dev/null || true)
    PARALLEL_TICKETS=$((PARALLEL_TICKETS+rows))
    govern::log "parallel: driver $lbl done (pid $pid, $rows ticket(s)) → $rd"
    govern::event driver_reaped "label=$lbl" "pid=$pid" "tickets=$rows" "ok=true"
  else
    PARALLEL_RC=1
    govern::log "parallel: driver $lbl done (pid $pid) — could not locate its run dir/state under $LOG_ROOT; treating as failed for the tally, see the child's own log above"
    PARALLEL_TFAIL=$((PARALLEL_TFAIL+1)); PARALLEL_TICKETS=$((PARALLEL_TICKETS+1))
    govern::event driver_reaped "label=$lbl" "pid=$pid" "tickets=0" "ok=false"
  fi
}
# Spawn one child driver. $1 = label for logs, $2 = "" or "--dry-run", $3… = the group's ticket
# numbers (always at least one: a child is never handed an empty set).
#
# `--serial` + a CLEARED GOVERN_PARALLEL on the child are BOTH load-bearing, not belt-and-braces
# paranoia: a child inherits this process's environment, so under `GOVERN_PARALLEL=4 run-loop.sh …`
# the child would itself resolve to parallel mode, become an orchestrator, and spawn a grandchild —
# which inherits the same env, forever. That is an unbounded fork bomb, reachable today. `--serial`
# is the primary guard (it wins over every other precedence rule); clearing the env keeps the
# child's own mode log honest.
govern::_parallel_spawn() {
  local lbl="$1" dry="$2"; shift 2
  # `--orchestrated`: THIS process already ran the run-start reconcile once, under the single-run
  # lock, and it will run the run-end blocks once after reaping. Children must do neither — N drivers
  # fetching/rebasing/pushing the SAME meta checkout concurrently is wasted git work and a real
  # interleaving hazard, and N run-end passes over N slices of one dispatch is the #40 duplicate.
  GOVERN_ALLOW_CONCURRENT=1 GOVERN_PARALLEL='' bash "$DIR/run-loop.sh" "$@" --serial --orchestrated $dry >&2 &
  PARALLEL_PIDS+=("$!"); PARALLEL_TIX+=("$lbl")
  govern::log "parallel: spawned $lbl (pid $!) — ${#PARALLEL_PIDS[@]}/$PARALLEL_N driver(s) running"
  govern::event driver_spawned "label=$lbl" "pid=${PARALLEL_PIDS[${#PARALLEL_PIDS[@]}-1]}" \
    "running=${#PARALLEL_PIDS[@]}" "cap=$PARALLEL_N"
}
govern::_parallel_run() {
  # A plain string (not an array) here on purpose: bash 3.2 (macOS's /bin/bash) throws "unbound
  # variable" under `set -u` for a bare `"${emptyarray[@]}"` expansion — a real portability trap,
  # not a hypothetical one. dry_flag is always either empty or the single literal word `--dry-run`
  # (no spaces/globs), so plain unquoted word-splitting inside _parallel_spawn is safe.
  local dry_flag=""; [[ "$MODE" == "dry" ]] && dry_flag="--dry-run"
  local g lbl
  govern::log "parallel mode: ${#DISPATCH_GROUPS[@]} locality group(s) across up to $PARALLEL_N concurrent driver(s)"
  for g in "${DISPATCH_GROUPS[@]}"; do
    while [[ "${#PARALLEL_PIDS[@]}" -ge "$PARALLEL_N" ]]; do govern::_parallel_reap_one; done
    lbl="$(printf '#%s ' ${g//,/ } | sed 's/ $//')"
    govern::_parallel_spawn "$lbl" "$dry_flag" ${g//,/ }
    PARALLEL_DRIVERS=$((PARALLEL_DRIVERS+1))
  done
  while [[ "${#PARALLEL_PIDS[@]}" -gt 0 ]]; do govern::_parallel_reap_one; done
  nres="$PARALLEL_TRES"; npark="$PARALLEL_TPARK"; nfail="$PARALLEL_TFAIL"
  ntimeout="$PARALLEL_TTIME"; nintr="$PARALLEL_TINTR"
  done_count="$PARALLEL_TICKETS"
  govern::log "parallel run done: $PARALLEL_DRIVERS driver(s) processed $done_count ticket(s) → resolved $nres · parked $npark · failed $nfail · timed-out $ntimeout · interrupted $nintr"
  return 0
}

# The orchestrator dispatches its groups to children and leaves the sequential loop below empty; the
# run-end blocks after the loop then fire ONCE for the whole dispatch, on either path.
if [[ "$PARALLEL" -eq 1 ]]; then
  govern::_parallel_run || PARALLEL_RC=1
  DISPATCH_GROUPS=()
fi

for _grp in ${DISPATCH_GROUPS[@]+"${DISPATCH_GROUPS[@]}"}; do
  tj_heartbeat   # keep the run-id file fresh (liveness) so a prompt resume re-adopts this run's id (#3)
  # --- hard bounds: stop BEFORE starting another group ---
  if [[ "$done_count" -ge "$MAX_TICKETS" ]]; then govern::log "reached GOVERN_MAX_TICKETS=$MAX_TICKETS — stopping"; break; fi
  elapsed=$(( $(date +%s) - START_EPOCH ))
  if [[ "$MAX_RUNTIME" -gt 0 && "$elapsed" -ge "$MAX_RUNTIME" ]]; then govern::log "reached GOVERN_MAX_RUNTIME=${MAX_RUNTIME}s (elapsed ${elapsed}s) — stopping"; break; fi
  # §5.7 RUN-LEVEL SPEND CEILING (#71). The governor had per-ATTEMPT spend telemetry and per-attempt
  # bounds (GOVERN_WORKER_MAX_TOKENS) but no brake on the RUN. Deterministic — sums this run's own
  # worker streams, no model call. 0 = off (the default), so this ships inert.
  if [[ "${GOVERN_RUN_MAX_TOKENS:-0}" -gt 0 ]]; then
    _run_tok=0
    while IFS= read -r _wj; do
      [[ -n "$_wj" ]] || continue
      _t="$(govern::cumulative_tokens "$_wj" 2>/dev/null || echo 0)"
      [[ "$_t" =~ ^[0-9]+$ ]] || _t=0
      _run_tok=$(( _run_tok + _t ))
    done < <(find "$RUNDIR" -name 'worker*.jsonl' -type f 2>/dev/null || true)
    if [[ "$_run_tok" -ge "${GOVERN_RUN_MAX_TOKENS}" ]]; then
      govern::log "reached GOVERN_RUN_MAX_TOKENS=${GOVERN_RUN_MAX_TOKENS} (run total ${_run_tok}) — stopping cleanly before dispatching another ticket"
      break
    fi
  fi
  # Pre-flight disk guard (#48): never cascade phantom fast-fails on a full disk. If free space
  # is below the worktree headroom, stop CLEANLY with a distinct reason — a disk artifact must
  # not masquerade as worker failures and trip the bad-streak brake.
  if [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
    free_gb=$(df -k "$HOME" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    if [[ "${free_gb:-99}" -lt "${GOVERN_MIN_FREE_GB:-5}" ]]; then
      govern::log "disk low (${free_gb}GB < ${GOVERN_MIN_FREE_GB:-5}GB) — stopping cleanly. Free space or resolve escalations to reclaim parked worktrees, then re-run."
      break
    fi
  fi

  sync_attempted_excludes   # drop anything a SIBLING driver already answered this run (#19)

  # The group's PRIMARY is its first (highest-severity) ticket; the rest ride its single worker + PR.
  N="${_grp%%,*}"
  BATCH=(); BATCH_CLAIMS=()
  case ",$excludes," in *",$N,"*) govern::log "#$N already accounted for this run — skipping its group"; continue;; esac

  # Per-ticket CLAIM lock (#41): two concurrent drivers must never work the same ticket. Non-
  # blocking — if another driver holds it, exclude it this run and pick another (or stop in
  # single-ticket mode). Released after the ticket's outcome; on_exit frees an in-flight claim.
  # #104: take the claim in EVERY mode (dry too), not just live. The acquire/release is purely a
  # mkdir/rmdir under governor/.locks — no PR, no commit, no real side effect — so a dry dual-run
  # faithfully REHEARSES the no-double-claim safety net (two dry drivers on the same named set with
  # NO --exclude visibly contend on .locks/ticket-N) without opening a single real PR. The
  # live-only gate stays on merge/bookkeep/worktree teardown (those DO have side effects); the
  # claim does not.
  CUR_CLAIM="$GOVERNOR_DIR/.locks/ticket-$N"
  if ! govern::lock_try "$CUR_CLAIM"; then
    govern::log "#$N already claimed by another driver — skipping"
    CUR_CLAIM=""
    # Exclude + continue (never break): the remaining groups are independent of this one.
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
  # Runs on EVERY dispatch, named included: a peer session that already shipped #N is exactly the
  # case where "the operator named it" is not a reason to burn a second worker on it.
  if [[ "$MODE" == "live" ]] && ! govern::ticket_present_on_origin "$META_DIR" "$N"; then
    govern::log "#$N no longer on origin/main (resolved+pushed by a concurrent driver) — skipping, no worker burned (#108)"
    govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""
    excludes="$excludes,$N"; continue
  fi

  # #119: pre-spawn dependency gate. If #N's body declares **Depends on:** #K and #K is STILL in
  # tickets.md (unlanded), defer #N this run instead of burning a worker building on something not yet
  # merged (the #80-class wasted run). Same in-run exclude as an escalation skip; the dep is re-derived
  # from the body each run, so #N becomes dispatchable automatically once #K lands.
  # ENFORCED ON NAMED SETS TOO. It used to be skipped whenever a ticket was named, on the theory that
  # the operator chose deliberately: but naming #N does not land #K, and a worker built on an unmerged
  # dependency is the #80-class wasted run whoever picked the ticket. The operator gets a log line
  # naming the blocker, which is more useful than a burned session.
  if true; then
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

  # §4.5 STALENESS GATE. The queue is partly machine-generated (worker `newTickets[]`,
  # govern-improve-triage proposals), so it accumulates duplicates and already-fixed entries.
  # Discovering that today costs a FULL worker — 100% waste, not a factor, and it multiplies against
  # every other saving in this file. Bash only, no model fallback (§10: deterministic or it doesn't
  # ship). FAIL-OPEN by construction: only exit 10 means "confidently stale"; every inconclusive case
  # dispatches, because a false "stale" silently drops real work. Sits AFTER the claim lock so
  # concurrent drivers can't race the same probe. Runs on every named dispatch: a ticket that is
  # already fixed costs a full worker to discover, and naming it does not make it less fixed.
  if [[ "${GOVERN_STALENESS_GATE:-0}" == "1" ]]; then
    _sg_out=""; _sg_rc=0
    _sg_out="$("$DIR/staleness-gate.sh" "$N" 2>/dev/null)" || _sg_rc=$?
    if [[ "$_sg_rc" -eq 10 ]]; then
      govern::log "#$N ${_sg_out:-confidently stale} — skipping, no worker burned (#4.5)"
      govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""
      excludes="$excludes,$N"; continue
    fi
  fi
  govern::log "=== ticket #$N (elapsed ${elapsed}s, done $done_count/$MAX_TICKETS) ==="
  CUR_TICKET="$N"; CUR_TICKET_MERGED=""   # #151: mark in-flight so an abnormal abort/interrupt surfaces #N (+ any merged-but-unbookkept PR)
  RETRY_CLASS_HINT=""                     # retry-class: per-ticket failure signature the driver observes (see record())

  # --- resume: if a prior (crashed) run already opened a PR for this ticket, don't re-spawn ---
  resumed=""; cf=0
  if [[ "$MODE" == "live" ]]; then
    resumed="$(govern::find_pr "$N" || true)"
    # #60: consider the cross-run failure streak whenever there is no PR to resume. This now applies
    # to named dispatch too: a ticket that failed the last GOVERN_MAX_TICKET_FAILS runs fails the same
    # way on the next one, and re-naming it is not new information. It auto-escalates instead, so the
    # operator sees the systemic blocker rather than a third identical burn.
    [[ -z "$resumed" ]] && cf="$(consecutive_fails "$N" 2>/dev/null || echo 0)"
  fi

  # Deterministic UPSTREAM-DRIFT pre-gate. Root CLAUDE.md's "workspace ↔ hub drift" anti-pattern:
  # this workspace dogfoods the harness as a sub-repo, so a ticket whose `Where:` names a mirrored
  # mechanism script may ALREADY be fixed in the hub templates by another fleet. Until now nothing
  # enforced that rule, so a worker could spend a full session re-deriving an existing fix.
  # lib/pregate.sh answers "is the HUB ahead on this exact file?" with pure file/git reads (no LLM,
  # no network, no writes) and is fail-open by construction — any uncertainty emits nothing and we
  # spawn as before. Its ONLY possible outcome is park+escalate; it can never resolve a ticket.
  # Skipped only when the lib is absent (pre-existing workspace). It runs on named dispatch too:
  # "another fleet already shipped this exact fix" is worth the same zero-cost check whoever picked
  # the ticket, and it can only ever park+escalate, never resolve.
  DRIFT=""
  if [[ -z "$resumed" && "${cf:-0}" -lt "${GOVERN_MAX_TICKET_FAILS:-2}" ]] \
     && declare -F govern::pregate_hub_ahead >/dev/null 2>&1; then
    DRIFT="$(govern::pregate_hub_ahead "$N" "$TICKETS_FILE" 2>/dev/null || true)"
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
  elif [[ -n "$DRIFT" ]]; then
    # The hub is ahead on a file this ticket targets — port the diff DOWN rather than paying an
    # agent session to re-derive it. Park + escalate (never resolve): only the operator decides
    # whether the hub version actually covers #N. The escalation keeps #N out of the selector next
    # run, so this cannot loop; answering it (or `/shiploop:update` + closing the escalation) puts
    # #N back in play. Zero LLM tokens spent.
    # Both strings stay SINGLE-LINE: file_open_escalation writes the reason onto one
    # `- **Reason:** …` markdown line, and a newline there would corrupt the block (and the
    # NDJSON the relay parses out of it).
    _dpaths="$(printf '%s' "$DRIFT" | cut -f1 | paste -sd' ' -)"
    _dpairs="$(printf '%s' "$DRIFT" | awk -F'\t' 'NF>=2{printf "%s%s -> %s", (n++?"; ":""), $1, $2}')"
    govern::log "#$N targets file(s) the HUB is AHEAD on ($_dpaths) — not spawning a fresh-fix worker; escalating 'port the hub diff down' (workspace↔hub drift anti-pattern)"
    report="$(jq -nc --arg p "$_dpaths" --arg d "$_dpairs" \
      '{status:"parked",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{
         title:"hub template ahead — port down, do not re-fix",
         reason:("this ticket targets " + $p + ", which this workspace has NOT changed since the templates-sync marker yet which DIFFERS from its hub template — so the hub moved, not us, and the fix it asks for may already exist upstream. Spawning a fresh-fix worker would re-derive it (workspace↔hub drift anti-pattern, root CLAUDE.md). live→template pairs: " + $d),
         question:"diff each pair; if the hub already covers this ticket, pull it down via /shiploop:update and close the ticket — otherwise re-scope the ticket to just the delta and answer here to release it",
         options:["pull the hub down via /shiploop:update, then close or re-scope","port the hub diff by hand","spawn a worker anyway (hub diff is unrelated)"]}}')"
  else
    # #23 LOCALITY BATCHING — the rest of this group rides #N's single worker and single PR.
    # Exploration is the dominant cost of a resolved ticket (~98% cacheRead), so tickets that touch
    # the same files handled by one worker pay discovery ONCE instead of N times. The group itself was
    # partitioned up front (see the dispatch block) by MEASURED file overlap with dependency-related
    # tickets kept apart, so all that is left here is the per-ticket safety the group could not do:
    #   • no unmet **Depends on:** — the same pre-spawn gate #N itself just passed, re-applied per
    #     member so batching can never sneak a dependency-blocked ticket past it, AND
    #   • claimable — we take its per-ticket claim lock here and hold it for the whole group.
    # A member that fails either is simply not batched; #N proceeds with whatever group it got
    # (possibly alone). Claiming greedily rather than all-or-nothing is deliberate: under --parallel a
    # peer driver may hold one member's claim, and that must not collapse the batch. The invariant
    # that matters — this driver holds a claim on EVERY ticket it dispatches — holds either way.
    if [[ "$BATCH_MAX" -gt 1 && "$_grp" == *,* ]]; then
      for bt in ${_grp//,/ }; do
        [[ "$bt" != "$N" ]] || continue
        case ",$excludes," in *",$bt,"*) continue;; esac
        bunmet=""
        while IFS= read -r bk; do
          [[ "$bk" =~ ^[0-9]+$ ]] || continue
          grep -qE "^##[[:space:]]+#$bk([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null && bunmet="${bunmet:+$bunmet, }#$bk"
        done < <(govern::ticket_deps "$bt" "$TICKETS_FILE")
        [[ -z "$bunmet" ]] || { govern::log "batch: #$bt depends on unresolved $bunmet — not batching it (#119)"; continue; }
        if govern::lock_try "$GOVERNOR_DIR/.locks/ticket-$bt"; then
          BATCH+=("$bt"); BATCH_CLAIMS+=("$GOVERNOR_DIR/.locks/ticket-$bt")
        else
          govern::log "batch: #$bt already claimed by another driver — not batching it"
        fi
      done
      [[ "${#BATCH[@]}" -eq 0 ]] \
        || govern::log "batch: #$N + $(printf '#%s ' "${BATCH[@]}")— one worker, one PR, sharing $(govern::ticket_paths "$N" "$TICKETS_FILE" 2>/dev/null | tr '\n' ' ' || true)(GOVERN_BATCH_MAX=$BATCH_MAX)"
    fi
    GOVERN_MODE="$MODE" spawn_worker_tracked "$N" ${BATCH[@]+"${BATCH[@]}"} 2>/dev/null || true
    report="$(cat "$SPAWN_OUT" 2>/dev/null || true)"; rm -f "$SPAWN_OUT"
    # Heartbeat every batched ticket's claim alongside the primary's (same rationale as below).
    for bl in ${BATCH_CLAIMS[@]+"${BATCH_CLAIMS[@]}"}; do govern::lock_heartbeat "$bl"; done
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
  # burning the rest of the dispatch + tripping the generic bad-streak breaker.
  if [[ "$status" == "infra" && "$MODE" == "live" && -z "$resumed" && "${GOVERN_INFRA_RETRY:-1}" == "1" ]]; then
    ierr="$(printf '%s' "$report" | jq -r '.infra.error // "infra/auth outage"' 2>/dev/null || echo 'infra/auth outage')"
    govern::log "#$N hit an INFRA/auth outage ($ierr) — pausing ${GOVERN_INFRA_RETRY_PAUSE:-20}s, retrying once before halting (#90)"
    sleep "${GOVERN_INFRA_RETRY_PAUSE:-20}"
    # retry-class: declare the failure signature to the retry — an auth/transport outage is NOT a sizing
    # failure, so this re-dispatch re-bets the ticket's OWN Model:/Effort: instead of escalating.
    GOVERN_RETRY_CLASS=infra GOVERN_MODE="$MODE" spawn_worker_tracked "$N" ${BATCH[@]+"${BATCH[@]}"} 2>/dev/null || true
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
    # retry-class: same as the infra retry — a transient connection drop is an ENVIRONMENT artifact, so the
    # resume re-bets the ticket's own sizing rather than escalating a tier that never failed.
    GOVERN_RETRY_CLASS=infra GOVERN_MODE="$MODE" spawn_worker_tracked "$N" ${BATCH[@]+"${BATCH[@]}"} 2>/dev/null || true
    report="$(cat "$SPAWN_OUT" 2>/dev/null || true)"; rm -f "$SPAWN_OUT"
    status="$(printf '%s' "$report" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"
  fi

  crossN="$(printf '%s' "$report" | jq -r '((.crossRefs.overlaps//[])+(.crossRefs.dependsOn//[]))|length' 2>/dev/null || echo 0)"

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
  # ticket-id (#N) from its title/body — a local id has no meaning on the repo — and (b) surface
  # any Claude spec/plan file that leaked into the diff (those belong in the root harness, never a
  # public PR). Deterministic net under the worker prompt; idempotent (no #N left → no-op). The branch
  # stays ticket-<N> (the governor tracks by it); only title+body are rewritten.
  # GOVERN_PR_TICKET_REF=1 opts out of (a) — but ONLY for a PRIVATE repo: on a public repo the scrub
  # runs regardless, so the opt-out can never weaken the public-repo guarantee. (b) always runs.
  if [[ "$MODE" == "live" ]]; then
    _pr_num="$(printf '%s' "$report" | jq -r '.pr.number // ""' 2>/dev/null || true)"
    _pr_url="$(printf '%s' "$report" | jq -r '.pr.url // ""' 2>/dev/null || true)"
    _pr_repo="$(printf '%s' "$report" | jq -r '.pr.repo // ""' 2>/dev/null || true)"
    if [[ -n "$_pr_num" ]]; then
      _pr_slug="$(printf '%s' "$_pr_url" | sed -nE 's#https?://github.com/([^/]+/[^/]+)/pull/.*#\1#p')"
      [[ -n "$_pr_slug" ]] || _pr_slug="$(govern::repo_slug "$_pr_repo" 2>/dev/null || true)"
      if [[ -n "$_pr_slug" ]]; then
        _scrub=1
        if [[ "${GOVERN_PR_TICKET_REF:-0}" == "1" ]] && ! govern::repo_is_public "$_pr_repo" 2>/dev/null; then
          _scrub=0
        fi
        if [[ "$_scrub" == "1" ]]; then
          govern::scrub_pr_ticket_ref "$_pr_slug" "$_pr_num" "$N"
        fi
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
    # gate: the recognizer would miss and a code-reading verdict would resolve a validation
    # ticket without live-test evidence, defeating the #67 gate.
    # Recognition itself lives in govern::is_validation_ticket (lib/common.sh) so it stays in
    # sync with the tells worker-prompt.md gives the worker — they had already drifted apart.
    tblock="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
    if govern::is_validation_ticket "$tblock"; then
      case "$(govern::validation_gate_action "$report")" in
        park-no-evidence)
          govern::log "#$N is a VALIDATION ticket but the worker gave no live-test evidence — refusing to auto-resolve; parking for a real test (#67 gate). Any worker PR is left open for review."
          report="$(printf '%s' "$report" | jq -c '.status="parked" | .pr=null | .escalation={title:"validation ticket needs a real test",reason:"reported resolved without running the live test — a validation/spike ticket requires empirical evidence (deploy/snapshot/restore/UI run with captured output), not static code analysis",question:"run the actual test and attach evidence, OR confirm it cannot be automated and decide disposition",options:[]}' 2>/dev/null || printf '%s' "$report")"
          status="parked" ;;
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
          status="parked" ;;
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
              # retry-class: the axis that failed is CI (commonly a portability/env bug — workers verify on
              # macOS while CI runs Linux), NOT the model tier. Tag it so the NEXT attempt
              # re-bets the SAME tier instead of burning a top-tier retry on a `stat -f` bug.
              RETRY_CLASS_HINT="ci"
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
              # retry-class: a gh network/auth/5xx error is an INFRA signature — the worker's sizing was
              # never in question, so a retry must not escalate the tier at all.
              RETRY_CLASS_HINT="infra"
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
      nres=$((nres+1)); bad_streak=0
      # §4.3: refresh the codebase index now that the tree has actually MOVED. Exploration is the
      # dominant cost of a resolved ticket and every worker pays it cold (Read is 7.7% of a worker's
      # tool calls but 31% of its returned bytes, at 6,145 B/call); the index converts per-ticket
      # O(explore) into O(read index) across the repo. Deterministic — git/grep/ctags, never
      # model-generated, because a model-generated digest would be a recurring bill AND would rot.
      # Once per RESOLVED ticket rather than per PR, so a multi-repo ticket rebuilds once. Best-effort:
      # it must never fail a resolution that already landed.
      if [[ "${GOVERN_INDEX:-1}" != "0" && "$MODE" == "live" ]]; then
        "$DIR/codebase-index.sh" build >/dev/null 2>&1 || true
      fi
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
      [[ "$crossN" -gt 0 ]] && govern::log "worker flagged $crossN cross-ref(s) on #$N"
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
      release_batch_claims; BATCH=()   # #23: an infra halt breaks the loop before the per-ticket
                                       # mapping below, so free the group's claims here too.
      govern::log "INFRA HALT — workers cannot authenticate / reach the API ($INFRA_HALT_ERR). Re-authenticate (\`claude login\`) or restore connectivity, then re-run. #$N and the remaining tickets were NOT recorded as failed (#90)."
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
    early-abort)
      # §4.4: the in-flight watchdog killed the worker on a DETERMINISTIC pathology — no file edits in
      # N turns, the same command repeated M times, or a rising tool-error rate — rather than letting
      # it run out a ceiling it was never going to reach usefully. A worker session is 218 assistant
      # turns; a doomed one burns nearly all of them before failing. Killing at ~turn 30 is the whole
      # point of the mechanism, so this must NOT be recorded as a feature failure.
      #
      # Treated exactly like `timeout`/`budget-exceeded`: INCOMPLETE, not failed; worktree PRESERVED so
      # the escalated retry resumes warm from the handoff block the dying worker wrote; counted toward
      # both the in-run bad-streak and the cross-run #60 streak, so a ticket that keeps stalling is
      # still auto-parked instead of retried forever. It gets its own status because "stalled out" and
      # "ran out of clock" are different systemic signals — the first says the tier or the scope is
      # wrong, the second says the work was simply long.
      record "$N" early-abort "killed mid-run by the early-abort watchdog (no progress signal) — INCOMPLETE, not failed; re-run resumes warm. worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
      govern::log "#$N EARLY-ABORT — no progress signal; killed before burning the full budget, worktree PRESERVED at $(wt_path "$N") (retry resumes from the handoff block) [#4.4]"
      slim_worktree "$N"
      excludes="$excludes,$N"; nabort=$((nabort+1)); bad_streak=$((bad_streak+1))
      ;;
    budget-exceeded)
      # #16: the worker was HARD-KILLED by GOVERN_WORKER_MAX_TOKENS before it could write a verdict —
      # same "incomplete, not failed" treatment as `timeout` (mirrors #241 above), but recorded under a
      # DISTINCT status so it stays visible in state.jsonl + cross-run history for its own axis: a
      # ticket that keeps burning its token budget without finishing is a DIFFERENT systemic signal
      # than one that keeps running out the wall clock (e.g. a cheap-tier model in over its depth).
      record "$N" budget-exceeded "killed mid-run — exceeded GOVERN_WORKER_MAX_TOKENS before verdict; INCOMPLETE, not failed; re-run resumes. worktree preserved: $(wt_path "$N")${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}"
      govern::log "#$N BUDGET-EXCEEDED — killed before verdict (token budget); recorded INCOMPLETE (not failed), worktree PRESERVED at $(wt_path "$N") (re-run resumes) [#16]"
      slim_worktree "$N"
      excludes="$excludes,$N"; nbudget=$((nbudget+1)); bad_streak=$((bad_streak+1))
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

  # #23 PER-TICKET OUTCOME MAPPING for a locality group. Constraint (c): a group that partially fails
  # must NOT collapse to one verdict — bookkeeping DELETES a ticket it marks resolved, so a batched
  # ticket the worker never actually fixed would vanish unfixed. Each batched ticket is therefore
  # bookkept ONLY on an explicit `resolved` entry in the report's `tickets` array. Every other
  # value — and a ticket ABSENT from the array, or an unparseable report — records `failed` and
  # LEAVES THE BLOCK IN tickets.md, so a later run simply re-selects it. Fail-closed by construction.
  # The primary #N is deliberately NOT re-processed here: it already went through the full case above
  # (PR discovery, CI await, merge, migration, verify, bookkeep) — this loop covers only the extras,
  # which ride #N's single group PR.
  #
  # SECOND precondition on top of the explicit `resolved`: the group must actually have produced a PR.
  # Doctrine defines "resolved" as "PR opened", and a batched ticket rides the primary's single group
  # PR — so with no PR there is nothing for a `resolved` claim to point at (the shape you get from a
  # timeout / budget-exceeded / interrupted worker, whose synthesized report has no `tickets` array
  # either). Checked once for the whole group. This does NOT collapse the group to one verdict: a
  # primary that PARKED while its PR is open still lets a genuinely-landed batched ticket resolve.
  bpr=0
  if [[ "${#BATCH[@]}" -gt 0 ]]; then
    bpr="$(printf '%s' "$report" | jq -r '
      if ((.pr.url // "") != "") or ((.pr.number // null) != null) or (((.prs // []) | length) > 0)
      then 1 else 0 end' 2>/dev/null || echo 0)"
    [[ "$bpr" == "1" ]] || govern::log "batch: the group produced no PR — every batched ticket stays in tickets.md"
  fi
  for bt in ${BATCH[@]+"${BATCH[@]}"}; do
    bstat="$(govern::batch_ticket_status "$report" "$bt" 2>/dev/null || true)"
    bnote="$(govern::batch_ticket_note "$report" "$bt" 2>/dev/null || true)"
    [[ "$bstat" == "resolved" && "$bpr" != "1" ]] && bstat="no-pr"
    case "$bstat" in
      resolved)
        if [[ "$MODE" == "dry" ]]; then govern::log "[dry] would bookkeep batched #$bt"
        else printf '%s' "$report" | "$DIR/govern-bookkeep.sh" "$bt" >&2 || govern::log "bookkeep failed #$bt"; fi
        record "$bt" resolved "batched with #$N${RESOLVED_PR_SUMMARY:+ — PRs:$RESOLVED_PR_SUMMARY}${bnote:+ — $bnote}"
        govern::log "#$bt RESOLVED (batched with #$N)"
        nres=$((nres+1)); done_count=$((done_count+1))
        ;;
      parked)
        if [[ "$MODE" == "live" ]]; then
          govern::file_open_escalation "$bt" "batched with #$N — ${bnote:0:60}" \
            "${bnote:-worker parked this ticket while resolving locality group #$N}" \
            "review the group PR, then decide how to finish #$bt" "" 2>/dev/null \
            || govern::log "could not file escalation for batched #$bt"
        fi
        record "$bt" parked "batched with #$N${bnote:+ — $bnote}"
        govern::log "#$bt PARKED (batched with #$N) — left in tickets.md"
        excludes="$excludes,$bt"; npark=$((npark+1)); done_count=$((done_count+1))
        ;;
      *)
        # `no-history`: this ticket never had a worker of its own, so a batch miss must not count
        # toward the #60 consecutive-failure auto-escalation. It is NOT counted against bad_streak
        # either — the primary's own outcome is what the circuit breaker reads.
        record "$bt" failed "batched with #$N; no explicit per-ticket 'resolved' in the report${bstat:+ (reported '$bstat')}${bnote:+ — $bnote} — left in tickets.md for a later run" no-history
        govern::log "#$bt NOT resolved in batch with #$N${bstat:+ (reported '$bstat')} — left in tickets.md, will be re-selected"
        excludes="$excludes,$bt"; nfail=$((nfail+1)); done_count=$((done_count+1))
        ;;
    esac
  done

  # release this ticket's claim now its outcome is recorded (#41), and every batched ticket's (#23)
  [[ -n "$CUR_CLAIM" ]] && { govern::lock_release "$CUR_CLAIM"; CUR_CLAIM=""; }
  release_batch_claims; BATCH=()
  # #151: #N reached a recorded terminal outcome (resolved/parked/failed/timeout) above — clear the
  # in-flight marker so a later CLEAN break (circuit-breaker / MAX_TICKETS / supervisor-halt) is not
  # wrongly reported as having a half-resolved ticket in flight.
  CUR_TICKET=""; CUR_TICKET_MERGED=""

  done_count=$((done_count+1))
  if [[ "$bad_streak" -ge "$MAX_BAD_STREAK" ]]; then govern::log "circuit breaker: $bad_streak consecutive parked/failed — halting"; break; fi
done

# ── RUN-END BLOCKS: exactly ONCE per dispatch, in the orchestrator ──────────────────────────────
# Every block below is a WHOLE-DISPATCH pass: it reads this run's aggregated state and writes shared
# files (governor/pending-escalations.json, improvements.md, the sync-port branch). A child driver
# only ever sees its own locality group, so a child running these reviews a FRAGMENT and files a
# near-duplicate of what its siblings file (#75/#76 are one wall-clock run, two drivers, two
# duplicate tickets). The orchestrator holds the whole picture and runs them once after reaping;
# children skip them via the internal --orchestrated flag. A sequential dispatch IS the orchestrator
# and takes this path exactly as before.
RUN_END=1
if [[ "$ORCHESTRATED" -eq 1 ]]; then
  RUN_END=0
  govern::log "run-end blocks: skipped — the orchestrator runs them once for the whole dispatch"
fi

# Out-of-band orphan-resource reap. A per-worker sweep (spawn-worker) only covers a worker the
# governor observed exit, NOT a session that died UNCLEANLY (whose SessionEnd never fired). If the
# workspace ships a scripts/reap-orphan-deploys.sh (deploy/cloud infra, absent by default), call it
# so a dispatch bounds an orphan's lifetime. Guarded on existence + always exits 0.
if [[ "$RUN_END" -eq 1 && "$MODE" == "live" && -f "$DIR/../reap-orphan-deploys.sh" ]]; then
  bash "$DIR/../reap-orphan-deploys.sh" --quiet 2>/dev/null || true
fi

# Durable validation runner (spec §4, reader 1/3): mechanically adopt any terminal validation job the
# runner (ticket #5) left pending, so a validation that finishes with no governor active does not land
# in silence. Purely deterministic (no model call); serialized under the bookkeep mutex so this pass
# and a concurrent SessionStart-hook / `govern validations` reader can never double-stamp the same
# terminal job. Guarded on existence + always non-fatal.
if [[ "$RUN_END" -eq 1 && "$MODE" == "live" && -f "$DIR/validations-pending-apply.sh" ]]; then
  _valapplied="$(bash "$DIR/validations-pending-apply.sh" --reader govern-run-end 2>/dev/null || true)"
  [[ -n "$_valapplied" ]] && govern::log "validation job(s) adopted: $(printf '%s' "$_valapplied" | tr '\n' ' ')"
fi

# Phase 5 flow advisories (ADVISORY ONLY, never auto-files: filing a validation is a human act).
# Surfaces (a) MEASURING flows whose sample window has plausibly elapsed, (b) `Revalidate: every Nd`
# flows now past due, and (c) passive "0 usage" evidence where an analytics adapter is wired. These
# used to ride the periodic supervisor cadence; with that gone they belong here, once per dispatch,
# where the whole run's state is visible. Guarded on the parser + always non-fatal.
if [[ "$RUN_END" -eq 1 && "$MODE" == "live" ]] && command -v govern::flows_due_advisories >/dev/null 2>&1; then
  _fadv="$(govern::flows_due_advisories "$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")" 2>/dev/null || true)"
  if command -v govern::flows_passive_evidence >/dev/null 2>&1; then
    _fpas="$(govern::flows_passive_evidence "$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")" 2>/dev/null || true)"
    [[ -n "$_fpas" ]] && _fadv="${_fadv:+$_fadv$'\n'}$_fpas"
  fi
  if [[ -n "$_fadv" ]]; then
    printf -- '- flow advisories:\n' >> "$REVIEW"
    while IFS= read -r _l; do
      [[ -n "$_l" ]] || continue
      govern::log "flow advisory: $_l"
      printf -- '  - %s\n' "$_l" >> "$REVIEW"
    done <<< "$_fadv"
  fi
fi

if [[ "$RUN_END" -eq 1 ]]; then
  govern::_improve_final "$RUNDIR" "dispatch" "${nfail:-0}" "${npark:-0}" "$REVIEW"
fi

# Opt-in guarded auto-apply (GOVERN_SELF_APPLY=1): apply ONE proposal under strict guards; the
# change takes effect next dispatch. Default off — observe→propose is the default posture.
if [[ "$RUN_END" -eq 1 && "${GOVERN_SELF_APPLY:-0}" == "1" && "$MODE" == "live" ]]; then
  "$DIR/govern-self-apply.sh" "$RUNDIR" 2>&1 | sed 's/^/[self-apply] /' || true
fi

# #337: authoritative run-end emit — LAST, after every run-end escalation writer (park loop, the
# self-improve/self-apply block above), so governor/pending-escalations.json reflects the FINAL
# escalations.md ## Open. This is the #62 operator hand-off: the launching relay reads this JSON and
# presents the still-unanswered entries; the next dispatch's run-start applies the recorded answers.
# Also fires GOVERN_NOTIFY_CMD when pending exist so a no-session dispatch still surfaces a signal.
if [[ "$RUN_END" -eq 1 && "$MODE" == "live" ]]; then
  "$DIR/escalations-emit-pending.sh" "$(basename "$RUNDIR")" "$REVIEW" >/dev/null 2>&1 \
    || govern::log "escalations-emit-pending failed (non-fatal)"
fi

if [[ "${INFRA_HALT:-0}" -eq 1 ]]; then
  govern::log "RUN HALTED on infra/auth outage ($INFRA_HALT_ERR) — re-authenticate (\`claude login\`) or restore connectivity, then re-run. No ticket recorded \`failed\`; affected tickets keep clean #60 history (#90)."
fi
# #272: emit the governor ROI (park rate + churn + tokens/ticket) to the run log at run-end too, so
# it's visible in a tailed session even without opening summary.md. Best-effort, never fatal.
if [[ "$RUN_END" -eq 1 && -x "$DIR/govern-health.sh" && -s "$HISTORY" ]]; then
  GOVERN_HISTORY_FILE="$HISTORY" "$DIR/govern-health.sh" --run "$(basename "$RUNDIR")" 2>/dev/null \
    | while IFS= read -r _hl; do govern::log "health | $_hl"; done || true
fi
govern::log "DONE — resolved=$nres parked=$npark failed=$nfail timed-out=$ntimeout budget-exceeded=$nbudget early-aborted=$nabort interrupted=$nintr (processed $done_count) | state=$STATE review=$REVIEW"
# Fleet event log (off unless GOVERN_EVENTS=1). The terminator every reader folds on: once this
# line lands, `govern:status` reports the run as finished rather than probing pids.
govern::event run_done "resolved=$nres" "parked=$npark" "failed=$nfail" "timeout=$ntimeout" \
  "budget_exceeded=$nbudget" "early_aborted=$nabort" "interrupted=$nintr" "processed=$done_count" \
  "rundir=$RUNDIR"
[[ "$npark" -gt 0 || "$nfail" -gt 0 ]] && govern::log "preserved worktrees for parked/failed tickets remain under $WORKTREE_BASE/ — review then '${ROOT_PM:-npm} run worktree:rm -- ticket-<N>'"

# Auto-trigger sync-port at run-end IFF (a) the mechanism script is present in this workspace AND
# (b) the workspace opted in via GOVERN_UPSTREAM_HARNESS_REPO. Best-effort: a failure here logs but
# never overrides the dispatch's exit code. Set GOVERN_SYNC_PORT_ON_END=0 to disable; --dry-run
# skips it too (nothing was resolved to sync).
if [[ "$RUN_END" -eq 1 \
   && "${GOVERN_SYNC_PORT_ON_END:-1}" == "1" \
   && -n "${GOVERN_UPSTREAM_HARNESS_REPO:-}" \
   && -x "$DIR/sync-port.sh" \
   && "${DRY_RUN:-0}" -ne 1 ]]; then
  govern::log "sync-port: auto-triggering at run-end (GOVERN_UPSTREAM_HARNESS_REPO=$GOVERN_UPSTREAM_HARNESS_REPO)"
  "$DIR/sync-port.sh" 2>&1 | while IFS= read -r _sl; do govern::log "sync-port | $_sl"; done \
    || govern::log "sync-port: exited non-zero (see escalations.md for details, if any)"
fi
exit "${PARALLEL_RC:-0}"
