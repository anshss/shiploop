#!/usr/bin/env bash
# govern-health.sh — governor self-ROI telemetry (#272).
#
# Computes a governor-health summary from the cross-run outcome history
# (governor/ticket-history.jsonl): park rate, self-referential/churn classification, and
# token-per-ticket spend (from the tokenjam-tagged worker token usage folded into each history
# entry by run-loop's record()). Motivated by #115 — a run where most tickets were
# self-referential "port into templates" churn with near-zero product value, discovered only by
# hand. This surfaces that waste class automatically instead of after it has dominated a run.
#
# Usage:
#   <pm> run govern:health                          # human summary: most-recent run + all-time rolling
#   scripts/govern/govern-health.sh --json          # machine-readable {run,allTime}
#   scripts/govern/govern-health.sh --run <run-id>  # scope the "run" block to a specific run
#   scripts/govern/govern-health.sh --last <N>      # scope the "run" block to the last N runs
#
# Env: GOVERN_HISTORY_FILE overrides the history path (tests point it elsewhere).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$DIR/lib/common.sh"
govern::require jq

HISTORY="${GOVERN_HISTORY_FILE:-$GOVERNOR_DIR/ticket-history.jsonl}"

JSON=0 RUN_FILTER="" LAST_N=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1;;
    --run) RUN_FILTER="${2:-}"; shift;;
    --last) LAST_N="${2:-}"; shift;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) govern::die "unknown arg: $1";;
  esac
  shift
done

if [[ ! -s "$HISTORY" ]]; then
  if [[ "$JSON" -eq 1 ]]; then echo '{"historyFile":"'"$HISTORY"'","empty":true}'; else
    echo "Governor health — no history yet ($HISTORY). Run the governor first."; fi
  exit 0
fi

# ── The metrics reducer (jq). Input: an array of OUTCOME entries (validation-evidence pointer rows
# already filtered out). Output: one metrics object — outcome counts + park/resolution rate, churn
# split (over rows that carry a churn classification), and token/cost aggregates (over rows that
# carry token data), split by churn so self-referential spend is visible against product spend.
read -r -d '' METRICS_JQ <<'JQ' || true
def pct($n; $d): if $d > 0 then (100 * $n / $d) else 0 end;
. as $rows
# churn — classified only over rows that shipped a PR (churn == true|false; null = unclassifiable)
| ([$rows[] | select(.churn != null)]) as $cls
| ([$cls[] | select(.churn == true)])  as $self
| ([$cls[] | select(.churn == false)]) as $prod
# tokens — aggregated only over rows that carry token data, split by churn class
| ([$rows[] | select(.tokens != null and (.tokens.total != null))]) as $tk
| ([$tk[] | select(.churn == true)])  as $tks
| ([$tk[] | select(.churn == false)]) as $tkp
| {
  total: ($rows | length),
  runs: ([$rows[].run] | unique | length),
  firstTs: ([$rows[].ts] | min),
  lastTs:  ([$rows[].ts] | max),
  status: {
    resolved: ([$rows[] | select(.status=="resolved")] | length),
    parked:   ([$rows[] | select(.status=="parked")]   | length),
    failed:   ([$rows[] | select(.status=="failed")]   | length),
    timeout:  ([$rows[] | select(.status=="timeout")]  | length)
  }
}
| .parkRatePct       = pct(.status.parked; .total)
| .resolutionRatePct = pct(.status.resolved; .total)
# escalations = every parked or failed outcome (each hands off to the operator via an escalation)
| .escalated = (.status.parked + .status.failed)
| .escalationRatePct = pct(.escalated; .total)
| .churn = {
    classified:  ($cls | length),
    selfRef:     ($self | length),
    product:     ($prod | length),
    selfRefPct:  pct(($self | length); ($cls | length))
  }
| .tokens = {
    withData:     ($tk | length),
    totalTokens:  ([$tk[].tokens.total] | add // 0),
    totalCostUsd: ([$tk[].costUsd | select(. != null)] | add // 0),
    avgTokens:    (if ($tk|length) > 0 then (([$tk[].tokens.total] | add) / ($tk|length)) else 0 end),
    avgCostUsd:   (if ($tk|length) > 0 then (([$tk[].costUsd | select(.!=null)] | add // 0) / ($tk|length)) else 0 end),
    selfRefAvgTokens: (if ($tks|length) > 0 then (([$tks[].tokens.total] | add) / ($tks|length)) else null end),
    productAvgTokens: (if ($tkp|length) > 0 then (([$tkp[].tokens.total] | add) / ($tkp|length)) else null end),
    selfRefTotalCostUsd: ([$tks[].costUsd | select(.!=null)] | add // 0),
    productTotalCostUsd: ([$tkp[].costUsd | select(.!=null)] | add // 0)
  }
JQ

# Build the two scoped arrays (as a single JSON with .allTime + .run) then run the reducer on each.
# OUTCOME rows = history entries WITHOUT a `kind` (the `kind:"validation-evidence"` rows are #252
# evidence POINTERS, not outcomes — counting them would double-count resolves).
scoped="$(jq -s \
  --arg runf "$RUN_FILTER" --arg lastn "$LAST_N" '
  ( map(select(.kind == null and (.status|type=="string"))) ) as $all
  # ordered unique run ids (first-seen order) → the last-N-runs window
  | ( [ $all[].run ] | reduce .[] as $r ([]; if index($r) then . else . + [$r] end) ) as $runorder
  | ( if $lastn != "" then ($runorder[-($lastn|tonumber):]) else null end ) as $lastruns
  | {
      all: $all,
      scope: (
        if $runf  != "" then [ $all[] | select(.run == $runf) ]
        elif $lastn != "" then [ $all[] | select(.run as $r | $lastruns | index($r)) ]
        else [ $all[] | select(.run == ($runorder[-1])) ]        # default: most-recent run
        end),
      scopeLabel: (
        if $runf  != "" then ("run " + $runf)
        elif $lastn != "" then ("last " + $lastn + " run(s)")
        else ("most recent run: " + ($runorder[-1] // "n/a"))
        end)
    }' "$HISTORY")"

all_m="$(jq -c '.all'   <<<"$scoped" | jq "$METRICS_JQ")"
run_m="$(jq -c '.scope' <<<"$scoped" | jq "$METRICS_JQ")"
run_label="$(jq -r '.scopeLabel' <<<"$scoped")"

if [[ "$JSON" -eq 1 ]]; then
  jq -nc --argjson run "$run_m" --argjson all "$all_m" --arg label "$run_label" --arg hf "$HISTORY" \
    '{historyFile:$hf, scopeLabel:$label, run:$run, allTime:$all}'
  exit 0
fi

# ── Human render ─────────────────────────────────────────────────────────────
fmt_tokens() { # integer -> "1.2M" / "34.5k" / "812"
  awk -v n="${1:-0}" 'BEGIN{
    if (n>=1000000) printf "%.1fM", n/1000000;
    else if (n>=1000) printf "%.1fk", n/1000;
    else printf "%d", n }'
}
render() { # metrics-json  header
  local m="$1" hdr="$2"
  local total res park fail to prate rrate erate
  total="$(jq -r '.total' <<<"$m")"
  res="$(jq -r '.status.resolved' <<<"$m")"; park="$(jq -r '.status.parked' <<<"$m")"
  fail="$(jq -r '.status.failed' <<<"$m")"; to="$(jq -r '.status.timeout' <<<"$m")"
  prate="$(jq -r '.parkRatePct|.*10|round/10' <<<"$m")"
  rrate="$(jq -r '.resolutionRatePct|.*10|round/10' <<<"$m")"
  erate="$(jq -r '.escalationRatePct|.*10|round/10' <<<"$m")"
  printf '%s (%s outcome record(s) over %s run(s))\n' "$hdr" "$total" "$(jq -r '.runs' <<<"$m")"
  if [[ "${total:-0}" -eq 0 ]]; then printf '  (no outcomes in scope)\n\n'; return; fi
  printf '  outcomes : ✅ %s resolved · ⏸ %s parked · ✖ %s failed · ⏱ %s timeout\n' "$res" "$park" "$fail" "$to"
  printf '  park rate: %s%%   resolution: %s%%   escalation (parked+failed): %s%%\n' "$prate" "$rrate" "$erate"
  # churn
  local ccl cself cprod cspct
  ccl="$(jq -r '.churn.classified' <<<"$m")"; cself="$(jq -r '.churn.selfRef' <<<"$m")"
  cprod="$(jq -r '.churn.product' <<<"$m")"; cspct="$(jq -r '.churn.selfRefPct|.*10|round/10' <<<"$m")"
  if [[ "${ccl:-0}" -gt 0 ]]; then
    printf '  churn    : %s%% self-referential (harness/templates) — %s self-ref vs %s product, over %s PR-shipping ticket(s)\n' \
      "$cspct" "$cself" "$cprod" "$ccl"
  else
    printf '  churn    : (no PR-classified outcomes in scope yet)\n'
  fi
  # tokens
  local twd ttot tcost tavg tcavg tspa tppa
  twd="$(jq -r '.tokens.withData' <<<"$m")"
  if [[ "${twd:-0}" -gt 0 ]]; then
    ttot="$(fmt_tokens "$(jq -r '.tokens.totalTokens' <<<"$m")")"
    tcost="$(jq -r '.tokens.totalCostUsd|.*100|round/100' <<<"$m")"
    tavg="$(fmt_tokens "$(jq -r '.tokens.avgTokens|round' <<<"$m")")"
    tcavg="$(jq -r '.tokens.avgCostUsd|.*100|round/100' <<<"$m")"
    printf '  tokens   : %s total / $%s   ·   avg %s tok ($%s) per ticket (over %s ticket(s) with token data)\n' \
      "$ttot" "$tcost" "$tavg" "$tcavg" "$twd"
    tspa="$(jq -r '.tokens.selfRefAvgTokens' <<<"$m")"; tppa="$(jq -r '.tokens.productAvgTokens' <<<"$m")"
    if [[ "$tspa" != "null" || "$tppa" != "null" ]]; then
      local sa pa sc pc
      [[ "$tspa" == "null" ]] && sa="n/a" || sa="$(fmt_tokens "$(printf '%.0f' "$tspa")")"
      [[ "$tppa" == "null" ]] && pa="n/a" || pa="$(fmt_tokens "$(printf '%.0f' "$tppa")")"
      sc="$(jq -r '.tokens.selfRefTotalCostUsd|.*100|round/100' <<<"$m")"
      pc="$(jq -r '.tokens.productTotalCostUsd|.*100|round/100' <<<"$m")"
      printf '           : self-ref avg %s tok ($%s total) · product avg %s tok ($%s total)\n' "$sa" "$sc" "$pa" "$pc"
    fi
  else
    printf '  tokens   : (no token data in scope yet — populated going forward as workers finish)\n'
  fi
  printf '\n'
}

echo "════════ Governor health (ROI telemetry · #272) ════════"
render "$run_m" "▸ $run_label"
render "$all_m" "▸ all-time rolling"
echo "history: $HISTORY   ·   detail: scripts/govern/govern-health.sh --json"
