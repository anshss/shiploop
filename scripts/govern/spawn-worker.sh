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

# 1. Extract the ticket block via the shared parser (govern::ticket_block): boundary is the
#    next `^##[[:space:]]+#<digits>` heading, NOT the first `^---$` — a bare `---` inside a
#    markdown body no longer truncates the worker prompt.
block="$(govern::ticket_block "$N" "$TICKETS_FILE")"
[[ -n "$block" ]] || govern::die "ticket #$N not found in $TICKETS_FILE"

# LATCH the per-ticket Model: field (if any) AND the first-attempt-vs-retry signal NOW — before
# worktree creation, so `[[ -d "$WORKTREE_BASE/$slug" ]]` still reflects the STATE BEFORE the
# current spawn, not a worktree we just created ourselves. The check is applied lower down where
# --model is assembled; see the block near `GOVERN_WORKER_MODEL`. `GOVERN_SPAWN_FORCE_RETRY=1` is
# a test seam. Extraction is ANCHORED to the ticket's LEADING FIELD BLOCK — the contiguous field
# lines between the `## #N` heading and the first blank line — so a `Model:` mention later in
# prose or inside a code fence in the body can never be parsed as the field. The awk strips the
# heading, skips leading blank lines, then reads until the first blank line and stops. The sed
# pattern (case-insensitive; strips optional `**Model:**` markdown emphasis) then extracts the
# tier value; allowlist gate below applies unchanged.
TICKET_MODEL="$(printf '%s' "$block" \
  | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
  | sed -n 's/^[[:space:]]*\*\{0,2\}[Mm]odel:\*\{0,2\}[[:space:]]*\([A-Za-z0-9._-]\{1,32\}\).*$/\1/p' \
  | head -1)"
MODEL_IS_RETRY=0
# Preserved-worktree is the primary retry signal; a flat-log check was removed as inert (run-loop
# nukes the flat log at line ~20; run-scoped `worker.jsonl` is truncated at spawn anyway).
[[ -d "$WORKTREE_BASE/$slug" ]] && MODEL_IS_RETRY=1
[[ "${GOVERN_SPAWN_FORCE_RETRY:-0}" == "1" ]] && MODEL_IS_RETRY=1
export TICKET_MODEL MODEL_IS_RETRY

# LATCH the per-ticket `Flow:` field (flow-registry validation ids) the SAME anchored way as Model —
# the contiguous leading field block only, so a `Flow:` mention in prose/code can't be mis-parsed.
# Space/comma list; whitespace normalized to single spaces. Injected as full flow blocks below.
TICKET_FLOW="$(printf '%s' "$block" \
  | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
  | sed -n -E 's/^[[:space:]]*\*{0,2}[Ff]low:\*{0,2}[[:space:]]*//p' | head -1 \
  | tr ',' ' ' | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"
export TICKET_FLOW

# GOVERN_SPAWN_DRY_RUN=1: resolve the model tier as the real spawn would, print the assembled
# `claude -p` invocation params as ONE JSON line to stdout, and exit 0 WITHOUT creating a
# worktree and WITHOUT launching a worker. Purely an observation seam for the model-routing
# evidence harness and any operator who wants to probe what would be run — no auth, no cost,
# no side effects. Not part of the normal run path.
if [[ "${GOVERN_SPAWN_DRY_RUN:-0}" == "1" ]]; then
  dr_model="${GOVERN_WORKER_MODEL:-opus}"
  dr_source="GOVERN_WORKER_MODEL"
  if [[ -n "$TICKET_MODEL" && "$MODEL_IS_RETRY" -eq 0 ]]; then
    case "$TICKET_MODEL" in
      haiku|sonnet|opus) dr_model="$TICKET_MODEL"; dr_source="ticket-Model-field" ;;
      *) dr_source="GOVERN_WORKER_MODEL (unknown ticket Model: '$TICKET_MODEL' ignored)" ;;
    esac
  elif [[ -n "$TICKET_MODEL" && "$MODEL_IS_RETRY" -eq 1 ]]; then
    dr_source="GOVERN_WORKER_MODEL (retry — ticket Model: '$TICKET_MODEL' skipped)"
  fi
  dr_mode="${GOVERN_MODE:-live}"
  dr_perm="${GOVERN_PERMISSION_MODE:-bypassPermissions}"
  [[ "$dr_mode" == "dry" ]] && dr_perm="plan"
  dr_strict_mcp="--strict-mcp-config"; [[ "${GOVERN_WORKER_MCP:-0}" == "1" ]] && dr_strict_mcp=""
  jq -nc \
    --arg bin "${GOVERN_CLAUDE_BIN:-claude}" \
    --arg model "$dr_model" \
    --arg source "$dr_source" \
    --arg perm "$dr_perm" \
    --arg mcp "$dr_strict_mcp" \
    --arg wtpath "$WORKTREE_BASE/$slug" \
    --arg tm "$TICKET_MODEL" \
    --argjson retry "$MODEL_IS_RETRY" \
    --arg n "$N" \
    '{ticket:($n|tonumber), claude_bin:$bin, model:$model, model_source:$source, ticket_model:$tm, is_retry:$retry, permission_mode:$perm, strict_mcp:$mcp, worktree:$wtpath}'
  exit 0
fi

# 2. Assemble the prompt: template (with {{TICKET_BLOCK}}/{{REPORT_PATH}} filled) + doctrine.
template="$(cat "$WORKER_PROMPT_FILE")"
prompt="${template//\{\{TICKET_BLOCK\}\}/$block}"
prompt="${prompt//\{\{REPORT_PATH\}\}/$report_path}"
prompt="$prompt

## Operator doctrine
$(cat "$PREFERENCES_FILE")"

# Trust-ladder + viral-footer PR instructions. Both are appended to the worker prompt so the worker
# opens the PR the way this workspace's knobs dictate:
#   - GOVERN_AUTONOMY=observe → open the PR as a DRAFT (visible but inert; the governor never merges).
#   - WSP_PR_FOOTER != off (default on) → end the PR body with the one-line shiploop attribution,
#     REPLACING any "Generated with" line so there is exactly one footer.
# Both resolve through the workspace.sh knobs (defaults: autonomy pr-only for new scaffolds / auto for
# pre-ladder installs; footer on) via the common.sh helpers, so behavior is uniform across every caller.
if govern::pr_draft; then
  prompt="$prompt

## ⚠ AUTONOMY=observe — open your PR as a DRAFT
This workspace runs the governor in **observe** mode: work is reviewed before anything lands. When you
create the PR, make it a **draft** — \`gh pr create --draft ...\` (all other steps unchanged: branch
\`ticket-<N>\`, real local validation first, do NOT merge). The governor will NOT merge it; a human
reviews the draft and merges when ready."
fi
if [[ "${WSP_PR_FOOTER:-on}" != "off" ]]; then
  prompt="$prompt

## PR body footer — REQUIRED
End every PR body you open with EXACTLY this attribution line as the FINAL line (replace any
\"🤖 Generated with …\" line — keep only this ONE footer, plus the Co-Authored-By trailer the
commit hook adds):

PR shipped by [shiploop](https://github.com/anshss/shiploop)"
fi

# Public-repo PR hygiene: on a PUBLIC target repo the branch MUST NOT carry the internal ticket id
# (an outsider seeing `ticket-<N>` infers a private tracker). Resolve which of this workspace's repos
# are public (GOVERN_PUBLIC_REPOS knob wins; else `gh repo view` auto-detect, cached per run) and, if
# any are, OVERRIDE the worker-prompt's "branch MUST be ticket-<N>" instruction for those repos with
# the neutral `sl-<hex>` scheme (govern::neutral_branch) plus a no-ticket-ids-in-PR/commits rule. The
# override appends LAST so it supersedes the static prompt. Private-only workspaces inject nothing —
# zero behavior change and zero extra context in the common case.
_pub_repos=""
for _r in ${GOVERN_MERGE_REPOS:-} ${GOVERN_FRONTEND_REPOS:-}; do
  govern::repo_is_public "$_r" 2>/dev/null && _pub_repos="${_pub_repos:+$_pub_repos }$_r"
done
if [[ -n "$_pub_repos" ]]; then
  _neutral_branch="$(govern::neutral_branch "$N" 2>/dev/null || printf 'ticket-%s' "$N")"
  prompt="$prompt

## ⚠ PUBLIC-REPO PR HYGIENE — overrides the \"branch MUST be ticket-<N>\" rule for these repos
These repos in this workspace are **PUBLIC**: ${_pub_repos}. On a public repo an internal ticket id
must NOT be visible to outsiders. So **in any repo listed above ONLY**:
1. Name your branch **\`${_neutral_branch}\`** — NOT \`ticket-$N\`. (It is a deterministic opaque token
   for this ticket; the governor still finds + merges the PR by it. Create it with
   \`git switch -c ${_neutral_branch}\`.)
2. Put **NO** internal ticket id anywhere an outsider can read it: not in the **PR title**, not in the
   **PR body**, and not in any **commit subject** (no \`#$N\`, no \`ticket $N\`, no \`ticket-$N\`).
   Describe the change on its own merits.
In every OTHER (private) repo you touch, keep the classic \`ticket-$N\` branch and normal messages.
When a resource name is required, use \`${_neutral_branch}-<label>\` in public repos (\`ticket-$N-<label>\`
elsewhere) so the orphan sweep still reaps it."
fi

# Flow-registry injection: a ticket carrying a `Flow:` field validates one or more registered flows.
# Inject the FULL flow block(s) so the worker knows each flow's Kind/Gate/Surface/Paths, and remind it
# to fill the report's flow fields. (The one-line "your change stales flows X,Y" summary for
# NON-validation tickets is Phase 3 — not emitted here.) Guarded on the parser existing (flows.sh).
if [[ -n "${TICKET_FLOW:-}" ]] && command -v govern::flow_block >/dev/null 2>&1; then
  flow_blocks=""
  for _fid in $TICKET_FLOW; do
    _fb="$(govern::flow_block "$_fid" 2>/dev/null || true)"
    [[ -n "$_fb" ]] && flow_blocks="$flow_blocks
$_fb
"
  done
  if [[ -n "$flow_blocks" ]]; then
    prompt="$prompt

## Flow(s) this ticket validates (from validation/flows.md)
This is a flow-registry validation. Drive the REAL path for each flow below (rule #12), then in your
report's \`validation\` object record: \`validatedShas\` (map each mapped sub-repo folder → its
\`git rev-parse HEAD\` at validation time), \`environment\` (\"local\"|\"prod\"), \`gatePassed\`
(effectiveness flows), \`measured\`, and \`flowIds\` (echo: $TICKET_FLOW). The governor stamps the
registry from these on resolve/gate-park.
$flow_blocks"
  fi
elif command -v govern::flows_matching_paths >/dev/null 2>&1; then
  # NON-validation ticket (no Flow: field): a context-flat ONE-LINE heads-up naming the validated flows
  # this ticket's change is likely to STALE — never full blocks (the context-flat posture; full blocks
  # are only for a ticket that actually validates a flow, above). Candidate paths are the `<sub-repo>/…`
  # tokens in the ticket block (its "Where:" area); flows whose mapped globs overlap them are surfaced
  # most-specific first, capped. Silent when nothing overlaps (the common case) — zero context cost then.
  _flow_meta="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"
  if [[ -f "$_flow_meta/validation/flows.md" && ${#REPOS[@]} -gt 0 ]]; then
    _repo_alt="$(printf '%s|' "${REPOS[@]}")"; _repo_alt="${_repo_alt%|}"
    # Extract distinct `<repo>/<path>` tokens the ticket names (dedup, order-stable).
    _cand_paths="$(printf '%s' "$block" \
      | grep -oE "(^|[^A-Za-z0-9_/.-])(${_repo_alt})/[A-Za-z0-9._*/-]+" 2>/dev/null \
      | sed -E 's/^[^A-Za-z0-9]//' | awk '!seen[$0]++' || true)"
    if [[ -n "$_cand_paths" ]]; then
      # shellcheck disable=SC2086
      _stale_flows="$(govern::flows_matching_paths "$_flow_meta" "${GOVERN_FLOWS_MATCH_MAX:-5}" $_cand_paths 2>/dev/null | tr '\n' ' ' | sed -E 's/ +$//' || true)"
      if [[ -n "$_stale_flows" ]]; then
        prompt="$prompt

## Heads-up — flows your change may STALE (validation/flows.md)
This is NOT a validation ticket, but your change touches paths mapped by these currently-validated
flow(s): ${_stale_flows}. That's expected — the governor's staleness sweep will mark them STALE
automatically once your PR lands; you do NOT need to re-validate them here. Noted only so a later
reader knows these proven paths were disturbed by this ticket."
      fi
    fi
  fi
fi

# #191: conflict-resolution re-dispatch. When the governor's merge of an EXISTING ticket-N PR hit a
# real content conflict (CI was green; the merge + rebase retry both failed), the merge path re-spawns
# this worker with GOVERN_RESOLVE_CONFLICT=<repo>#<pr>. The PR already exists — do NOT redo the ticket
# or open a new PR; just land the existing one on top of the moved origin/main. Append an OVERRIDE
# block (last instruction wins) so the worker rebases-by-merge + pushes instead.
if [[ -n "${GOVERN_RESOLVE_CONFLICT:-}" ]]; then
  prompt="$prompt

## ⚠ OVERRIDE — CONFLICT-RESOLUTION MODE (this supersedes \"How to work\" above)
The PR for this ticket ($GOVERN_RESOLVE_CONFLICT) ALREADY EXISTS on branch \`ticket-$N\` and its CI is
green, but the governor could not merge it: origin/main moved under it (an interdependent sibling PR
just landed touching the same files) and it now CONFLICTS. Your ONLY job is to land that existing PR —
NOT to re-implement the ticket and NOT to open a new PR.

Do exactly this in the sub-repo whose PR is $GOVERN_RESOLVE_CONFLICT:
1. \`cd\` into that sub-repo, \`git fetch origin\`, and check out the existing \`ticket-$N\` branch.
2. \`git merge origin/main\` — a MERGE commit. Do NOT rebase and do NOT force-push (force-push is a
   doctrine hard-stop); a plain merge + normal \`git push\` updates the PR fast-forward.
3. Resolve EVERY conflict so BOTH the ticket's change AND the changes already on origin/main are
   preserved — re-apply the ticket's intent on top of the new main, never clobber the landed work.
4. Build the sub-repo and run its tests to confirm the resolution compiles + passes.
5. \`git commit\` the merge and \`git push\` (no force, no new PR — the open PR updates in place).
6. Do NOT edit \`tickets.md\`. Report \`status:\"resolved\"\` with the SAME existing PR
   ({repo,number,url}); the governor re-checks CI and merges it.

If the conflict genuinely cannot be resolved without a judgment call the doctrine does not cover,
PARK (status \"parked\") and explain precisely in \`escalation\`. Otherwise resolve + push + report resolved."
fi

# 3. Create the worktree.
wt_cmd="${GOVERN_WORKTREE_CMD:-}"
wtpath="$WORKTREE_BASE/$slug"
if [[ -n "$wt_cmd" ]]; then
  wtpath="$("$wt_cmd" "$slug")"
elif [[ -d "$wtpath" ]]; then
  # Resume: a preserved worktree from a prior failed/parked attempt already exists.
  # worktree:new hard-exits on an existing path → under set -e that aborts spawn-worker and
  # fast-fails the resume before the worker even runs. Reuse it, and re-run the project
  # bootstrap hook (if any) to restore deps a slim/cleanup may have stripped (#53).
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
  # reads as a phantom worker failure (#48). Direct bash + assume-yes sidestep both.
  #
  # #76: capture worktree:new's output and DON'T let a non-zero exit `set -e`-abort spawn-worker.
  # The driver runs us as `spawn-worker.sh N 2>/dev/null || true`, so a bare abort discards our
  # stderr and surfaces only an opaque "#N FAILED" with no cause. new.sh now self-heals a stale
  # ticket-<N> registry entry (registry path-gone self-heal), so the common re-open collision just
  # succeeds; if it STILL fails (a genuine live collision), emit a `failed` report carrying the
  # REAL reason so the driver records something actionable instead of a bare FAILED.
  set +e
  wt_out="$( cd "$WS_ROOT" && WORKTREE_ASSUME_YES=1 bash "$WS_ROOT/scripts/worktree/new.sh" "$slug" 2>&1 )"
  wt_rc=$?
  set -e
  if [[ "$wt_rc" -ne 0 || ! -d "$wtpath" ]]; then
    reason="worktree:new for $slug failed (rc=$wt_rc): $(printf '%s' "$wt_out" | grep -iE 'already in registry|already exists|already checked out|already used|fatal|error' | tail -2 | tr '\n' ' ' | sed 's/  */ /g')"
    [[ "$reason" == *': ' || "$reason" == *':' ]] && reason="worktree:new for $slug failed (rc=$wt_rc) — inspect $jsonl; tail: $(printf '%s' "$wt_out" | tail -2 | tr '\n' ' ')"
    govern::log "worker for #$N → failed at worktree create: $reason"
    rm_hint="$ROOT_PM run worktree:rm -- $slug --force"
    jq -nc --arg r "$reason" --arg rm "$rm_hint" \
      '{status:"failed",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{reason:$r,question:("clear the ticket-<N> worktree/branch/registry collision ("+$rm+") then re-run"),options:[]}}'
    exit 0
  fi
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

# Per-ticket brain-decided model routing. Honor a `Model:` line inside the ticket block ONLY when
# THIS is the ticket's FIRST attempt — any retry unconditionally escalates to GOVERN_WORKER_MODEL,
# because a cheap-tier bet that didn't land the first time shouldn't be re-bet on retry. The brain
# that filed/triaged the ticket recorded the model; the harness carries no severity/task-type
# heuristic of its own. Unknown / absent value → keep GOVERN_WORKER_MODEL (fail safe, current
# behavior preserved for the entire existing backlog). Extend the allowlist below if a new tier
# ships. `MODEL_IS_RETRY` (below) latched BEFORE worktree/new.sh created a fresh worktree, so this
# always reflects the STATE-BEFORE-spawn.
if [[ -n "${TICKET_MODEL:-}" && "$MODEL_IS_RETRY" -eq 0 ]]; then
  case "$TICKET_MODEL" in
    haiku|sonnet|opus)
      govern::log "worker #$N model=$TICKET_MODEL per ticket Model: field (first attempt; brain-decided)"
      model="$TICKET_MODEL"
      ;;
    *)
      govern::log "worker #$N: ignoring unknown Model: '$TICKET_MODEL' from ticket — using GOVERN_WORKER_MODEL=$model (fail-safe)"
      ;;
  esac
elif [[ -n "${TICKET_MODEL:-}" && "$MODEL_IS_RETRY" -eq 1 ]]; then
  govern::log "worker #$N: retry detected (preserved worktree) — escalating to GOVERN_WORKER_MODEL=$model (ignoring ticket Model: $TICKET_MODEL)"
fi

# Lean worker: a code-fix worker uses git/gh/<pm> via Bash, not MCP. Loading the operator's
# inherited MCP fleet (often 8+ stdio servers / dozens of tools) just slows worker startup and
# risks a teardown stall on exit. --strict-mcp-config = load ONLY --mcp-config files (we pass
# none) → zero MCP servers. Set GOVERN_WORKER_MCP=1 to keep the inherited servers.
strict_mcp="--strict-mcp-config"; [[ "${GOVERN_WORKER_MCP:-0}" == "1" ]] && strict_mcp=""

to="${GOVERN_WORKER_TIMEOUT:-3600}"   # per-worker wall-clock cap (s); 0 = unbounded. Default 1h.
worker_killed=0
# #239: stamp the worker's start time. After the worker exits — for ANY reason, including a
# GOVERN_WORKER_TIMEOUT kill — we sweep every non-terminal external resource the worker may have
# created since this epoch and close it (see run_deploy_sweep below), so a killed/timed-out worker
# can never leave a billing orphan. 60s of slack absorbs minor clock skew without ever reaching back
# into a PRIOR worker's window.
worker_start_epoch=$(( $(date +%s) - 60 ))

# #239: post-worker orphan sweep. Runs after EVERY worker (resolved / failed / parked / timed-out /
# KILLED) — a killed/timed-out worker never runs its own cleanup, so without this any real resources
# it created bill until a human finds them. This project ships NO deploy/cloud infra by default, so
# the sweep is a no-op unless the operator wires GOVERN_DEPLOY_SWEEP_CMD — a command called with the
# worker's start epoch and the ticket number ("$cmd" <since-epoch> <N>); it should close every
# non-terminal resource created in this worker's window. Best-effort: a sweep failure never changes
# the worker's reported outcome.
run_deploy_sweep() {
  local since="$1"
  local sweep="${GOVERN_DEPLOY_SWEEP_CMD:-}"
  # No seam configured → nothing to sweep (this template has no deploy infra). Default = disabled.
  [[ -n "$sweep" ]] || return 0
  # Skip only in DRY mode (no real worker, no resources). An explicitly-wired seam DOES fire under a
  # test worktree-cmd override — that is exactly how the #239 trap wiring is regression-tested
  # (test-spawn-worker-sweep.sh). A live governor run never sets GOVERN_WORKTREE_CMD, so real
  # behavior is unchanged; do NOT re-add a `-z "${GOVERN_WORKTREE_CMD:-}"` clause here or the sweep
  # seam goes dead in tests and a removed trap can silently regress the #3001 kill-path leak.
  [[ "${GOVERN_MODE:-live}" == "live" ]] || return 0
  # A time-window sweep closes EVERY resource born in this worker's window, so it is only safe in
  # SINGLE-RUN mode (one worker at a time). Under GOVERN_ALLOW_CONCURRENT=1 two parallel workers'
  # windows overlap and this could close a sibling's in-flight resource — relying instead on the
  # worker's own tagged cleanup. Skip the broad time sweep in that mode.
  if [[ "${GOVERN_ALLOW_CONCURRENT:-0}" == "1" ]]; then
    govern::log "post-worker orphan sweep SKIPPED for #$N — GOVERN_ALLOW_CONCURRENT=1 (time-window sweep is single-run-only) [#239]"
    return 0
  fi
  govern::log "post-worker orphan sweep for #$N → GOVERN_DEPLOY_SWEEP_CMD closing resources created since $(date -r "$since" '+%H:%M:%S' 2>/dev/null || echo "$since") [#239]"
  "$sweep" "$since" "$N" >>"$logdir/deploy-sweep.log" 2>&1 || true
  return 0
}

# TokenJam cross-session run tagging: stamp this worker's OTEL_RESOURCE_ATTRIBUTES so TokenJam groups
# every session of one run under a single tokenjam.run_id "Run", labelled with the ticket slug.
# govern::otel_attrs appends to any inherited attrs (never clobbers) and is passed ONLY to the spawned
# claude via `env VAR=...` below — the governor's own shell OTEL_RESOURCE_ATTRIBUTES is unchanged.
otel_attrs="$(govern::otel_attrs "$slug")"

govern::log "spawning worker for #$N (mode=$mode, model=$model, timeout=${to}s) in $wtpath"
govern::log "worker #$N OTel resource attrs: ${otel_attrs}"

# #242: tear the worker subtree down on EVERY exit path so a stopped/killed governor never leaves an
# orphaned `claude -p` (+ any grandchildren it spawned) reparented to init and billing a box. $cpid is
# launched under `set -m` below → it LEADS its own process group, so govern::kill_tree reaps the whole
# tree (group kill + pid-walk) in one sweep. The EXIT trap covers a clean return (cpid already gone →
# fast no-op) and an abrupt one; the INT/TERM trap covers run-loop forwarding a stop signal to us
# (run-loop SIGTERMs this process on its own stop), so the kill cascades driver → spawn-worker → tree.
cpid=""; wd=""
spawn_worker_cleanup() {
  [[ -n "${wd:-}" ]] && { kill "$wd" 2>/dev/null || true; govern::_kill_tree_walk "$wd" TERM; }
  [[ -n "${cpid:-}" ]] && govern::kill_tree "$cpid" "${GOVERN_KILL_GRACE_S:-10}"
  return 0   # EXIT-trap body must end 0 — its last status would otherwise become the script's exit code
}
trap 'spawn_worker_cleanup' EXIT
trap 'govern::log "spawn-worker #'"$N"' received stop signal — tearing down worker tree [#242]"; spawn_worker_cleanup; exit 143' INT TERM

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
# #242 set -m: run `claude` as its OWN process-group leader (pgid==cpid) so the timeout watchdog /
# stop traps can `kill -- -cpid` the WHOLE subtree (claude + every grandchild) at once, including
# descendants that reparent. macOS has no `setsid`; `set -m` is the portable equivalent. set +m
# right after so the watchdog and the rest of the script stay in spawn-worker's own group.
set -m
( cd "$wtpath" && exec env \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
    GOVERN_REPORT_PATH="$report_path" OTEL_RESOURCE_ATTRIBUTES="$otel_attrs" "$claude_bin" -p "$prompt" \
    --output-format stream-json --verbose \
    --setting-sources "${GOVERN_SETTING_SOURCES:-user}" \
    $strict_mcp \
    --permission-mode "$permflag" --model "$model" ) >"$jsonl" 2>&1 &
cpid=$!
set +m
if [[ "$to" -gt 0 ]]; then
  # 1>/dev/null: the watchdog (and its sleep child) must NOT inherit this script's stdout — that
  # pipe feeds the caller's $(...) capture, and an orphaned sleep holding it would hang the caller.
  # #242: tear down the whole worker process GROUP (not just direct children) so a grandchild can't
  # outlive the timeout kill.
  ( sleep "$to"
    if kill -0 "$cpid" 2>/dev/null; then
      govern::log "worker #$N exceeded ${to}s — terminating worker tree; worktree PRESERVED at $wtpath (re-run resumes)"
      govern::kill_tree "$cpid" 10
    fi ) 1>/dev/null & wd=$!
fi
wait "$cpid"; rc=$?
if [[ -n "$wd" ]]; then kill "$wd" 2>/dev/null; govern::_kill_tree_walk "$wd" TERM; fi
wd=""; cpid=""   # worker + watchdog reaped — disarm the cleanup traps' fast path
set -e
if [[ "$rc" -gt 128 ]]; then worker_killed=1; fi

# #239: sweep this worker's orphan resources NOW — before report resolution and on EVERY exit path
# (resolved / failed / parked / timed-out / killed). A worker hard-killed by GOVERN_WORKER_TIMEOUT
# after creating real external resources never ran its own cleanup, so they would bill until a human
# found them. No-op unless GOVERN_DEPLOY_SWEEP_CMD is wired (see run_deploy_sweep above).
run_deploy_sweep "$worker_start_epoch"

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

# 6. Validate; synthesize a report ONLY if no parseable status-bearing object exists anywhere.
#    Three distinct no-report outcomes — never conflated, because each needs a different response:
#      infra   — worker died on an auth/transport outage (#90): NOT the ticket's fault → run halts.
#      timeout — worker HARD-KILLED by GOVERN_WORKER_TIMEOUT before it could write its verdict (#241):
#                NOT a genuine FAIL. The killed worker may have done real, green work and just never
#                reached the report write — recording that as `failed` masks a working result as broken
#                (a false launch-blocking signal) and wastes a re-run. So emit a DISTINCT
#                status:"timeout" (incomplete, worktree preserved) → run-loop re-runs it.
#      failed  — worker finished/errored on its own (no kill) yet produced no parseable report: a
#                genuine ticket failure.
if [[ -z "$report" ]] || ! printf '%s' "$report" | jq empty >/dev/null 2>&1; then
  # #90: a real timeout (worker_killed) is a kill, not infra, so skip the infra signature check in
  # that case (a genuine wall-clock timeout is the dominant cause and the timeout status is
  # recoverable either way).
  infra_sig=""; intr_sig=""
  if [[ "$worker_killed" -eq 0 ]]; then
    infra_sig="$(govern::infra_error_signature "$jsonl" || true)"
    # #34: only when it's NOT a persistent infra/auth outage, check for a TRANSIENT mid-stream
    # connection drop (laptop sleep / network suspend) — that gets its own recoverable status.
    [[ -z "$infra_sig" ]] && intr_sig="$(govern::interrupted_error_signature "$jsonl" || true)"
  fi
  if [[ -n "$infra_sig" ]]; then
    govern::log "worker for #$N → INFRA/auth outage (not a ticket fault): $infra_sig"
    report="$(jq -nc --arg e "$infra_sig" --arg wt "$wtpath" \
      '{status:"infra",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},infra:{error:$e},escalation:null}')"
  elif [[ -n "$intr_sig" ]]; then
    # #34: a TRANSIENT mid-response connection drop (e.g. the laptop slept mid-run and the OS
    # suspended the process + dropped the network) — the worker exited on its OWN (worker_killed=0),
    # NOT the timeout watchdog. NOT a ticket fault and NOT a persistent infra outage: the worktree is
    # preserved + resumable, so emit a DISTINCT status:"interrupted" → run-loop auto-retries the SAME
    # ticket ONCE instead of burning it as `failed` and mis-attributing a sleep artifact to ticket
    # difficulty. Order matters: infra (halt-class) is checked FIRST, then interrupted, then timeout.
    govern::log "worker for #$N → INTERRUPTED — transient connection drop mid-response (e.g. laptop sleep), worktree preserved at $wtpath (auto-retry resumes): $intr_sig"
    report="$(jq -nc --arg e "$intr_sig" --arg wt "$wtpath" \
      '{status:"interrupted",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},interrupted:{error:$e},escalation:null}')"
  elif [[ "$worker_killed" -eq 1 ]]; then
    # #241: kill-before-verdict — NOT failed. The worktree is preserved; a re-run resumes it.
    reason="worker exceeded ${to}s timeout and was hard-killed before it could write its verdict — INCOMPLETE, not a genuine failure; any real work is PRESERVED at $wtpath (a re-run resumes). Treating this as failed would mask a possibly-working result (#241)."
    govern::log "worker for #$N → timeout (killed before verdict; NOT recorded failed) [#241]: $reason"
    report="$(jq -nc --arg r "$reason" --arg wt "$wtpath" \
      '{status:"timeout",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{reason:$r,question:("re-run the ticket to resume from "+$wt+" (or raise GOVERN_WORKER_TIMEOUT if it legitimately needs longer)"),options:[]}}')"
  else
    reason="no valid report from worker (inspect $jsonl)"
    govern::log "worker for #$N → failed: $reason"
    report="$(jq -nc --arg r "$reason" --arg wt "$wtpath" \
      '{status:"failed",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{reason:$r,question:("resume from "+$wt+" or re-run the ticket"),options:[]}}')"
  fi
fi
printf '%s\n' "$report"
