#!/usr/bin/env bash
# Spawn one headless worker for ticket N. Prints the worker's JSON report to stdout.
# Overridable for tests: GOVERN_WORKTREE_CMD (takes slug, prints worktree path),
# GOVERN_CLAUDE_BIN (the claude binary), GOVERN_MODE (live|dry → permission mode).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

N="${1:?ticket number required}"
shift
# #23 locality batching: any EXTRA ticket numbers after $1 are co-batched into this ONE worker —
# they share $N's worktree, branch and PR, and their outcomes come back per-ticket in the report's
# `tickets` array. $N stays the PRIMARY: the worktree slug, the branch, the model/effort/flow latches
# and the run-scoped log dir are all keyed on it, so a plain single-ticket spawn is byte-identical to
# before. The run-loop only ever passes extras it already holds the per-ticket CLAIM LOCK for.
BATCH=()
for _b in "$@"; do
  _b="${_b//[^0-9]/}"
  [[ -n "$_b" && "$_b" != "$N" ]] || continue
  BATCH+=("$_b")
done
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

# #18: LATCH the per-ticket `Effort:` field the SAME anchored way as Model — reasoning effort is an
# INDEPENDENT knob from model tier (raising effort is far cheaper than raising tier, so it's the
# correct first rung on the escalation ladder). Reuses MODEL_IS_RETRY: a failed cheap bet (either
# knob) shouldn't be re-bet on retry.
TICKET_EFFORT="$(printf '%s' "$block" \
  | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
  | sed -n 's/^[[:space:]]*\*\{0,2\}[Ee]ffort:\*\{0,2\}[[:space:]]*\([A-Za-z0-9._-]\{1,32\}\).*$/\1/p' \
  | head -1)"
export TICKET_EFFORT

# LATCH the per-ticket `Flow:` field (flow-registry validation ids) the SAME anchored way as Model —
# the contiguous leading field block only, so a `Flow:` mention in prose/code can't be mis-parsed.
# Space/comma list; whitespace normalized to single spaces. Injected as full flow blocks below.
TICKET_FLOW="$(printf '%s' "$block" \
  | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
  | sed -n -E 's/^[[:space:]]*\*{0,2}[Ff]low:\*{0,2}[[:space:]]*//p' | head -1 \
  | tr ',' ' ' | tr -s ' ' | sed -E 's/^ +//; s/ +$//')"
export TICKET_FLOW

# ── worker sizing (model tier + reasoning effort) ───────────────────────────────────────────────
# ONE resolver, called by BOTH the dry-run observation seam and the live spawn — previously the two
# paths carried copy-pasted resolution logic that could drift apart. Sets the globals
# `model`/`model_source`/`effort`/`effort_source`/`retry_class`/`retry_reason`. Emits NO log lines
# (the caller logs the decision once) so the dry-run seam stays a pure, quiet observation.
#
# First attempt: the brain-decided per-ticket `Model:`/`Effort:` fields win (allowlisted; an unknown
# value is dropped fail-safe), else the GOVERN_WORKER_MODEL / GOVERN_WORKER_EFFORT floors.
#
# Retry: classify WHY the last attempt failed (govern::retry_class) and escalate the axis that
# actually failed, instead of always jumping to GOVERN_WORKER_MODEL. See the table in lib/common.sh.
resolve_sizing() {
  local base_model base_effort escalated_model
  retry_class="first-attempt"; retry_reason="first attempt — no prior failure to classify"

  # Baseline = what the FIRST attempt would have used.
  base_model="${GOVERN_WORKER_MODEL:-opus}"; model_source="GOVERN_WORKER_MODEL"
  case "${TICKET_MODEL:-}" in
    "") ;;
    haiku|sonnet|opus) base_model="$TICKET_MODEL"; model_source="ticket-Model-field" ;;
    *) model_source="GOVERN_WORKER_MODEL (unknown ticket Model: '$TICKET_MODEL' ignored)" ;;
  esac
  base_effort="${GOVERN_WORKER_EFFORT:-}"; effort_source="GOVERN_WORKER_EFFORT"
  [[ -z "$base_effort" ]] && effort_source="none (unset)"
  case "${TICKET_EFFORT:-}" in
    "") ;;
    low|medium|high|xhigh|max) base_effort="$TICKET_EFFORT"; effort_source="ticket-Effort-field" ;;
    *) effort_source="${effort_source} (unknown ticket Effort: '$TICKET_EFFORT' ignored)" ;;
  esac
  model="$base_model"; effort="$base_effort"
  [[ "${MODEL_IS_RETRY:-0}" -eq 1 ]] || return 0   # first attempt: the baseline IS the answer

  IFS=$'\t' read -r retry_class retry_reason < <(govern::retry_class "$N") || true
  [[ -n "${retry_class:-}" ]] || { retry_class="unknown"; retry_reason="classifier produced no verdict"; }
  # Raising the tier means "at least the workspace floor" — never BELOW the tier this ticket already
  # asked for, so an escalation can't accidentally down-grade a `Model: opus` ticket.
  escalated_model="$(govern::model_max "$base_model" "${GOVERN_WORKER_MODEL:-opus}")"
  case "$retry_class" in
    infra|ci)
      # POSITIVELY identified non-model cause (transport outage / red CI on a portability-or-env
      # bug). Re-bet the SAME sizing: the tier was never the problem, and escalating it is the waste
      # the classifier exists to stop. The only path allowed to keep a sub-floor tier on a retry.
      model_source="$model_source (retry class=$retry_class — same tier, not escalated) [retry-class]"
      effort_source="$effort_source (retry class=$retry_class — unchanged) [retry-class]"
      ;;
    budget)
      # Ran out of room while still exploring → the SCOPE was underestimated, not the judgment.
      # Raise TIER only; compounding an effort raise on top just multiplies the spend.
      model="$escalated_model"
      model_source="escalated from $base_model (retry class=budget — scope underestimated) [retry-class]"
      effort_source="$effort_source (retry class=budget — tier raised, effort unchanged) [retry-class]"
      ;;
    judgment)
      # A coherent but WRONG fix → a judgment failure. Effort is the cheaper knob, so it always
      # moves; the tier moves too, but only when it is actually below the floor (when the prior
      # attempt already ran at the floor, judgment was marginal rather than absent and the effort
      # rung is the whole escalation).
      effort="$(govern::effort_bump "$base_effort")"
      model="$escalated_model"
      effort_source="escalated from ${base_effort:-<unset>} (retry class=judgment) [retry-class]"
      if [[ "$model" == "$base_model" ]]; then
        model_source="$model_source (retry class=judgment — already at the floor tier; effort raised instead) [retry-class]"
      else
        model_source="escalated from $base_model (retry class=judgment) [retry-class]"
      fi
      ;;
    *)
      # UNRECOGNIZED signature → exactly the pre-classifier behavior: discard the ticket's brain-decided
      # fields and escalate to the workspace floor. Fail-safe by construction.
      model="${GOVERN_WORKER_MODEL:-opus}"
      effort="${GOVERN_WORKER_EFFORT:-}"
      model_source="GOVERN_WORKER_MODEL (retry — ticket Model: '${TICKET_MODEL:-}' skipped)"
      effort_source="GOVERN_WORKER_EFFORT"; [[ -z "$effort" ]] && effort_source="none (unset)"
      if [[ -n "${TICKET_EFFORT:-}" ]]; then
        effort_source="${effort_source} (retry — ticket Effort: '$TICKET_EFFORT' skipped)"
      fi
      ;;
  esac
  # Explicit: under `set -e` a function whose LAST command is a false test would abort the spawn.
  return 0
}

# GOVERN_SPAWN_DRY_RUN=1: resolve the model tier as the real spawn would, print the assembled
# `claude -p` invocation params as ONE JSON line to stdout, and exit 0 WITHOUT creating a
# worktree and WITHOUT launching a worker. Purely an observation seam for the model-routing
# evidence harness and any operator who wants to probe what would be run — no auth, no cost,
# no side effects. Not part of the normal run path.
if [[ "${GOVERN_SPAWN_DRY_RUN:-0}" == "1" ]]; then
  # Same resolver the live spawn uses — the dry-run seam can never drift from the real
  # decision, and `retry_class`/`retry_reason` make the escalation policy directly observable.
  resolve_sizing
  dr_model="$model"; dr_source="$model_source"
  dr_effort="$effort"; dr_effort_source="$effort_source"
  dr_mode="${GOVERN_MODE:-live}"
  dr_perm="${GOVERN_PERMISSION_MODE:-bypassPermissions}"
  [[ "$dr_mode" == "dry" ]] && dr_perm="plan"
  dr_strict_mcp="--strict-mcp-config"; [[ "${GOVERN_WORKER_MCP:-0}" == "1" ]] && dr_strict_mcp=""
  jq -nc \
    --arg bin "${GOVERN_CLAUDE_BIN:-claude}" \
    --arg model "$dr_model" \
    --arg source "$dr_source" \
    --arg effort "$dr_effort" \
    --arg effort_source "$dr_effort_source" \
    --arg perm "$dr_perm" \
    --arg mcp "$dr_strict_mcp" \
    --arg wtpath "$WORKTREE_BASE/$slug" \
    --arg tm "$TICKET_MODEL" \
    --arg te "$TICKET_EFFORT" \
    --arg rclass "$retry_class" \
    --arg rreason "$retry_reason" \
    --argjson retry "$MODEL_IS_RETRY" \
    --arg n "$N" \
    '{ticket:($n|tonumber), claude_bin:$bin, model:$model, model_source:$source, ticket_model:$tm, effort:$effort, effort_source:$effort_source, ticket_effort:$te, is_retry:$retry, retry_class:$rclass, retry_reason:$rreason, permission_mode:$perm, strict_mcp:$mcp, worktree:$wtpath}'
  exit 0
fi

# 1b. #23: fold each co-batched ticket's block into $block so {{TICKET_BLOCK}} carries the WHOLE group
# (and the flow-staleness path scan below sees the group's paths too). Done AFTER the Model/Effort/Flow
# latches so those still read $N's leading field block only, and after the dry-run seam so its output
# is unchanged. A batched number that is no longer in tickets.md (a concurrent driver resolved it) is
# dropped here rather than failing the spawn — the run-loop's per-ticket outcome mapping then simply
# finds no entry for it and leaves it in the queue.
if [[ "${#BATCH[@]}" -gt 0 ]]; then
  _kept=()
  for _b in "${BATCH[@]}"; do
    _bblock="$(govern::ticket_block "$_b" "$TICKETS_FILE" 2>/dev/null || true)"
    [[ -n "$_bblock" ]] || { govern::log "spawn #$N: batched #$_b not in $TICKETS_FILE — dropping from the group"; continue; }
    _kept+=("$_b"); block="$block

$_bblock"
  done
  BATCH=(${_kept[@]+"${_kept[@]}"})
fi

# 2. Assemble the prompt: template (with {{TICKET_BLOCK}}/{{REPORT_PATH}} filled) + doctrine.
template="$(cat "$WORKER_PROMPT_FILE")"
prompt="${template//\{\{TICKET_BLOCK\}\}/$block}"
prompt="${prompt//\{\{REPORT_PATH\}\}/$report_path}"
prompt="$prompt

## Operator doctrine
$(cat "$PREFERENCES_FILE")"

# #23: batch addendum. Appended AFTER the template and the doctrine so it overrides their "resolve
# EXACTLY ONE ticket" / single-object report contract (last instruction wins). The per-ticket
# `tickets` array is load-bearing: the governor bookkeeps (and DELETES) a batched ticket ONLY when
# this array explicitly says that ticket resolved. Anything else — a different status, or the ticket
# missing from the array — leaves it in the queue for a later run. That fail-closed default is why a
# partially-failed group can never mark unfixed tickets resolved.
if [[ "${#BATCH[@]}" -gt 0 ]]; then
  _grp="$(printf '#%s, ' "$N" "${BATCH[@]}")"; _grp="${_grp%, }"
  prompt="$prompt

## ⚠ LOCALITY BATCH — you are resolving ${#BATCH[@]} EXTRA ticket(s), not one (overrides \"EXACTLY ONE ticket\")
These tickets were grouped because they touch the SAME area of the codebase, so ONE worker explores it
once instead of N workers each paying full discovery cost. **The ticket blocks above are ALL of them:
$_grp** — #$N is the primary.

Rules for a batch:
1. **Explore once, fix all.** Read the area once, then work each ticket in turn. Ticket blocks appear
   in the order you should work them.
2. **ONE branch and ONE PR for the whole group** — the primary's branch (\`ticket-$N\`, or the neutral
   token if the public-repo hygiene section below applies). Do NOT open a PR per ticket. Use separate
   commits per ticket so the PR stays reviewable, and describe every ticket in the PR body.
3. **A ticket you could NOT finish is not a failure of the group.** Finish the ones you can, and report
   the rest honestly. Never stretch one ticket's fix to \"cover\" another.
4. **REQUIRED — per-ticket outcomes.** Your report JSON MUST carry a top-level \`tickets\` array with
   ONE entry for EVERY ticket in the group ($_grp), even the ones you did not finish:

   \"tickets\": [{\"ticket\": $N, \"status\": \"resolved|parked|failed\", \"note\": \"one line: what landed, or why not\"}, ...]

   A ticket you omit, or mark anything other than \`resolved\`, STAYS IN THE QUEUE for a later run —
   which is the correct, safe outcome. Do NOT mark a ticket \`resolved\` unless its fix is actually in
   the PR. The top-level \`status\` field still describes the group as a whole (use \`resolved\` if the
   PR is open with at least one ticket fixed); the \`tickets\` array is what bookkeeping acts on.
5. Everything else — \`pr\`/\`prs\`, \`newTickets\`, \`crossRefs\`, \`migration\`, \`validation\`,
   \`escalation\`, the PR footer, park rules — is unchanged and applies to the group."
fi

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

🤖 shipped by [shiploop](https://github.com/anshss/shiploop)"
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

## Flow(s) this ticket validates (from .claude/shiploop/validation/flows.md)
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
  if [[ -f "$_flow_meta/.claude/shiploop/validation/flows.md" && ${#REPOS[@]} -gt 0 ]]; then
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

## Heads-up — flows your change may STALE (.claude/shiploop/validation/flows.md)
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

# Per-ticket brain-decided model + effort routing, and — on a retry — the retry-class evidence-based
# escalation. All of it lives in resolve_sizing() (defined above, shared with the dry-run seam):
#   - FIRST attempt: the ticket's `Model:`/`Effort:` fields win (the brain that triaged the ticket
#     recorded them; the harness carries no heuristic of its own), else the GOVERN_WORKER_* floors.
#     An unknown value is dropped fail-safe. `MODEL_IS_RETRY` was latched BEFORE worktree/new.sh
#     created a fresh worktree, so it always reflects the STATE-BEFORE-spawn.
#   - RETRY: the failure signature of the PRIOR attempt decides which axis escalates — an
#     infra/CI-portability failure re-bets the SAME tier, a budget blow-out raises the tier, a
#     coherent-but-wrong fix raises effort (and tier), and an UNRECOGNIZED signature falls back to
#     exactly the pre-classifier escalate-to-GOVERN_WORKER_MODEL behavior.
resolve_sizing
# The decision AND its reason, in one line — this is the audit trail for every retry escalation.
govern::log "worker #$N sizing: model=$model [$model_source] effort=${effort:-none} [$effort_source] retry-class=$retry_class — $retry_reason"

# Lean worker: a code-fix worker uses git/gh/<pm> via Bash, not MCP. Loading the operator's
# inherited MCP fleet (often 8+ stdio servers / dozens of tools) just slows worker startup and
# risks a teardown stall on exit. --strict-mcp-config = load ONLY --mcp-config files (we pass
# none) → zero MCP servers. Set GOVERN_WORKER_MCP=1 to keep the inherited servers.
strict_mcp="--strict-mcp-config"; [[ "${GOVERN_WORKER_MCP:-0}" == "1" ]] && strict_mcp=""

# Disable slash commands: workers never invoke /skills or /slashes, so loading the full
# command surface wastes baseline context. ~2,600 tokens saved per turn. Set GOVERN_WORKER_SLASH_COMMANDS=1
# to restore (e.g., if worker prompt instructs slash-command invocation).
disable_slash_cmds="--disable-slash-commands"; [[ "${GOVERN_WORKER_SLASH_COMMANDS:-0}" == "1" ]] && disable_slash_cmds=""

# #18: only pass --effort when resolved to a non-empty value — an unset knob means the worker runs
# at the CLI's session-default effort, exactly as before this ticket (no invented default).
effort_flag=""; [[ -n "$effort" ]] && effort_flag="--effort $effort"

to="${GOVERN_WORKER_TIMEOUT:-3600}"   # per-worker wall-clock cap (s); 0 = unbounded. Default 1h.
worker_killed=0

# #19: PER-ATTEMPT LEDGER. One ticket can be spawned MORE THAN ONCE against the same (run-scoped) log
# dir: an in-run infra/interrupted auto-retry, a GOVERN_FIX_CI re-dispatch, a GOVERN_RESOLVE_CONFLICT
# re-dispatch. Each spawn used to just reopen worker.jsonl with a truncating `>`, which lost the prior
# attempt's usage AND (when the prior attempt's fd was still open at a high offset) left a NUL hole at
# the head of the file that made every later `grep` read the stream as binary and match nothing.
# So: (a) number this attempt from the ledger's existing row count, (b) ROTATE the previous attempt's
# stream aside — the redirect below then creates a brand-new inode, so a stale fd can never corrupt
# the live file and the killed attempt's stream survives for forensics, and (c) after the worker exits,
# append one append-only row carrying this attempt's sizing DECISION (model/effort/attempt) and its
# MEASURED usage. run-loop's history enrichment reads this ledger, so ticket-history.jsonl records the
# decision beside the cost and a killed attempt's spend is never silently dropped.
attempts_file="$logdir/attempts.jsonl"
attempt=1
if [[ -s "$attempts_file" ]]; then
  attempt=$(( $(awk 'END{print NR+0}' "$attempts_file" 2>/dev/null || echo 0) + 1 ))
fi
if [[ -f "$jsonl" ]]; then
  # attempt>1 → this run's previous attempt (numbered). attempt==1 with a stream already present →
  # a stream left by an EARLIER standalone invocation in the flat log dir; park it under a neutral name.
  if [[ "$attempt" -gt 1 ]]; then rotated="$logdir/worker.attempt$((attempt-1)).jsonl"
  else rotated="$logdir/worker.prior.jsonl"; fi
  mv -f "$jsonl" "$rotated" 2>/dev/null || rm -f "$jsonl" 2>/dev/null || true
fi

# Append this attempt's row. Called on EVERY exit path (clean return and the INT/TERM/EXIT teardown),
# because the attempts a stop signal kills are exactly the expensive ones worth accounting for.
# Idempotent (a `written` latch) and best-effort — it never changes the worker's reported outcome.
attempt_row_written=0
record_attempt() { # status -> appends one ledger row
  [[ "$attempt_row_written" -eq 0 ]] || return 0
  attempt_row_written=1
  local st="${1:-unknown}" usage
  usage="$(govern::stream_usage "$jsonl" 2>/dev/null || echo '{"tokens":null,"costUsd":null,"usageSource":"none"}')"
  jq -nc --argjson a "$attempt" --arg m "$model" --arg ms "$model_source" \
     --arg e "$effort" --arg es "$effort_source" --arg tm "${TICKET_MODEL:-}" \
     --argjson retry "$MODEL_IS_RETRY" --arg mode "$mode" --arg st "$st" \
     --argjson u "$usage" --argjson ts "$(date +%s)" \
     '{attempt:$a, model:$m, modelSource:$ms,
       effort:(if $e == "" then null else $e end), effortSource:$es,
       ticketModel:(if $tm == "" then null else $tm end), isRetry:($retry == 1),
       mode:$mode, status:$st, ts:$ts} + $u' >> "$attempts_file" 2>/dev/null || true
  return 0
}

# #16: per-attempt cumulative TOKEN cap — wall-clock was the only ceiling before this; a worker that
# wanders can burn tens of millions of tokens before $to fires (tickets #3/#6: ~22M tokens/~$9.7
# each). GOVERN_WORKER_MAX_TOKENS=0 is the DEFAULT and means unlimited, preserving current behavior
# for anyone who does not opt in. When set >0, a watchdog polls the LIVE worker.jsonl every
# GOVERN_TOKEN_POLL_S seconds (govern::cumulative_tokens) and kills the worker tree exactly like the
# wall-clock watchdog below once cumulative tokens exceed the budget — but stamps a $budget_marker
# file so the outcome is recorded as a DISTINCT `budget-exceeded` status, not `timeout` (a future
# evidence-based escalation needs to tell "ran out of budget while still exploring" apart from other
# failure modes).
tok_budget="${GOVERN_WORKER_MAX_TOKENS:-0}"
tok_poll="${GOVERN_TOKEN_POLL_S:-20}"
worker_budget_exceeded=0
budget_marker="$logdir/budget-exceeded.marker"; rm -f "$budget_marker"
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

govern::log "spawning worker for #$N (mode=$mode, model=$model, effort=${effort:-none} [$effort_source], timeout=${to}s) in $wtpath"
govern::log "worker #$N OTel resource attrs: ${otel_attrs}"

# #242: tear the worker subtree down on EVERY exit path so a stopped/killed governor never leaves an
# orphaned `claude -p` (+ any grandchildren it spawned) reparented to init and billing a box. $cpid is
# launched under `set -m` below → it LEADS its own process group, so govern::kill_tree reaps the whole
# tree (group kill + pid-walk) in one sweep. The EXIT trap covers a clean return (cpid already gone →
# fast no-op) and an abrupt one; the INT/TERM trap covers run-loop forwarding a stop signal to us
# (run-loop SIGTERMs this process on its own stop), so the kill cascades driver → spawn-worker → tree.
cpid=""; wd=""; twd=""; _spawn_signalled=0
spawn_worker_cleanup() {
  [[ -n "${wd:-}" ]] && { kill "$wd" 2>/dev/null || true; govern::_kill_tree_walk "$wd" TERM; }
  [[ -n "${twd:-}" ]] && { kill "$twd" 2>/dev/null || true; govern::_kill_tree_walk "$twd" TERM; }
  [[ -n "${cpid:-}" ]] && govern::kill_tree "$cpid" "${GOVERN_KILL_GRACE_S:-10}"
  # #19: account for an attempt torn down BEFORE it could reach the normal record_attempt call below —
  # those are the expensive rows a sizing loop most needs. The tree is already dead here, so the stream
  # has stopped growing and its per-turn usage is final. Latched, so the normal exit path (which
  # already recorded the real status) makes this a no-op. The status distinguishes a forwarded stop
  # signal from any other early exit, so neither is mislabelled.
  if [[ "${_spawn_signalled:-0}" -eq 1 ]]; then record_attempt "killed-by-signal"
  else record_attempt "aborted-before-verdict"; fi
  return 0   # EXIT-trap body must end 0 — its last status would otherwise become the script's exit code
}
trap 'spawn_worker_cleanup' EXIT
trap '_spawn_signalled=1; govern::log "spawn-worker #'"$N"' received stop signal — tearing down worker tree [#242]"; spawn_worker_cleanup; exit 143' INT TERM

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
    $strict_mcp $disable_slash_cmds \
    --permission-mode "$permflag" --model "$model" $effort_flag ) >"$jsonl" 2>&1 &
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
# #16: token-budget watchdog — same shape as the wall-clock one above, polling cumulative usage
# instead of a fixed deadline. 1>/dev/null for the same reason: it must not inherit this script's
# stdout, which feeds the caller's $(...) capture.
if [[ "$tok_budget" -gt 0 ]]; then
  ( while kill -0 "$cpid" 2>/dev/null; do
      sleep "$tok_poll"
      kill -0 "$cpid" 2>/dev/null || break
      cur="$(govern::cumulative_tokens "$jsonl")"
      if [[ "${cur:-0}" -gt "$tok_budget" ]]; then
        govern::log "worker #$N exceeded token budget (${cur} > ${tok_budget}) — terminating worker tree; worktree PRESERVED at $wtpath (re-run resumes) [#16]"
        : > "$budget_marker"
        govern::kill_tree "$cpid" 10
        break
      fi
    done ) 1>/dev/null & twd=$!
fi
wait "$cpid"; rc=$?
if [[ -n "$wd" ]]; then kill "$wd" 2>/dev/null; govern::_kill_tree_walk "$wd" TERM; fi
if [[ -n "$twd" ]]; then kill "$twd" 2>/dev/null; govern::_kill_tree_walk "$twd" TERM; fi
wd=""; cpid=""; twd=""   # worker + watchdogs reaped — disarm the cleanup traps' fast path
set -e
if [[ "$rc" -gt 128 ]]; then worker_killed=1; fi
[[ -f "$budget_marker" ]] && { worker_killed=1; worker_budget_exceeded=1; }

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
  # govern::stream_grep (not bare grep): a NUL-holed stream would otherwise hide a perfectly good
  # report and get the attempt synthesized as `failed` (#19).
  result_msg="$(govern::stream_grep "$jsonl" '"type":"result"' | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"
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
#      budget-exceeded — same kill-before-verdict shape, but HARD-KILLED by the GOVERN_WORKER_MAX_TOKENS
#                watchdog instead of the wall-clock one (#16). Kept DISTINCT from "timeout" so a
#                future evidence-based escalation can tell "ran out of budget while still exploring"
#                apart from other failure modes.
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
  elif [[ "$worker_budget_exceeded" -eq 1 ]]; then
    # #16: kill-before-verdict via the TOKEN watchdog — a DISTINCT outcome from a wall-clock timeout,
    # not failed. The worktree is preserved; a re-run resumes it.
    reason="worker exceeded the GOVERN_WORKER_MAX_TOKENS budget (${tok_budget} tokens) and was hard-killed before it could write its verdict — INCOMPLETE, not a genuine failure; any real work is PRESERVED at $wtpath (a re-run resumes). Distinct from a wall-clock timeout: this worker burned its token budget, which usually means it was still exploring/wandering (#16)."
    govern::log "worker for #$N → budget-exceeded (killed before verdict; NOT recorded failed) [#16]: $reason"
    report="$(jq -nc --arg r "$reason" --arg wt "$wtpath" \
      '{status:"budget-exceeded",pr:null,lessonPatch:null,newTickets:[],crossRefs:{},escalation:{reason:$r,question:("re-run the ticket to resume from "+$wt+" (or raise GOVERN_WORKER_MAX_TOKENS if it legitimately needs a bigger budget)"),options:[]}}')"
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

# #19: the outcome is now known — append this attempt's decision + measured usage to the ledger.
# `status` comes from the report itself, so a killed attempt records `timeout`/`budget-exceeded` and
# a genuine failure records `failed`, each with the tokens it actually burned.
record_attempt "$(printf '%s' "$report" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)"

printf '%s\n' "$report"
