#!/usr/bin/env bash
# Poll a PR's CI. Usage: await-ci.sh <repo> <pr-number>
# Prints ONE outcome token; the exit code encodes whether the CI state is VERIFIED:
#   green   (exit 0) — every check passed.
#   red     (exit 0) — at least one check failing/cancelled.
#   pending (exit 0) — checks still running after GOVERN_CI_MAX_TRIES polls.
#   none    (exit 0) — VERIFIED checkless: `gh pr checks` was empty for
#                      GOVERN_CI_NONE_CONSEC consecutive polls AND a SECOND independent
#                      signal (`gh pr view --json statusCheckRollup`) also came back
#                      empty with gh exiting cleanly. Only then is a checkless PR
#                      auto-mergeable (some workspaces deploy post-merge, so a repo
#                      with genuinely no PR-level checks is still a valid mergeable state).
#   error   (exit 3) — CI state UNVERIFIABLE. `gh` failed to return parseable JSON
#                      (network / auth / rate-limit / GitHub 5xx) for GOVERN_CI_ERR_MAX
#                      consecutive polls, OR the none-verification call itself failed.
#                      FAIL-CLOSED: a gh error is NOT conflated with "no checks" — the
#                      caller must PARK (never merge) on 'error' (root cause of the
#                      pre-#34b fail-open: `… 2>/dev/null || echo '[]'` made a broken gh
#                      look identical to a checkless repo and auto-merged un-tested PRs).
# Tunables: GOVERN_CI_MAX_TRIES (60), GOVERN_CI_INTERVAL secs (30),
#           GOVERN_CI_NONE_GRACE secs (6) slept between consecutive-empty polls,
#           GOVERN_CI_NONE_CONSEC (2) consecutive empties before we VERIFY 'none',
#           GOVERN_CI_ERR_MAX (3) consecutive gh errors before we conclude 'error'.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require gh; govern::require jq

REPO="${1:?repo required}"; PR="${2:?pr number required}"
SLUG="$(govern::repo_slug "$REPO")"
MAX="${GOVERN_CI_MAX_TRIES:-60}"; INTERVAL="${GOVERN_CI_INTERVAL:-30}"
NONE_GRACE="${GOVERN_CI_NONE_GRACE:-6}"     # secs between empty polls (so checks can register)
NONE_CONSEC="${GOVERN_CI_NONE_CONSEC:-2}"   # consecutive empties required before verifying 'none'
ERR_MAX="${GOVERN_CI_ERR_MAX:-3}"           # consecutive gh errors before concluding 'error'
EXIT_ERROR=3

# Query a PR's check buckets. On success sets REPLY to the JSON array and returns 0.
# On ANY gh failure to yield parseable JSON, returns 1 (a REAL error) — deliberately NOT
# conflated with a genuinely-empty '[]', which is the whole point of this fail-closed rewrite.
fetch_checks() {
  local out
  set +e; out="$(gh pr checks "$PR" --repo "$SLUG" --json bucket 2>/dev/null)"; set -e
  jq -e . >/dev/null 2>&1 <<<"$out" || return 1
  REPLY="$out"; return 0
}

# Second, independent confirmation that a PR is TRULY checkless. Prints:
#   empty  — statusCheckRollup came back empty with gh clean → verified no checks.
#   checks — rollup is NON-empty (checks exist but `pr checks` hasn't registered their
#            buckets yet: fresh-PR registration lag) → keep polling, do NOT conclude 'none'.
#   error  — gh failed to return parseable JSON → state unverifiable.
verify_checkless() {
  local out len
  set +e; out="$(gh pr view "$PR" --repo "$SLUG" --json statusCheckRollup 2>/dev/null)"; set -e
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$out" || { echo error; return; }
  len="$(jq '(.statusCheckRollup // []) | length' <<<"$out" 2>/dev/null || echo -1)"
  if [[ "$len" == "0" ]]; then echo empty; else echo checks; fi
}

tries=0; none_seen=0; err_seen=0
while :; do
  if ! fetch_checks; then
    # gh could not return parseable JSON → genuine error, NOT "no checks". Fail closed.
    err_seen=$((err_seen+1)); none_seen=0
    if [[ "$err_seen" -ge "$ERR_MAX" ]]; then
      govern::log "await-ci: gh pr checks failed to return JSON ${err_seen}× on $REPO#$PR — CI state UNVERIFIABLE (error)"
      echo "error"; exit "$EXIT_ERROR"
    fi
    sleep "$NONE_GRACE"; continue
  fi
  err_seen=0
  json="$REPLY"
  total="$(jq 'length' <<<"$json")"
  fails="$(jq '[.[]|select(.bucket=="fail" or .bucket=="cancel")]|length' <<<"$json")"
  pend="$(jq '[.[]|select(.bucket=="pending")]|length' <<<"$json")"

  if [[ "$total" -eq 0 ]]; then
    none_seen=$((none_seen+1))
    if [[ "$none_seen" -ge "$NONE_CONSEC" ]]; then
      # An empty `gh pr checks` alone is NOT sufficient to auto-merge (#34b). Confirm with a
      # second independent signal before concluding the repo is genuinely checkless.
      case "$(verify_checkless)" in
        empty) echo "none"; exit 0 ;;
        checks)
          # rollup HAS checks `pr checks` hasn't registered yet (fresh-PR lag) → treat as pending.
          none_seen=0; tries=$((tries+1))
          if [[ "$tries" -ge "$MAX" ]]; then echo "pending"; exit 0; fi
          govern::log "CI check-registration lag on $REPO#$PR (rollup non-empty, buckets empty) — sleeping ${INTERVAL}s (try $tries/$MAX)"
          sleep "$INTERVAL"; continue ;;
        *)
          govern::log "await-ci: none-verification (statusCheckRollup) failed on $REPO#$PR — CI state UNVERIFIABLE (error)"
          echo "error"; exit "$EXIT_ERROR" ;;
      esac
    fi
    sleep "$NONE_GRACE"; continue
  fi
  none_seen=0
  if [[ "$fails" -gt 0 ]]; then echo "red"; exit 0; fi
  if [[ "$pend" -eq 0 ]]; then echo "green"; exit 0; fi

  tries=$((tries+1))
  if [[ "$tries" -ge "$MAX" ]]; then echo "pending"; exit 0; fi
  govern::log "CI pending on $REPO#$PR ($pend pending) — sleeping ${INTERVAL}s (try $tries/$MAX)"
  sleep "$INTERVAL"
done
