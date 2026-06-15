#!/usr/bin/env bash
# Spawn one headless worker for ticket N. Prints the worker's JSON report to stdout.
# Overridable for tests: GOVERN_WORKTREE_CMD (takes slug, prints worktree path),
# GOVERN_CLAUDE_BIN (the claude binary), GOVERN_MODE (live|dry → permission mode).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

N="${1:?ticket number required}"
slug="ticket-$N"
# #75: run-scoped log dir (logs/govern/run-<ts>/ticket-N/ when GOVERN_RUN_DIR is set by run-loop),
# so a re-run never reads a PRIOR run's worker.jsonl. Standalone invocation falls back to the flat
# logs/govern/ticket-N/.
logdir="$(govern::worker_logdir "$N")"; mkdir -p "$logdir"
jsonl="$logdir/worker.jsonl"
report_path="$logdir/report.json"; rm -f "$report_path"
# #75: when run-scoped, truncate any LEGACY flat log so no consumer can tail a prior run's stale
# data from logs/govern/ticket-N/ (we never read it again, but other tails might).
if [[ -n "${GOVERN_RUN_DIR:-}" ]]; then rm -f "$LOG_ROOT/$slug/worker.jsonl" "$LOG_ROOT/$slug/report.json"; fi

# 1. Extract the ticket block: from "## #N" up to the next "---".
block="$(awk -v n="$N" '
  $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" {grab=1}
  grab && /^---[[:space:]]*$/ {exit}
  grab {print}
' "$TICKETS_FILE")"
[[ -n "$block" ]] || govern::die "ticket #$N not found in $TICKETS_FILE"

# 2. Assemble the prompt: template (with {{TICKET_BLOCK}}/{{REPORT_PATH}} filled) + doctrine.
template="$(cat "$WORKER_PROMPT_FILE")"
prompt="${template//\{\{TICKET_BLOCK\}\}/$block}"
prompt="${prompt//\{\{REPORT_PATH\}\}/$report_path}"
prompt="$prompt

## Operator doctrine
$(cat "$PREFERENCES_FILE")"

# 3. Create the worktree.
wt_cmd="${GOVERN_WORKTREE_CMD:-}"
wtpath="$WORKTREE_BASE/$slug"
if [[ -n "$wt_cmd" ]]; then
  wtpath="$("$wt_cmd" "$slug")"
elif [[ -d "$wtpath" ]]; then
  # Resume: a preserved worktree from a prior failed/parked attempt already exists.
  # worktree:new hard-exits on an existing path → under set -e that aborts spawn-worker and
  # fast-fails the resume before the worker even runs. Reuse it, and re-run the project
  # bootstrap hook (if any) to restore deps a slim/cleanup may have stripped. (aquanode #53)
  govern::log "reusing preserved worktree for #$N at $wtpath (resume)"
  if [[ -x "$WS_ROOT/scripts/lib/worktree-bootstrap.sh" ]]; then
    wslot="$(awk -F= '/WORKTREE_SLOT/{gsub(/ /,"",$2);print $2}' "$wtpath/worktree.env" 2>/dev/null)"
    bash "$WS_ROOT/scripts/lib/worktree-bootstrap.sh" "$slug" "${wslot:-0}" "$wtpath" || true
  fi
else
  # Call the worktree script DIRECTLY (not via `$ROOT_PM run`): it's our own PM-agnostic bash
  # (pure git), and routing through `pnpm run` adds the package-manager's pre-run gate — pnpm
  # v11 aborts in a non-TTY shell (ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY) before the script
  # runs, silently killing every worker at the worktree step. WORKTREE_ASSUME_YES=1: a headless
  # worker has no TTY to answer new.sh's <5GB disk prompt; without it the guard EOF-aborts and
  # reads as a phantom worker failure (aquanode #48). Direct bash + assume-yes sidestep both.
  ( cd "$WS_ROOT" && WORKTREE_ASSUME_YES=1 bash "$WS_ROOT/scripts/worktree/new.sh" "$slug" >/dev/null )
fi
[[ -d "$wtpath" ]] || govern::die "worktree not created at $wtpath"

# 4. Run the worker. dry → plan mode (no writes); live → acceptEdits.
mode="${GOVERN_MODE:-live}"
# bypassPermissions: a headless worker can't answer prompts; acceptEdits only covers file edits,
# so git/gh/<pm>/build would stall. Operator-approved exception to the global "never
# dangerously-skip-permissions" rule — scoped to throwaway worktrees; the doctrine hard-stops
# (destructive git / prod-data) still gate the dangerous actions via self-park.
permflag="${GOVERN_PERMISSION_MODE:-bypassPermissions}"; [[ "$mode" == "dry" ]] && permflag="plan"
claude_bin="${GOVERN_CLAUDE_BIN:-claude}"
model="${GOVERN_WORKER_MODEL:-opus}"

# Lean worker: a code-fix worker uses git/gh/<pm> via Bash, not MCP. Loading the operator's
# inherited MCP fleet (often 8+ stdio servers / dozens of tools) just slows worker startup and
# risks a teardown stall on exit. --strict-mcp-config = load ONLY --mcp-config files (we pass
# none) → zero MCP servers. Set GOVERN_WORKER_MCP=1 to keep the inherited servers.
strict_mcp="--strict-mcp-config"; [[ "${GOVERN_WORKER_MCP:-0}" == "1" ]] && strict_mcp=""

to="${GOVERN_WORKER_TIMEOUT:-3600}"   # per-worker wall-clock cap (s); 0 = unbounded. Default 1h.
worker_killed=0
govern::log "spawning worker for #$N (mode=$mode, model=$model, timeout=${to}s) in $wtpath"
set +e
# --setting-sources user: drop the PROJECT .claude/settings.json hooks so a worker does NOT
# inherit a ticket-sweep Stop hook (clobbers stdout), a SessionEnd cleanup (fleet-wide side
# effects), or a SessionStart flood. `exec` so $cpid IS the claude process → clean kill.
#
# env -u CLAUDE_CODE_*: SCRUB the parent-session runtime markers. If this run-loop was launched
# from inside an interactive Claude session (or anything that leaked Claude env), the child
# `claude -p` inherits CLAUDE_CODE_ENTRYPOINT et al. and then NEVER finalizes — it answers but
# emits no `result` event and hangs until the watchdog kills it at GOVERN_WORKER_TIMEOUT. From a
# bare terminal these are unset so it "just works", which makes the bug invisible until someone
# drives the governor from a Claude session. Scrubbing them makes the worker self-contained and
# terminate cleanly regardless of how the loop was launched. (CLAUDE_CODE_ENTRYPOINT is the
# proven culprit; the rest are scrubbed defensively — none are needed by a fresh worker.)
( cd "$wtpath" && exec env \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
    GOVERN_REPORT_PATH="$report_path" "$claude_bin" -p "$prompt" \
    --output-format stream-json --verbose \
    --setting-sources "${GOVERN_SETTING_SOURCES:-user}" \
    $strict_mcp \
    --permission-mode "$permflag" --model "$model" ) >"$jsonl" 2>&1 &
cpid=$!
wd=""
if [[ "$to" -gt 0 ]]; then
  # 1>/dev/null: the watchdog (and its sleep child) must NOT inherit this script's stdout — that
  # pipe feeds the caller's $(...) capture, and an orphaned sleep holding it would hang the caller.
  ( sleep "$to"
    if kill -0 "$cpid" 2>/dev/null; then
      govern::log "worker #$N exceeded ${to}s — terminating; worktree PRESERVED at $wtpath (re-run resumes)"
      pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null
      sleep 10; pkill -KILL -P "$cpid" 2>/dev/null; kill -KILL "$cpid" 2>/dev/null
    fi ) 1>/dev/null & wd=$!
fi
wait "$cpid"; rc=$?
if [[ -n "$wd" ]]; then pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; fi
set -e
if [[ "$rc" -gt 128 ]]; then worker_killed=1; fi

# 5. Resolve the report. The strict contract is "the final message is ONLY a JSON object", but a
#    worker that DID the work sometimes emits "JSON + trailing prose" (or writes prose into
#    report.json) — so rather than requiring the WHOLE text to parse, pull the last balanced
#    JSON object carrying a `status` field out of each candidate source (#66). Prefer the file
#    (live), then the last result event's .result (dry / no-file). govern::extract_report keeps
#    the clean-object happy path as a fast short-circuit.
report=""
if [[ -s "$report_path" ]]; then
  report="$(govern::extract_report < "$report_path" || true)"
fi
if [[ -z "$report" ]]; then
  result_msg="$(grep '"type":"result"' "$jsonl" 2>/dev/null | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"
  [[ -n "$result_msg" ]] && report="$(printf '%s' "$result_msg" | govern::extract_report || true)"
fi

# 6. Validate; synthesize a failed report ONLY if no parseable status-bearing object exists anywhere.
#    A timeout/kill is reported as failed-with-preserved-worktree (recoverable, not lost work).
if [[ -z "$report" ]] || ! printf '%s' "$report" | jq empty >/dev/null 2>&1; then
  # #90: BEFORE recording a generic ticket `failed`, check whether the worker actually died on an
  # INFRA/auth outage (expired token, API unreachable, network down) — a transport error that kills
  # the worker before it can emit any report. That is NOT the ticket's fault: emit a DISTINCT
  # status:"infra" carrying the signature so run-loop neither records the ticket `failed` (→ #60
  # false auto-escalation / govern-improve noise) nor blames it — it halts the run with a re-auth
  # signal instead. A real timeout (worker_killed) is a genuine failure, not infra, so skip the
  # infra check in that case.
  infra_sig=""
  [[ "$worker_killed" -eq 0 ]] && infra_sig="$(govern::infra_error_signature "$jsonl" || true)"
  if [[ -n "$infra_sig" ]]; then
    govern::log "worker for #$N → INFRA/auth outage (not a ticket fault): $infra_sig"
    report="$(jq -nc --arg e "$infra_sig" --arg wt "$wtpath" \
      '{status:"infra",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},infra:{error:$e},escalation:null}')"
  else
    reason="no valid report from worker (inspect $jsonl)"
    [[ "$worker_killed" -eq 1 ]] && reason="worker exceeded ${to}s timeout and was terminated; partial work PRESERVED at $wtpath"
    govern::log "worker for #$N → failed: $reason"
    report="$(jq -nc --arg r "$reason" --arg wt "$wtpath" \
      '{status:"failed",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{reason:$r,question:("resume from "+$wt+" or re-run the ticket"),options:[]}}')"
  fi
fi
printf '%s\n' "$report"
