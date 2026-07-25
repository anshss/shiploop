#!/usr/bin/env bash
# #49: run-start preflight — refuse to dispatch a wave of workers onto an unambiguously CI-red
# base branch. MEASURED: ticket #46 was dispatched while main was CI-red; its PR (a one-line
# markdown change that could not possibly have failed the suite) inherited the broken baseline,
# went red, and was recorded 'failed' — after a full worker session. Under --parallel (the
# default), a red baseline fails EVERY concurrent worker in the wave, not just one ticket. A
# `gh run list` costs one API call and no tokens, so check it BEFORE spawning anything rather than
# discovering the break the most expensive way (await-ci.sh, after N workers each opened a PR).
#
# Checks the latest completed run on the base branch for every repo this run could dispatch into
# (GOVERN_MERGE_REPOS + GOVERN_FRONTEND_REPOS — the full harness repo universe; ticket selection
# hasn't happened yet at this point in the run, so every repo is in scope). Prints the failing run
# URL(s) and exits 2 ONLY when a repo's base branch is unambiguously red (a completed run whose
# conclusion is "failure"). Exits 0 (fail-open) on everything else: gh missing, gh unauthenticated,
# no workflows configured, no runs yet, an in-progress/queued run (conclusion null), or a gh/API
# error — none of those are evidence of a red baseline, and this check must never block a fleet
# whose CI is simply absent (the harness's own "green-or-no-checks" merge policy already treats a
# checkless repo as mergeable; this check stays consistent with it).
#
# GOVERN_SKIP_BASE_CHECK=1 opts out entirely (e.g. the ticket being worked IS the fix for the red
# CI). GOVERN_BASE_BRANCH overrides the branch name (default "main", matching preflight-main.sh's
# existing assumption elsewhere in this lane).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

if [[ "${GOVERN_SKIP_BASE_CHECK:-0}" == "1" ]]; then
  govern::log "preflight: GOVERN_SKIP_BASE_CHECK=1 — skipping base-branch CI check"
  exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
  govern::log "preflight: gh not found — skipping base-branch CI check (fail-open)"
  exit 0
fi

BRANCH="${GOVERN_BASE_BRANCH:-main}"
seen=","
for repo in ${GOVERN_MERGE_REPOS:-} ${GOVERN_FRONTEND_REPOS:-}; do
  [[ -n "$repo" ]] || continue
  case "$seen" in *",$repo,"*) continue;; esac
  seen="$seen$repo,"
  slug="$(govern::repo_slug "$repo" 2>/dev/null || true)"
  [[ -n "$slug" ]] || continue

  json="$(gh run list --repo "$slug" --branch "$BRANCH" --limit 1 --json conclusion,status,url 2>/dev/null || true)"
  if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
    govern::log "preflight: base-CI check on $slug#$BRANCH — gh error/no response, proceeding (fail-open)"
    continue
  fi
  n="$(jq 'length' <<<"$json" 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -eq 0 ]]; then
    govern::log "preflight: base-CI check on $slug#$BRANCH — no runs found (CI absent or none yet), proceeding (fail-open)"
    continue
  fi
  status="$(jq -r '.[0].status // ""' <<<"$json" 2>/dev/null)"
  conclusion="$(jq -r '.[0].conclusion // ""' <<<"$json" 2>/dev/null)"
  url="$(jq -r '.[0].url // ""' <<<"$json" 2>/dev/null)"

  if [[ "$status" == "completed" && "$conclusion" == "failure" ]]; then
    govern::log "preflight: base branch $slug#$BRANCH is CI-RED ($url) — refusing to dispatch this run (#49). Fix it first (or dispatch the ticket that fixes it), or set GOVERN_SKIP_BASE_CHECK=1 to proceed anyway."
    exit 2
  fi
  govern::log "preflight: base-CI check on $slug#$BRANCH — status=${status:-none} conclusion=${conclusion:-none} (not an unambiguous red; proceeding)"
done

exit 0
