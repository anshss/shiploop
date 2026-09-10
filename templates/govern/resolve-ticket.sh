#!/usr/bin/env bash
# resolve-ticket.sh — the SESSION-SIDE resolve path for ticket N (shiploop 1.19.2, the loop purge).
#
# Before this script, the ONLY thing that landed a resolution was the autonomous loop
# (run-loop.sh): it awaited CI, merged the PR, then piped the worker's report into the bookkeep
# script. A worker in the interactive model stops at PR-open plus a report, so nothing finished
# the job for a plain Claude Code session. This script is that missing step: hand it the exact
# report a worker (headless or interactive) produced, and it awaits CI, merges, applies the prod
# migration if one is needed, and lands the ticket exactly the way the loop used to.
#
# Usage:  printf '%s' "$report" | resolve-ticket.sh <N> [--no-merge]
#   <N>          the ticket number.
#   --no-merge   skip the CI-await + merge steps for a PR the OPERATOR already merged (or
#                deliberately left open) by hand — go straight to landing.
#   stdin        the worker's JSON report — the EXACT shape land-resolution.sh consumes:
#                .pr, .prs[], .status, .lessonPatch, .newTickets[], .validation.*
#                Accepted `.pr` shapes (#120 — an ambiguous contract once let a present-but-
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
#   2. Normalize `.pr` into {repo,number,url}, or REFUSE (#120): a `.pr` that is present but not
#      one of the accepted shapes (see the stdin contract above) must never fall through to the
#      "no PR" path — that silent fall-through once deleted a queue block while the PR sat open,
#      unmerged. This runs BEFORE any bookkeeping, so a refusal here leaves tickets.md untouched.
#   3. PR-hygiene backstop: strip a leaked internal #N reference from the PR's title/body, and warn
#      if a Claude spec/plan artifact leaked into the diff. Ported from run-loop.sh's per-ticket
#      PR-hygiene block; scoped, like the original, to the single reported .pr (not every PR a
#      multi-repo ticket opened).
#   4. The validation-evidence gate (#67 no live-test evidence / #73 gate measured a negative):
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
#      A refusal is not a failure of this script, it is information: the interactive session (or the
#      operator) decides what to do next, then re-runs this script (plain, once the refusal clears,
#      or with --no-merge once they handled it by hand).
#   6. If the report needs a prod migration, apply it via GOVERN_MIGRATE_CMD the way run-loop.sh
#      did (same destructive-migration refusal, same local-first neutralization, same
#      apply-then-verify-then-classify-the-failure shape).
#   7. Only once every PR is merged (or --no-merge) and the migration step (if any) succeeded:
#      pipe the report into land-resolution.sh <N> — the actual tickets.md edit + commit + push.
#   8. Worker-boundary cleanup that belongs wherever a worker's resolution actually lands: refresh
#      the codebase index (§4.3, GOVERN_INDEX) and tear down the ticket's worktree.
#   9. Record the outcome into ticket-history.jsonl (govern-health.sh's only input), preserving the
#      exact JSON shape run-loop.sh's record()/history_enrich() wrote.
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

# ── Normalize/validate the reported `.pr` shape, or REFUSE (#120) ──────────────────────────────
# A present-but-unparseable `.pr` (a bare integer, a malformed object, any other shape) used to
# fall through to the SAME branch as a genuinely PR-less report, and that branch LANDS — deleting
# the queue block while the real PR sat open, unmerged, with only a stderr line as the signal. This
# runs BEFORE any bookkeeping (no ticket-history write, no land-resolution.sh call), so a refusal
# here leaves tickets.md byte-identical. See the stdin contract at the top of this file for the
# accepted `.pr` shapes.
_norm_report="$(govern::normalize_pr_field "$report")" && report="$_norm_report" || {
  echo "resolve-ticket #$N: .pr is present but not one of the accepted shapes (an object {repo,number,url}, or a bare integer PR number a configured repo has open) — refusing BEFORE any bookkeeping rather than silently landing as 'no PR' (#120). Fix the report's .pr field and re-run." >&2
  exit 9
}

# ── ticket-history.jsonl writer (§B3) ───────────────────────────────────────────────────────────
# Mirrors run-loop.sh's record()/history_enrich() exactly (same JSON shape: {ticket,run,status,ts}
# plus tokens/costUsd/model/effort/attempt/usageSource/churn/repos) so govern-health.sh — which
# reads ONLY this file — keeps an input now that the loop no longer writes it. "run" falls back to
# "manual" exactly like land-resolution.sh's own --source string does when GOVERN_RUN_DIR is unset.
rt_history_enrich() { # -> json extra fields (tokens/costUsd/model/effort/attempt/usageSource/churn/repos)
  local logdir jsonl attempts_file extra
  logdir="$(govern::worker_logdir "$N")"
  jsonl="$logdir/worker.jsonl"
  attempts_file="$logdir/attempts.jsonl"
  extra='{}'
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
    extra="$(govern::stream_usage "$jsonl" 2>/dev/null || echo '{}')"
  fi
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

# ── 1. PR-hygiene backstop (ported from run-loop.sh:1427-1453) ─────────────────────────────────
# Scoped to the single reported .pr, exactly like the original — a multi-repo ticket's OTHER PRs
# are handled by the merge loop below, not by this scrub.
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

# ── 2. The #67/#73 validation-evidence gate (ported from run-loop.sh:1455-1500) ────────────────
tblock="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
if govern::is_validation_ticket "$tblock"; then
  case "$(govern::validation_gate_action "$report")" in
    park-no-evidence)
      echo "resolve-ticket #$N: VALIDATION ticket but the worker gave no live-test evidence (validation.ranLiveTest != true, or no evidence) — refusing to auto-resolve (#67 gate). Run the actual test and attach evidence, or confirm it cannot be automated and record a disposition. The PR (if any) is left open for review." >&2
      rt_record_history parked "validation gate: no live-test evidence (#67)"
      exit 3
      ;;
    park-gate-failed)
      echo "resolve-ticket #$N: VALIDATION ticket whose gate FAILED (validation.gatePassed == false) — refusing to auto-ship a measured-NEGATIVE result (#73 gate). Decide kill / ship-default-off / shelve / rework yourself; do not let a worker self-decide. The PR (if any) is left open for review." >&2
      rt_record_history parked "validation gate: measured negative (#73)"
      exit 3
      ;;
  esac
fi

# ── 3. Await CI + merge every PR the report names (ported from run-loop.sh's per-PR merge walk,
#    B1 steps 2-3). merge-pr.sh calls await-ci.sh internally — never reimplemented here. ────────
pr_lines="$(govern::collect_ticket_prs "$N" "$report")"
MERGE_REPO_MERGED=0
if [[ "$NO_MERGE" -eq 1 ]]; then
  echo "resolve-ticket #$N: --no-merge — skipping CI/merge (operator already handled it), landing directly" >&2
  MERGE_REPO_MERGED=1
elif [[ -n "$pr_lines" ]]; then
  # Two DIFFERENT non-zero classes, exactly as the loop drew the line (#129, #autonomy):
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
        echo "resolve-ticket #$N: $_mrepo#$_mnum left open (frontend is PR-only) [#129], surfaced, not merged; merge it yourself when ready." >&2
        PR_DISPOSITIONS="$PR_DISPOSITIONS $_mrepo#$_mnum(frontend-left-open)"
        ;;
      6)
        echo "resolve-ticket #$N: $_mrepo#$_mnum left open, GOVERN_AUTONOMY=$(govern::autonomy) (the governor opens PRs, it does not auto-merge; flip to auto to enable) [autonomy]" >&2
        PR_DISPOSITIONS="$PR_DISPOSITIONS $_mrepo#$_mnum(autonomy-left-open)"
        ;;
      3) echo "resolve-ticket #$N: $_mrepo#$_mnum refused — CI is red or still pending. Fix CI (or wait for it), then re-run resolve-ticket." >&2; ALL_MERGED=0 ;;
      4) echo "resolve-ticket #$N: $_mrepo#$_mnum refused — CI state could not be verified (gh network/auth/rate-limit/5xx). Investigate, then re-run." >&2; ALL_MERGED=0 ;;
      5) echo "resolve-ticket #$N: $_mrepo#$_mnum refused — external-PR safety guard blocked it (not this governor's own PR/branch). Merge it by hand via gh/web if trusted, then re-run with --no-merge." >&2; ALL_MERGED=0 ;;
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

# ── 4. Prod migration (ported from run-loop.sh:1630-1679, same destructive refusal + local-first
#    neutralization + apply-then-verify-then-classify shape) ───────────────────────────────────
mneeded="$(jq -r '.migration.needed // false' <<<"$report" 2>/dev/null || echo false)"
mdestr="$(jq -r '.migration.destructive // false' <<<"$report" 2>/dev/null || echo false)"

if [[ "$mneeded" == "true" && "$mdestr" != "true" && -n "$pr_lines" ]]; then
  _all_localfirst=1
  while IFS=$'\t' read -r _lfr _lfp _lfu; do
    [[ -n "$_lfr" ]] || continue
    govern::is_local_first_repo "$_lfr" || { _all_localfirst=0; break; }
  done <<< "$pr_lines"
  if [[ "$_all_localfirst" == "1" ]]; then
    echo "resolve-ticket #$N: additive migration ships as auto-applying code on local-first repo(s) — no prod apply needed; proceeding as a normal resolve (#72)" >&2
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
elif [[ "$mneeded" == "true" ]]; then
  echo "resolve-ticket #$N: needs an additive prod migration but no merge-repo PR merged this pass — NOT landing (migration would not be applied). Apply it manually, or re-run once a merge-repo PR is merged." >&2
  rt_record_history parked "additive prod migration needed, no merge-repo PR merged"
  exit 6
fi

# ── 5. Land: pipe the report into the EXISTING land-resolution.sh (the real tickets.md edit +
#    commit + BK_LOCK/CAS push). Never reimplemented here. ─────────────────────────────────────
if ! printf '%s' "$report" | "$DIR/land-resolution.sh" "$N"; then
  echo "resolve-ticket #$N: land-resolution.sh failed — ticket NOT bookkept. Check the error above and retry." >&2
  exit 8
fi

# ── 6. Worker-boundary cleanup that belongs wherever a resolution lands (ported from
#    run-loop.sh:1707-1720): codebase-index refresh + worktree teardown. ───────────────────────
if [[ "${GOVERN_INDEX:-1}" != "0" ]]; then
  "$DIR/codebase-index.sh" build >/dev/null 2>&1 || true
fi
if [[ -z "${GOVERN_WORKTREE_CMD:-}" ]]; then
  ( cd "$WS_ROOT" && bash "$WS_ROOT/scripts/worktree/rm.sh" "ticket-$N" --force >/dev/null 2>&1 ) \
    || echo "resolve-ticket #$N: worktree:rm ticket-$N failed — clean up manually" >&2
fi

# ── 7. Record the outcome (govern-health.sh's only input) ──────────────────────────────────────
# #129: record EVERY PR with its disposition (merged / frontend-left-open / autonomy-left-open) so
# nothing a multi-repo ticket opened is silently dropped from the history row.
_rnote="${PR_DISPOSITIONS:-}"
_rnote="${_rnote# }"
[[ -n "$_rnote" ]] || _rnote="$(printf '%s\n' "$pr_lines" | awk -F'\t' 'NF>=2{printf "%s%s#%s",sep,$1,$2; sep=", "}')"
[[ -n "$_rnote" ]] || _rnote="$(jq -r '.pr.url // ""' <<<"$report" 2>/dev/null || true)"
rt_record_history resolved "$_rnote"

echo "resolve-ticket #$N: landed${_rnote:+ — PRs: $_rnote}" >&2
exit 0
