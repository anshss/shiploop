#!/usr/bin/env bash
# resolve-ticket.sh — the SESSION-SIDE resolve path for ticket N (shiploop 1.19.2, the loop purge).
#
# A worker stops at PR-open plus a report; nothing else finishes the job for a plain Claude Code
# session. This script is that missing step: hand it the exact report a worker (headless or
# interactive) produced, and it awaits CI, merges, applies the prod migration if one is needed,
# and lands the ticket.
#
# Usage:  printf '%s' "$report" | resolve-ticket.sh <N> [--no-merge]
#   <N>          the ticket number.
#   --no-merge   skip the CI-await + merge steps for a PR the OPERATOR already merged (or
#                deliberately left open) by hand — go straight to landing.
#   stdin        the worker's JSON report — the EXACT shape land-resolution.sh consumes:
#                .pr, .prs[], .status, .lessonPatch, .newTickets[], .validation.*
#                Accepted `.pr` shapes (an ambiguous contract once let a present-but-
#                unparseable `.pr` silently land as "no PR", deleting a queue block with the PR
#                still open, unmerged):
#                  * absent / null            — no PR at all (see `.prs[]`), e.g. omit the field.
#                  * an OBJECT                  {"repo":"alpha","number":42,"url":"https://github.com/acme/alpha/pull/42"}
#                                               — `.repo` + `.number` required, `.url` optional.
#                  * a bare INTEGER             42
#                                               — the shape a worker naturally emits when it only
#                                               knows the number; the repo is resolved from the
#                                               workspace's configured repos (govern::resolve_pr_repo).
#                Anything else present (a non-numeric string, an object missing `.repo`/`.number`,
#                an integer no configured repo has open) is a HARD REFUSAL before any bookkeeping —
#                never treated as "no PR". `.prs[]` entries follow the same OBJECT shape.
#
# What it does, in order:
#   1. Refuse anything whose report.status is not "resolved" — that is the worker's own concern,
#      not this script's; read the worker's output directly.
#   2. Normalize `.pr` into {repo,number,url}, or REFUSE: a `.pr` that is present but not
#      one of the accepted shapes (see the stdin contract above) must never fall through to the
#      "no PR" path — that silent fall-through once deleted a queue block while the PR sat open,
#      unmerged. This runs BEFORE any bookkeeping, so a refusal here leaves tickets.md untouched.
#   3. PR-hygiene backstop: strip a leaked internal #N reference from the PR's title/body, and warn
#      if a Claude spec/plan artifact leaked into the diff. Scoped to the single reported .pr (not
#      every PR a multi-repo ticket opened).
#   4. The validation-evidence gate (no live-test evidence / gate measured a negative):
#      refuse to land, explain which of the two rules tripped, exit non-zero. A refusal here is a
#      product-judgment call the worker must never make for itself.
#   5. Await CI + merge EVERY PR the report names (.pr + .prs[]), via the EXISTING await-ci.sh /
#      merge-pr.sh — never reimplemented here. merge-pr.sh's exit code is honoured exactly:
#        0 merged · 2 frontend/PR-only · 3 CI red/pending · 4 CI unverifiable ·
#        5 external-PR-blocked · 6 left-open (GOVERN_AUTONOMY observe/pr-only)
#      rc 2 and rc 6 are LEFT OPEN BY DESIGN, not refusals: the PR is deliberately not this
#      governor's to merge, so the ticket still lands with the PR surfaced in the history note,
#      exactly as the loop bookkept it. rc 3/4/5 (and anything unexpected) mean the PR is not
#      known-good: do NOT land, print what happened and why, exit non-zero so the session can act.
#      On rc 3, also print ci-log.sh's bounded excerpt of the failing run on stderr, alongside the
#      refusal, so the reader gets the actual failure instead of re-dispatching blind to find
#      it. ci-log.sh is fail-open, so this never changes the refusal itself.
#      A refusal is not a failure of this script, it is information: the interactive session (or the
#      operator) decides what to do next, then re-runs this script (plain, once the refusal clears,
#      or with --no-merge once they handled it by hand).
#   6. If the report needs a prod migration, apply it via GOVERN_MIGRATE_CMD: refuse a destructive
#      migration, neutralize it locally first, then apply, verify, and classify any failure.
#   6b. If the report names `rootScope.commits` (root-only work with no PR of its own — a fix
#       confined to scripts/**, governor/**), cherry-pick them onto local main here; refuse if any
#       commit reaches into a sub-repo path or the cherry-pick fails. Then refuse the WHOLE resolve,
#       before any bookkeeping, if a report claiming "resolved" produced no PR, no landed
#       root-scope commit, no lessonPatch and no applied migration (GOVERN_ALLOW_EMPTY_RESOLVE=1
#       overrides a genuinely deliberate no-op).
#   7. Only once every PR is merged (or --no-merge) and the migration step (if any) succeeded:
#      pipe the report into land-resolution.sh <N> — the actual tickets.md edit + commit + push.
#   8. Worker-boundary cleanup that belongs wherever a worker's resolution actually lands: refresh
#      the codebase index (GOVERN_INDEX) and tear down the ticket's worktree.
#   9. Record the outcome into ticket-history.jsonl (govern-health.sh's only input), in the
#      {ticket,run,status,ts} shape every reader expects.
#
# Kill switch: GOVERN_RESOLVE_TICKET=0 refuses to run at all (exit 1) — there is no sensible
# "quiet no-op" for the one script that lands a resolution; a silent skip here would look like a
# successful land to anyone not reading stderr.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

if [[ "${GOVERN_RESOLVE_TICKET:-1}" == "0" ]]; then
  echo "resolve-ticket: disabled (GOVERN_RESOLVE_TICKET=0) — not landing anything" >&2
  exit 1
fi

NO_MERGE=0
N=""
PR_DISPOSITIONS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-merge) NO_MERGE=1; shift ;;
    [0-9]*)     N="$1"; shift ;;
    *)          govern::die "usage: resolve-ticket.sh <N> [--no-merge]" ;;
  esac
done
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "usage: resolve-ticket.sh <N> [--no-merge] — ticket number required"

report="$(cat)"
[[ -n "$report" ]] || govern::die "resolve-ticket #$N: no report on stdin — pipe the worker's JSON report in"
jq -e . >/dev/null 2>&1 <<<"$report" || govern::die "resolve-ticket #$N: stdin is not valid JSON"

status="$(jq -r '.status // "failed"' <<<"$report" 2>/dev/null || echo failed)"
if [[ "$status" != "resolved" ]]; then
  echo "resolve-ticket #$N: report status is '$status', not 'resolved' — nothing to land. Read the worker's own output/escalation and handle it directly." >&2
  exit 2
fi

# ── Normalize/validate the reported `.pr` shape, or REFUSE ─────────────────────────────────────
# A present-but-unparseable `.pr` (a bare integer, a malformed object, any other shape) used to
# fall through to the SAME branch as a genuinely PR-less report, and that branch LANDS — deleting
# the queue block while the real PR sat open, unmerged, with only a stderr line as the signal. This
# runs BEFORE any bookkeeping (no ticket-history write, no land-resolution.sh call), so a refusal
# here leaves tickets.md byte-identical. See the stdin contract at the top of this file for the
# accepted `.pr` shapes.
_norm_report="$(govern::normalize_pr_field "$report")" && report="$_norm_report" || {
  echo "resolve-ticket #$N: .pr is present but not one of the accepted shapes (an object {repo,number,url}, or a bare integer PR number a configured repo has open): refusing BEFORE any bookkeeping rather than silently landing as 'no PR'. Fix the report's .pr field and re-run." >&2
  exit 9
}

# ── ticket-history.jsonl writer ─────────────────────────────────────────────────────────────────
# Writes govern-health.sh's only input, in the {ticket,run,status,ts} shape plus
# tokens/costUsd/model/effort/attempt/usageSource/churn/repos. "run" falls back to "manual" exactly
# like land-resolution.sh's own --source string does when GOVERN_RUN_DIR is unset.
rt_history_enrich() { # -> json extra fields (tokens/costUsd/model/effort/attempt/usageSource/churn/repos)
  local logdir jsonl extra
  logdir="$(govern::worker_logdir "$N")"
  jsonl="$logdir/worker.jsonl"
  extra="$(govern::stream_usage "$jsonl" 2>/dev/null || echo '{}')"
  [[ -n "$extra" ]] || extra='{}'
  local repos nrepos nself _r churn
  repos="$(printf '%s' "$report" | jq -c '[ (.pr // empty), (.prs // [])[] ]
    | map(.repo // empty) | map(select(. != "")) | unique' 2>/dev/null || echo '[]')"
  [[ "$repos" == "null" || -z "$repos" ]] && repos='[]'
  churn='null'
  nrepos="$(printf '%s' "$repos" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "${nrepos:-0}" -gt 0 ]]; then
    nself=0
    while IFS= read -r _r; do [[ -n "$_r" ]] && govern::is_selfref_repo "$_r" && nself=$((nself+1)); done \
      < <(printf '%s' "$repos" | jq -r '.[]' 2>/dev/null || true)
    if [[ "$nself" -eq "$nrepos" ]]; then churn=true; else churn=false; fi
  fi
  jq -nc --argjson e "$extra" --argjson ch "$churn" --argjson rp "$repos" \
    '{tokens:null, costUsd:null, model:null, effort:null, attempt:null, usageSource:null}
     + $e + {churn:$ch, repos:$rp}' 2>/dev/null || echo '{}'
  return 0
}

rt_record_history() { # status note
  local st="$1" note="${2:-}"
  local run_label base extra
  run_label="$(basename "${GOVERN_RUN_DIR:-manual}")"
  base="$(jq -nc --argjson t "$N" --arg run "$run_label" --arg st "$st" --argjson ts "$(date +%s)" \
    '{ticket:$t, run:$run, status:$st, ts:$ts}' 2>/dev/null \
    || printf '{"ticket":%s,"run":"%s","status":"%s","ts":%s}' "$N" "$run_label" "$st" "$(date +%s)")"
  extra="$(rt_history_enrich 2>/dev/null || echo '{}')"
  printf '%s\n' "$(jq -c --argjson e "$extra" '. + $e' <<<"$base" 2>/dev/null || printf '%s' "$base")" \
    >> "$TICKET_HISTORY_FILE" 2>/dev/null || true
  return 0
}

# ── 1. PR-hygiene backstop ──────────────────────────────────────────────────────────────────────
# Scoped to the single reported .pr: a multi-repo ticket's OTHER PRs are handled by the merge
# loop below, not by this scrub.
_pr_num="$(jq -r '.pr.number // ""' <<<"$report" 2>/dev/null || true)"
_pr_url="$(jq -r '.pr.url // ""' <<<"$report" 2>/dev/null || true)"
_pr_repo="$(jq -r '.pr.repo // ""' <<<"$report" 2>/dev/null || true)"
if [[ -n "$_pr_num" ]]; then
  _pr_slug="$(printf '%s' "$_pr_url" | sed -nE 's#https?://github.com/([^/]+/[^/]+)/pull/.*#\1#p')"
  [[ -n "$_pr_slug" ]] || _pr_slug="$(govern::repo_slug "$_pr_repo" 2>/dev/null || true)"
  if [[ -n "$_pr_slug" ]]; then
    _scrub=1
    if [[ "${GOVERN_PR_TICKET_REF:-0}" == "1" ]] && ! govern::repo_is_public "$_pr_repo" 2>/dev/null; then
      _scrub=0
    fi
    [[ "$_scrub" == "1" ]] && govern::scrub_pr_ticket_ref "$_pr_slug" "$_pr_num" "$N"
    _specs="$(govern::pr_spec_files "$_pr_slug" "$_pr_num" 2>/dev/null || true)"
    [[ -n "$_specs" ]] && echo "resolve-ticket #$N: WARN $_pr_slug#$_pr_num includes Claude spec/plan artifact(s) that must NOT be on a public PR — strip before merge: $(printf '%s' "$_specs" | tr '\n' ' ')" >&2
  fi
fi

# ── 2. The validation-evidence gate ─────────────────────────────────────────────────────────────
# Structured fields only (heading VALIDATION|SPIKE marker, **Type:**), never the prose tells
# (govern::is_validation_ticket's broader match): those are the advisor's own wording in
# Observed/Done-when text, not something a script should guess dispatch intent from before
# refusing to land a PR. GOVERN_VALIDATION_GATE is the same kill switch ticket-sweep-reminder.sh's
# Stop-hook block already answers to, so one switch disables both blocking call sites at once.
tblock="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
if [[ "${GOVERN_VALIDATION_GATE:-1}" != "0" ]] && govern::is_validation_ticket_strict "$tblock"; then
  case "$(govern::validation_gate_action "$report")" in
    park-no-evidence)
      echo "resolve-ticket #$N: VALIDATION ticket but the worker gave no live-test evidence (validation.ranLiveTest != true, or no evidence): refusing to auto-resolve. Run the actual test and attach evidence, or confirm it cannot be automated and record a disposition. The PR (if any) is left open for review." >&2
      rt_record_history parked "validation gate: no live-test evidence"
      exit 3
      ;;
    park-gate-failed)
      echo "resolve-ticket #$N: VALIDATION ticket whose gate FAILED (validation.gatePassed == false): refusing to auto-ship a measured-NEGATIVE result. Decide kill / ship-default-off / shelve / rework yourself; do not let a worker self-decide. The PR (if any) is left open for review." >&2
      rt_record_history parked "validation gate: measured negative"
      exit 3
      ;;
  esac
fi

# Print ci-log.sh's bounded excerpt for a refused PR on stderr, alongside the refusal above it.
# the advisor's cheapest next move without it is a full re-dispatch to rediscover what CI already
# knows. ci-log.sh is fail-open by design: a missing `gh`, a network failure, a run still pending
# with no failing check yet, or any other problem prints nothing and exits nonzero, so this call
# can never change what caller prints or how it exits. `|| true` plus the explicit `return 0`
# below keep it that way under `set -euo pipefail`: this function's exit status is never checked
# and must never propagate.
rt_print_ci_excerpt() { # <repo> <pr>
  local excerpt
  excerpt="$("$DIR/ci-log.sh" "$1" "$2" 2>/dev/null || true)"
  [[ -n "$excerpt" ]] && printf '%s\n' "$excerpt" >&2
  return 0
}

# ── 3. Await CI + merge every PR the report names. merge-pr.sh calls await-ci.sh internally
#    (never reimplemented here). ────────────────────────────────────────────────────────────────
pr_lines="$(govern::collect_ticket_prs "$N" "$report")"
MERGE_REPO_MERGED=0
if [[ "$NO_MERGE" -eq 1 ]]; then
  echo "resolve-ticket #$N: --no-merge — skipping CI/merge (operator already handled it), landing directly" >&2
  MERGE_REPO_MERGED=1
elif [[ -n "$pr_lines" ]]; then
  # Two DIFFERENT non-zero classes, exactly as the loop drew the line:
  #   LEFT OPEN, still land, rc 2 (frontend/PR-only repo: a different account merges it) and
  #     rc 6 (GOVERN_AUTONOMY observe/pr-only: the governor opens PRs and does not merge them).
  #     Neither is a failure of the resolution: the work is done, the PR is deliberately not ours
  #     to merge, and the loop bookkept the ticket resolved with the PR SURFACED as left-open.
  #     Refusing to land here would strand every multi-repo ticket with a frontend sibling and
  #     every pr-only workspace permanently un-bookkept.
  #   REFUSAL, do not land, rc 3 (CI red/pending), 4 (CI unverifiable), 5 (external-PR guard) and
  #     anything unexpected. Those say "this PR is not known-good", which is exactly the case where
  #     landing edits tickets.md against work that never merged.
  ALL_MERGED=1
  PR_DISPOSITIONS=""
  while IFS=$'\t' read -r _mrepo _mnum _murl; do
    [[ -n "$_mrepo" && -n "$_mnum" ]] || continue
    set +e
    "$DIR/merge-pr.sh" "$_mrepo" "$_mnum"
    _mrc=$?
    set -e
    case "$_mrc" in
      0)
        echo "resolve-ticket #$N: merged $_mrepo#$_mnum" >&2
        PR_DISPOSITIONS="$PR_DISPOSITIONS $_mrepo#$_mnum(merged)"
        govern::is_merge_repo "$_mrepo" && MERGE_REPO_MERGED=1
        ;;
      2)
        echo "resolve-ticket #$N: $_mrepo#$_mnum left open (frontend is PR-only), surfaced, not merged; merge it yourself when ready." >&2
        PR_DISPOSITIONS="$PR_DISPOSITIONS $_mrepo#$_mnum(frontend-left-open)"
        ;;
      6)
        echo "resolve-ticket #$N: $_mrepo#$_mnum left open, GOVERN_AUTONOMY=$(govern::autonomy) (the governor opens PRs, it does not auto-merge; flip to auto to enable) [autonomy]" >&2
        PR_DISPOSITIONS="$PR_DISPOSITIONS $_mrepo#$_mnum(autonomy-left-open)"
        ;;
      3)
        echo "resolve-ticket #$N: $_mrepo#$_mnum refused: CI is red or still pending. Fix CI (or wait for it), then re-run resolve-ticket." >&2
        rt_print_ci_excerpt "$_mrepo" "$_mnum"
        ALL_MERGED=0
        ;;
      4) echo "resolve-ticket #$N: $_mrepo#$_mnum refused: CI state could not be verified (gh network/auth/rate-limit/5xx). Investigate, then re-run." >&2; ALL_MERGED=0 ;;
      5) echo "resolve-ticket #$N: $_mrepo#$_mnum refused: external-PR safety guard blocked it (not this governor's own PR/branch). Merge it by hand via gh/web if trusted, then re-run with --no-merge." >&2; ALL_MERGED=0 ;;
      *) echo "resolve-ticket #$N: $_mrepo#$_mnum — merge-pr.sh exited $_mrc (unexpected)." >&2; ALL_MERGED=0 ;;
    esac
  done <<< "$pr_lines"
  if [[ "$ALL_MERGED" != "1" ]]; then
    echo "resolve-ticket #$N: a PR is not known-good, NOT landing the resolution. A refusal above is information, not a failure of this script: fix it (or merge by hand), then re-run." >&2
    exit 5
  fi
else
  echo "resolve-ticket #$N: no PR found on the report (.pr/.prs[] empty, none discovered) — nothing to merge; landing the resolution as-is." >&2
fi

# ── 4. Prod migration: destructive refusal + local-first neutralization + apply-then-verify-
#    then-classify shape ───────────────────────────────────────────────────────────────────────
mneeded="$(jq -r '.migration.needed // false' <<<"$report" 2>/dev/null || echo false)"
mdestr="$(jq -r '.migration.destructive // false' <<<"$report" 2>/dev/null || echo false)"

if [[ "$mneeded" == "true" && "$mdestr" != "true" && -n "$pr_lines" ]]; then
  _all_localfirst=1
  while IFS=$'\t' read -r _lfr _lfp _lfu; do
    [[ -n "$_lfr" ]] || continue
    govern::is_local_first_repo "$_lfr" || { _all_localfirst=0; break; }
  done <<< "$pr_lines"
  if [[ "$_all_localfirst" == "1" ]]; then
    echo "resolve-ticket #$N: additive migration ships as auto-applying code on local-first repo(s): no prod apply needed; proceeding as a normal resolve" >&2
    mneeded="false"
  fi
fi

if [[ "$mneeded" == "true" && "$mdestr" == "true" ]]; then
  echo "resolve-ticket #$N: needs a DESTRUCTIVE prod migration ($(jq -r '.migration.name // "?"' <<<"$report")) — NOT landing. Review, apply the migration manually, then re-run with --no-merge." >&2
  rt_record_history parked "destructive prod migration needed"
  exit 6
elif [[ "$mneeded" == "true" && -z "${GOVERN_MIGRATE_CMD:-}" ]]; then
  echo "resolve-ticket #$N: needs an additive prod migration but no GOVERN_MIGRATE_CMD is configured — NOT landing. Apply it manually, then re-run with --no-merge." >&2
  rt_record_history parked "additive prod migration needed, no GOVERN_MIGRATE_CMD"
  exit 6
elif [[ "$mneeded" == "true" && "$MERGE_REPO_MERGED" == "1" ]]; then
  echo "resolve-ticket #$N: applying additive prod migration via GOVERN_MIGRATE_CMD" >&2
  mout="$( cd "$WS_ROOT" && eval "$GOVERN_MIGRATE_CMD" 2>&1 )" || true
  if [[ -n "${GOVERN_VERIFY_CMD:-}" ]]; then
    vout="$( cd "$WS_ROOT" && eval "$GOVERN_VERIFY_CMD" 2>&1 )" && vrc=0 || vrc=$?
  else
    vout=""
    vrc=0
  fi
  if [[ "$vrc" -ne 0 ]]; then
    mverify="$vout"$'\n'"$mout"
    esc_reason=""
    if printf '%s' "$mverify" | grep -qiE 'FAILED / half-applied|failed state|migrate resolve'; then
      esc_reason='prod migration is in a FAILED / half-applied state after merge — needs a `migrate resolve` (do NOT re-run the migrate step); inspect migration status on prod'
    elif printf '%s' "$mverify" | grep -qiE 'ff-pull FAILED|BEHIND origin/main|STALE on-disk'; then
      esc_reason='could not fast-forward the merged checkout to origin/main before applying the migration — reconcile the checkout, then re-run'
    elif printf '%s' "$mverify" | grep -qiE 'NOT applied|not yet been applied|have not'; then
      esc_reason='additive prod migration is still NOT applied after the post-merge heal (the apply step failed) — re-run once the cause is cleared'
    else
      esc_reason='additive prod migration applied/verify FAILED after merge — check migration status on prod'
    fi
    echo "resolve-ticket #$N: prod migration/verify FAILED — NOT landing ($esc_reason)" >&2
    rt_record_history parked "prod migration failed: $esc_reason"
    exit 7
  fi
  echo "resolve-ticket #$N: prod migration applied + verified" >&2
  MIGRATION_APPLIED=1
elif [[ "$mneeded" == "true" ]]; then
  echo "resolve-ticket #$N: needs an additive prod migration but no merge-repo PR merged this pass — NOT landing (migration would not be applied). Apply it manually, or re-run once a merge-repo PR is merged." >&2
  rt_record_history parked "additive prod migration needed, no merge-repo PR merged"
  exit 6
fi

# ── 4b. Root-scope landing: cherry-pick a worker's meta-worktree commits (scripts/**, governor/**
#    work that has no PR of its own — root paths never route through a sub-repo PR) onto local
#    `main` BEFORE land-resolution.sh runs. Ordering is load-bearing: land-resolution.sh is what
#    deletes the queue block, so a landing failure here must refuse the WHOLE resolve while the
#    ticket is still queued, never delete the block against work that never actually landed.
#
#    A remote-less meta-repo root is a first-class supported state, never a precondition: this
#    lands unconditionally on LOCAL main and pushes ONLY when an origin happens to exist, mirroring
#    land-resolution.sh's own publish guard (`GOVERN_NO_PUSH` + `git remote get-url origin`). ─────
ROOT_SCOPE_LANDED=0
_rs_n="$(jq -r '(.rootScope.commits // []) | length' <<<"$report" 2>/dev/null || echo 0)"
if [[ "${_rs_n:-0}" -gt 0 ]]; then
  git -C "$WS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "resolve-ticket #$N: rootScope.commits reported but $WS_ROOT is not a git repo — NOT landing." >&2
    rt_record_history parked "rootScope: main checkout is not a git repo"
    exit 10
  }
  [[ -z "$(git -C "$WS_ROOT" status --porcelain 2>/dev/null)" ]] || {
    echo "resolve-ticket #$N: rootScope.commits reported but the main checkout has uncommitted changes — NOT landing. Clean it by hand, then re-run." >&2
    rt_record_history parked "rootScope: main checkout dirty"
    exit 10
  }
  _rs_branch="$(git -C "$WS_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [[ "$_rs_branch" == "main" ]] || {
    echo "resolve-ticket #$N: rootScope.commits reported but the main checkout's HEAD is '${_rs_branch:-detached}', not 'main' — NOT landing. Check out main by hand, then re-run." >&2
    rt_record_history parked "rootScope: main checkout not on main"
    exit 10
  }

  _rs_prehead="$(git -C "$WS_ROOT" rev-parse HEAD)"
  declare -a _rs_shas=()
  while IFS= read -r _rs_sha; do [[ -n "$_rs_sha" ]] && _rs_shas+=("$_rs_sha"); done \
    < <(jq -r '.rootScope.commits[]' <<<"$report" 2>/dev/null || true)

  _rs_bad=""
  for _rs_sha in "${_rs_shas[@]}"; do
    if ! git -C "$WS_ROOT" cat-file -e "${_rs_sha}^{commit}" 2>/dev/null; then
      _rs_bad="$_rs_sha (no such commit)"; break
    fi
    _rs_paths="$(git -C "$WS_ROOT" diff-tree --no-commit-id --name-only -r "$_rs_sha" 2>/dev/null || true)"
    while IFS= read -r _rs_p; do
      [[ -n "$_rs_p" ]] || continue
      for _rs_sub in "${REPOS[@]}"; do
        case "$_rs_p" in "$_rs_sub"/*) _rs_bad="$_rs_sha touches sub-repo path $_rs_p"; break 2 ;; esac
      done
    done <<< "$_rs_paths"
    [[ -z "$_rs_bad" ]] || break
  done
  if [[ -n "$_rs_bad" ]]; then
    echo "resolve-ticket #$N: rootScope commit $_rs_bad — only root paths are ever cherry-picked here, never a sub-repo. NOT landing; fix the report and re-run." >&2
    rt_record_history parked "rootScope: bad commit ($_rs_bad)"
    exit 10
  fi

  if ! ( cd "$WS_ROOT" && git cherry-pick -x "${_rs_shas[@]}" ); then
    git -C "$WS_ROOT" cherry-pick --abort >/dev/null 2>&1 || true
    # Narrow rollback, never `reset --hard` a repo this script does not exclusively own — mirrors
    # land-resolution.sh's own sub-repo-lesson rollback (reset --mixed to the captured prehead).
    git -C "$WS_ROOT" reset --mixed "$_rs_prehead" >/dev/null 2>&1 || true
    echo "resolve-ticket #$N: rootScope cherry-pick failed — main checkout rolled back to $_rs_prehead. NOT landing; resolve the conflict by hand, then re-run." >&2
    rt_record_history parked "rootScope: cherry-pick failed"
    exit 10
  fi
  if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git -C "$WS_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WS_ROOT" push origin HEAD:main >/dev/null 2>&1 \
      || echo "resolve-ticket #$N: rootScope commits landed on local main but push to origin failed — reconcile by hand ('git pull --rebase origin main && git push')" >&2
  fi
  ROOT_SCOPE_LANDED=1
  echo "resolve-ticket #$N: rootScope landed ${#_rs_shas[@]} commit(s) onto main" >&2
fi

# ── 4c. Refuse an EMPTY resolve: a report claiming status "resolved" that produced no PR, no
#    landed root-scope commit, no lessonPatch and no applied migration must not bookkeep the ticket
#    off the queue — that would delete the block while nothing about it actually changed. Escape
#    hatch for a genuinely deliberate no-op: GOVERN_ALLOW_EMPTY_RESOLVE=1. ──────────────────────────
_rs_changed=0
# The report's OWN claim, not this script's discovery/verification pipeline: `pr_lines` folds in
# `gh`-verified/discovered PRs (govern::collect_ticket_prs), which can legitimately come back empty
# in an environment that can't reach `gh` even though the worker genuinely reported a PR — that is
# an environment limit, never evidence the resolve was empty.
[[ "$(jq -r '((.pr // null) != null) or ((.prs // []) | length > 0)' <<<"$report" 2>/dev/null || echo false)" == "true" ]] && _rs_changed=1
[[ "$ROOT_SCOPE_LANDED" == "1" ]] && _rs_changed=1
[[ "$(jq -r '.lessonPatch != null' <<<"$report" 2>/dev/null || echo false)" == "true" ]] && _rs_changed=1
[[ "${MIGRATION_APPLIED:-0}" == "1" ]] && _rs_changed=1
if [[ "$_rs_changed" -ne 1 && "${GOVERN_ALLOW_EMPTY_RESOLVE:-0}" != "1" ]]; then
  echo "resolve-ticket #$N: report claims status 'resolved' but nothing actually changed (no PR, no landed root-scope commit, no lessonPatch, no migration) — refusing BEFORE bookkeeping so the ticket stays queued. If this is a deliberate no-op, re-run with GOVERN_ALLOW_EMPTY_RESOLVE=1." >&2
  rt_record_history parked "empty resolve refused: nothing changed"
  exit 11
fi

# ── 5. Land: pipe the report into the EXISTING land-resolution.sh (the real tickets.md edit +
#    commit + BK_LOCK/CAS push). Never reimplemented here.
#
#    A GROUP report (a non-empty `.tickets` array, a worker batched onto one branch/one PR as a
#    named group) lands PER TICKET instead of once: loop the array, and for each entry
#    read govern::batch_ticket_status (fail-closed: "" for a missing entry, an empty array, an
#    absent array, unparseable JSON, or an entry with no status). A "resolved" entry lands via
#    land-resolution.sh for THAT ticket number; "parked"/"failed" record the outcome in ticket
#    history and leave the queue block in place; anything else (including a ticket the array never
#    names) is left untouched too, never a guess at what the worker meant. `newTickets`/
#    `lessonPatch` are group-wide findings the worker states once, so only the PRIMARY ticket's
#    (the $N this script was invoked with) landing call carries them through; every other group
#    member's call gets them stripped so a filed ticket or a promoted lesson is never applied twice
#    for one worker run.
#
#    An EMPTY or absent `.tickets` array is the single-ticket path and lands exactly as it always
#    has: a worker that never named a group must not have to remember to omit the field. ─────────
_group_tickets_n="$(jq -r '(.tickets // []) | length' <<<"$report" 2>/dev/null || echo 0)"
if [[ "${_group_tickets_n:-0}" -gt 0 ]]; then
  _group_stripped_report="$(jq -c '.newTickets = [] | .lessonPatch = null' <<<"$report" 2>/dev/null || echo "$report")"
  while IFS= read -r _gt; do
    [[ "$_gt" =~ ^[0-9]+$ ]] || continue
    _gstatus="$(govern::batch_ticket_status "$report" "$_gt")"
    _gnote="$(govern::batch_ticket_note "$report" "$_gt")"
    case "$_gstatus" in
      resolved)
        _lreport="$_group_stripped_report"
        [[ "$_gt" == "$N" ]] && _lreport="$report"
        if ! printf '%s' "$_lreport" | "$DIR/land-resolution.sh" "$_gt"; then
          echo "resolve-ticket #$N: land-resolution.sh failed for group member #$_gt, ticket NOT bookkept. Check the error above and retry." >&2
          exit 8
        fi
        ;;
      parked|failed)
        echo "resolve-ticket #$N: group member #$_gt reported '$_gstatus', left in the queue" >&2
        rt_record_history "$_gstatus" "${_gnote:-group landing: reported $_gstatus, not resolved}"
        ;;
      *)
        echo "resolve-ticket #$N: group member #$_gt has no explicit 'resolved' entry in the report's tickets array, left in the queue" >&2
        ;;
    esac
  done < <(jq -r '.tickets[].ticket // empty' <<<"$report" 2>/dev/null || true)
else
  if ! printf '%s' "$report" | "$DIR/land-resolution.sh" "$N"; then
    echo "resolve-ticket #$N: land-resolution.sh failed, ticket NOT bookkept. Check the error above and retry." >&2
    exit 8
  fi
fi

# ── 6. Worker-boundary cleanup that belongs wherever a resolution lands: codebase-index refresh
#    + worktree teardown. ─────────────────────────────────────────────────────────────────────
if [[ "${GOVERN_INDEX:-1}" != "0" ]]; then
  "$DIR/codebase-index.sh" build >/dev/null 2>&1 || true
fi
if [[ -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
  # Resolve which worktree we're about to tear down via a NON-destructive registry lookup FIRST, so
  # we can inspect it for unreported commits before rm.sh --force ever runs (the safety net below).
  # Priority: the report's own rootScope.worktree — the ONLY signal available when a root-scope-only
  # ticket has no PR to derive a name from — then the headless convention ticket-$N, then the merged
  # PR's own headRefName. `wt_registry_path_for` fails closed (empty path) when the lookup helper
  # isn't present or the name isn't registered, so this degrades exactly like the old blind-attempt
  # probe did: "not found" here, never a hard error.
  _wt_registry_lib="$WS_ROOT/scripts/worktree/lib/registry.sh"
  [[ -f "$_wt_registry_lib" ]] && source "$_wt_registry_lib"
  _wt_name="$(jq -r '.rootScope.worktree // ""' <<<"$report" 2>/dev/null || true)"
  _wt_path=""
  [[ -n "$_wt_name" ]] && _wt_path="$(wt_registry_path_for "$_wt_name" 2>/dev/null || true)"
  if [[ -z "$_wt_path" ]]; then
    _wt_path="$(wt_registry_path_for "ticket-$N" 2>/dev/null || true)"
    [[ -n "$_wt_path" ]] && _wt_name="ticket-$N"
  fi
  if [[ -z "$_wt_path" ]]; then
    while IFS=$'\t' read -r _wrepo _wnum _wurl; do
      [[ -n "$_wrepo" && -n "$_wnum" ]] || continue
      _cand="$(gh pr view "$_wnum" --repo "$(govern::repo_slug "$_wrepo")" --json headRefName -q '.headRefName' 2>/dev/null || true)"
      [[ -n "$_cand" ]] || continue
      _cand_path="$(wt_registry_path_for "$_cand" 2>/dev/null || true)"
      if [[ -n "$_cand_path" ]]; then _wt_name="$_cand"; _wt_path="$_cand_path"; break; fi
    done <<< "$pr_lines"
  fi

  if [[ -z "$_wt_path" ]]; then
    echo "resolve-ticket #$N: no registered worktree found (checked rootScope.worktree, ticket-$N, and the PR's head branch) — nothing to tear down here; clean up manually if one exists under another name." >&2
  else
    # Safety net: a worker that forgot to report root-scope commits must not lose them silently to
    # the teardown below. Compare the worktree's commits ahead of local main against what
    # rootScope.commits named; leave the worktree INTACT (never --force it) if anything is
    # unaccounted for — the ticket's own resolution already landed above, this only protects
    # whatever ELSE is sitting on that worktree's detached HEAD.
    declare -a _wt_reported=()
    while IFS= read -r _wt_c; do [[ -n "$_wt_c" ]] && _wt_reported+=("$_wt_c"); done \
      < <(jq -r '.rootScope.commits[]?' <<<"$report" 2>/dev/null || true)
    _wt_unreported=""
    if git -C "$_wt_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      while IFS= read -r _wt_sha; do
        [[ -n "$_wt_sha" ]] || continue
        _wt_known=0
        for _wt_c in ${_wt_reported[@]+"${_wt_reported[@]}"}; do
          [[ "$_wt_sha" == "$_wt_c"* ]] && { _wt_known=1; break; }
        done
        [[ "$_wt_known" -eq 1 ]] || _wt_unreported="$_wt_unreported $_wt_sha"
      done < <(git -C "$_wt_path" rev-list main..HEAD 2>/dev/null || true)
    fi
    _wt_unreported="${_wt_unreported# }"
    if [[ -n "$_wt_unreported" ]]; then
      echo "resolve-ticket #$N: worktree '$_wt_name' has commit(s) not reachable from local main and not named in rootScope.commits ($_wt_unreported) — refusing to tear it down. Recover them by hand from $_wt_path, then run 'npm run worktree:rm -- $_wt_name --force' yourself once they're safe." >&2
    else
      ( cd "$WS_ROOT" && bash "$WS_ROOT/scripts/worktree/rm.sh" "$_wt_name" --force >/dev/null 2>&1 ) \
        || echo "resolve-ticket #$N: worktree:rm $_wt_name failed — clean up manually" >&2
    fi
  fi
fi

# ── 7. Record the outcome (govern-health.sh's only input) ──────────────────────────────────────
# Record EVERY PR with its disposition (merged / frontend-left-open / autonomy-left-open) so
# nothing a multi-repo ticket opened is silently dropped from the history row.
_rnote="${PR_DISPOSITIONS:-}"
_rnote="${_rnote# }"
[[ -n "$_rnote" ]] || _rnote="$(printf '%s\n' "$pr_lines" | awk -F'\t' 'NF>=2{printf "%s%s#%s",sep,$1,$2; sep=", "}')"
[[ -n "$_rnote" ]] || _rnote="$(jq -r '.pr.url // ""' <<<"$report" 2>/dev/null || true)"
rt_record_history resolved "$_rnote"

echo "resolve-ticket #$N: landed${_rnote:+ — PRs: $_rnote}" >&2
exit 0
