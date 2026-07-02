#!/usr/bin/env bash
# Poll a PR's CI. Usage: await-ci.sh <repo> <pr-number>
# Prints one of: green | red | pending | none   (and exits 0 in all those cases).
# Tunables: GOVERN_CI_MAX_TRIES (default 60), GOVERN_CI_INTERVAL secs (default 30).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require gh; govern::require jq

REPO="${1:?repo required}"; PR="${2:?pr number required}"
MAX="${GOVERN_CI_MAX_TRIES:-60}"; INTERVAL="${GOVERN_CI_INTERVAL:-30}"

GRACE="${GOVERN_CI_NONE_GRACE:-6}"   # require 2 consecutive empties before concluding "none",
tries=0; none_seen=0                  # so we don't read "none" before checks have registered.
while :; do
  json="$(gh pr checks "$PR" --repo "$(govern::repo_slug "$REPO")" --json bucket 2>/dev/null || echo '[]')"
  total="$(jq 'length' <<<"$json")"
  fails="$(jq '[.[]|select(.bucket=="fail" or .bucket=="cancel")]|length' <<<"$json")"
  pend="$(jq '[.[]|select(.bucket=="pending")]|length' <<<"$json")"

  if [[ "$total" -eq 0 ]]; then
    none_seen=$((none_seen+1))
    if [[ "$none_seen" -ge 2 ]]; then echo "none"; exit 0; fi
    sleep "$GRACE"; continue
  fi
  none_seen=0
  if [[ "$fails" -gt 0 ]]; then echo "red"; exit 0; fi
  if [[ "$pend" -eq 0 ]]; then echo "green"; exit 0; fi

  tries=$((tries+1))
  if [[ "$tries" -ge "$MAX" ]]; then echo "pending"; exit 0; fi
  govern::log "CI pending on $REPO#$PR ($pend pending) — sleeping ${INTERVAL}s (try $tries/$MAX)"
  sleep "$INTERVAL"
done
