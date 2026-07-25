#!/usr/bin/env bash
# Durable validation runner — CORE LAUNCHER (harness durable-validation-runner design §1–§3).
#
# THE sanctioned launch path for a long, BILLABLE flow validation script. Running a flow's script
# directly bypasses the whole orphan substrate; this runner is what makes such a run durable and
# orphan-proof:
#   • launches the script setsid-detached (own session/process group → not a harness-tracked task →
#     no ~25-min background cap), non-blocking — returns a job-id immediately;
#   • exports VAL_JOB_ID so every deploy the script makes is name-tagged <jobid>-<label> (reapable);
#   • the runner OWNS the heartbeat (touches ~every GOVERN_VAL_HEARTBEAT_INTERVAL while the flow's
#     process group is alive — liveness, not script cooperation);
#   • enforces a generous wall cap (GOVERN_VAL_TIMEOUT, hours) — on expiry it kills the job's process
#     group and writes terminal ERROR (durable ≠ immortal; a hung-but-alive job must still end);
#   • prunes terminal job dirs on a retention window so logs/govern/validations/ never grows unbounded.
# It NEVER closes boxes itself — orphan cleanup is the workspace's GOVERN_DEPLOY_SWEEP_CMD, which reads
# the verdict this runner exposes as DATA (see the `orphans` subcommand + valjob::orphan_verdict).
#
# Usage:
#   run-validation.sh <flow-id|script.sh> [--max-deploys N]   → launch; prints the job-id, exits 0
#   run-validation.sh orphans                                 → per-orphan-job deploy rows (data only)
# Env: GOVERN_VAL_TIMEOUT (wall cap secs, default 6h) · GOVERN_VAL_HEARTBEAT_INTERVAL (default 30s) ·
#      GOVERN_VAL_JOB_ID (deterministic job-id override) · GOVERN_VAL_PREFLIGHT (refuse-to-start gate).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
source "$DIR/lib/valjob.sh"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"

VALIDATIONS_DIR="${GOVERN_VALIDATIONS_DIR:-$LOG_ROOT/validations}"
INTERVAL="${GOVERN_VAL_HEARTBEAT_INTERVAL:-30}"
TIMEOUT="${GOVERN_VAL_TIMEOUT:-21600}"   # 6h — generous, hours not minutes (§1).

# ── supervise mode (internal; the detached, runner-owned babysitter) ─────────
if [[ "${1:-}" == "--_supervise" ]]; then
  job_id="${2:?job id}"; script="${3:?script}"
  export VAL_JOB_ID="$job_id"
  export VAL_JOB_DIR="$VALIDATIONS_DIR/$job_id"
  export SCRIPT_PATH="$script"
  mkdir -p "$VAL_JOB_DIR"
  valjob::heartbeat_touch                       # seed so orphan_verdict isn't instantly "stale".
  # Launch the flow in its OWN process group. The wrapper records its own pgid (the group leader's
  # pid) then execs the flow, so the pid stays stable for group-kill. setsid gives a full new session
  # where available (Linux); otherwise bash monitor mode (`set -m`) still places the job in its own
  # process group, and nohup + redirected stdio keep it alive past this supervisor's parent.
  wrapper='echo $$ > "$VAL_JOB_DIR/pgid"; exec bash "$SCRIPT_PATH"'
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$wrapper" </dev/null >>"$VAL_JOB_DIR/script.log" 2>&1 &
  else
    set -m
    nohup bash -c "$wrapper" </dev/null >>"$VAL_JOB_DIR/script.log" 2>&1 &
    disown 2>/dev/null || true
    set +m
  fi
  # Read the recorded pgid (bounded ~10s wait for the wrapper to write it).
  pgid=""; for ((i=0; i<50; i++)); do
    if [[ -s "$VAL_JOB_DIR/pgid" ]]; then pgid="$(cat "$VAL_JOB_DIR/pgid" 2>/dev/null)"; break; fi
    sleep 0.2
  done
  if [[ -z "$pgid" ]]; then valjob::terminal ERROR "flow never recorded a pgid — failed to launch"; exit 0; fi

  start="$(date +%s)"
  # Heartbeat + wall-cap loop: one tick == the heartbeat interval; each tick touches the heartbeat and
  # re-checks liveness + the wall cap. Liveness = the process GROUP (negative pid), with a same-pid
  # fallback for the no-setsid path.
  while kill -0 "-$pgid" 2>/dev/null || kill -0 "$pgid" 2>/dev/null; do
    valjob::heartbeat_touch
    now="$(date +%s)"
    if (( now - start >= TIMEOUT )); then
      kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
      sleep 2
      kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
      valjob::terminal ERROR "GOVERN_VAL_TIMEOUT ${TIMEOUT}s wall cap exceeded — job process group killed"
      break
    fi
    sleep "$INTERVAL"
  done
  # If the flow's group is gone but it never wrote a terminal record (crash / external SIGKILL), stamp
  # ERROR: a terminal record makes the job's deploys orphan-candidates for the sweep (orphan-safety).
  [[ -f "$VAL_JOB_DIR/status" ]] || valjob::terminal ERROR "job process group exited without a terminal record"
  exit 0
fi

# ── orphans mode — DATA for the workspace sweep (closes nothing) ─────────────
# Prints, for every ORPHAN job, tab-separated rows: <job-id> <verdict> <deploy-id> <provider>.
# GOVERN_DEPLOY_SWEEP_CMD consumes these to close boxes; the hub never does.
if [[ "${1:-}" == "orphans" || "${1:-}" == "--orphans" ]]; then
  [[ -d "$VALIDATIONS_DIR" ]] || exit 0
  for d in "$VALIDATIONS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    verdict="$(valjob::orphan_verdict "${d%/}")"
    case "$verdict" in
      ORPHAN*)
        job="$(basename "${d%/}")"
        while read -r id prov; do
          [[ -n "$id" ]] || continue
          printf '%s\t%s\t%s\t%s\n' "$job" "$verdict" "$id" "$prov"
        done < <(valjob::orphan_deploys "${d%/}")
        ;;
    esac
  done
  exit 0
fi

# ── launch mode ──────────────────────────────────────────────────────────────
MAX_DEPLOYS=0; FLOW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-deploys) MAX_DEPLOYS="${2:?--max-deploys needs N}"; shift 2 ;;
    -h|--help) grep '^#' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) govern::die "unknown flag: $1" ;;
    *) [[ -z "$FLOW" ]] && { FLOW="$1"; shift; } || govern::die "unexpected extra arg: $1" ;;
  esac
done
[[ -n "$FLOW" ]] || govern::die "usage: run-validation.sh <flow-id|script.sh> [--max-deploys N]"

# Resolve the validation script: an existing file is the script; otherwise treat FLOW as a registry
# flow-id and read its `Run:` field.
if [[ -f "$FLOW" ]]; then
  SCRIPT_PATH="$(cd "$(dirname "$FLOW")" && pwd)/$(basename "$FLOW")"
  flowslug="$(basename "$FLOW")"; flowslug="${flowslug%.sh}"
else
  run_rel=""
  command -v govern::flow_field >/dev/null 2>&1 && run_rel="$(govern::flow_field "$FLOW" Run 2>/dev/null || true)"
  [[ -n "$run_rel" ]] || govern::die "'$FLOW' is neither a script file nor a flow with a Run: field"
  case "$run_rel" in /*) SCRIPT_PATH="$run_rel" ;; *) SCRIPT_PATH="$WS_ROOT/$run_rel" ;; esac
  [[ -f "$SCRIPT_PATH" ]] || govern::die "flow '$FLOW' Run script not found: $SCRIPT_PATH"
  flowslug="$FLOW"
fi
flowslug="$(printf '%s' "$flowslug" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-')"

job_id="${GOVERN_VAL_JOB_ID:-val-${flowslug}-$(date +%Y%m%d-%H%M%S)}"
VAL_JOB_DIR="$VALIDATIONS_DIR/$job_id"
mkdir -p "$VAL_JOB_DIR"

# Pre-flight gate (§6, thin): a per-flow refuse-to-start check the flow owns (capacity/quota/health).
# The runner owns ONLY the refuse-to-start decision — a non-zero pre-flight means nothing is spent.
preflight="${GOVERN_VAL_PREFLIGHT:-}"
if [[ -z "$preflight" && ! -f "$FLOW" ]] && command -v govern::flow_field >/dev/null 2>&1; then
  preflight="$(govern::flow_field "$FLOW" Preflight 2>/dev/null || true)"
fi
if [[ -n "$preflight" ]]; then
  if ! ( cd "$WS_ROOT" && VAL_JOB_ID="$job_id" VAL_JOB_DIR="$VAL_JOB_DIR" eval "$preflight" ) >>"$VAL_JOB_DIR/preflight.log" 2>&1; then
    govern::die "pre-flight gate failed for '$FLOW' — refusing to start (see $VAL_JOB_DIR/preflight.log)"
  fi
fi

valjob::prune "$VALIDATIONS_DIR" || true   # retention (best-effort; never blocks a launch).

# Export the job env for the detached supervisor + the flow, then detach the supervisor. VAL_MAX_DEPLOYS
# and the pre-flight are the runner's gate; provider-retry/pre-flight *logic* stays in the flow script.
export VAL_JOB_ID="$job_id" VAL_JOB_DIR VAL_MAX_DEPLOYS="$MAX_DEPLOYS"
export VALJOB_LIB="$DIR/lib/valjob.sh"
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$SELF" --_supervise "$job_id" "$SCRIPT_PATH" </dev/null >>"$VAL_JOB_DIR/runner.log" 2>&1 &
else
  nohup bash "$SELF" --_supervise "$job_id" "$SCRIPT_PATH" </dev/null >>"$VAL_JOB_DIR/runner.log" 2>&1 &
  disown 2>/dev/null || true
fi

govern::log "launched durable validation job $job_id → $VAL_JOB_DIR"
printf '%s\n' "$job_id"    # job-id to stdout, non-blocking; the caller may exit immediately.
