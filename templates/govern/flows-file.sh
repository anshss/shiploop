#!/usr/bin/env bash
# File governor validation tickets for selected flows (validations Phase 4, `/shiploop:flows file`).
# THE spend gate — filing a flow queues a real, often BILLABLE, deploy, so this is deliberately
# conservative:
#   • DRY BY DEFAULT — prints the plan (which tickets, estimated provisions) and files NOTHING unless
#     --yes is passed. "Never auto-file; filing is a human act" (design). Staleness is advisory.
#   • Resource-group batching — flows sharing a `Resource-group:` are filed as ONE ticket carrying a
#     comma-list `Flow:` field, so one worker + one deploy validates them all (the 9×{deploy,comfyui,
#     migration} matrix costs ~9 provisions, not ~27).
#   • BLOCKED flows are excluded (a named blocker can't be validated headlessly).
#   • In-flight guard — a flow that already has an OPEN Flow: ticket is skipped (semantic dedupe on top
#     of file-ticket's CAS).
#   • --all-* preconditions — batch filing refuses unless GOVERN_DEPLOY_SWEEP_CMD is wired (the orphan
#     sweep is the safety net on the harness's highest-spend path).
#   • Cheapest/fastest-first ordering + --max-deploys N — a truncated governor run still maximizes
#     coverage; slow-provision flows (near GOVERN_WORKER_TIMEOUT) are flagged.
#
# Usage:
#   scripts/govern/flows-file.sh <id[,id…]|--all-stale|--all-untested> [--max-deploys N] [--yes]
# Exit 0 on a clean plan/file; exit 2 on a precondition refusal (nothing filed).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
command -v govern::flow_ids >/dev/null 2>&1 || govern::die "flow parser (flows.sh) unavailable — upgrade the harness"

sel_mode="ids"; sel_ids=""; max_deploys=0; do_file=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-stale)     sel_mode="all-stale"; shift ;;
    --all-untested)  sel_mode="all-untested"; shift ;;
    --max-deploys)   max_deploys="${2:?--max-deploys needs N}"; shift 2 ;;
    --yes)           do_file=1; shift ;;
    --*)             govern::die "unknown flag: $1" ;;
    *)               sel_ids="${sel_ids:+$sel_ids }${1//,/ }"; shift ;;
  esac
done

META="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"
FLOWS="${GOVERN_FLOWS_FILE:-$META/.claude/shiploop/validation/flows.md}"
[[ -f "$FLOWS" ]] || govern::die "no flow registry at $FLOWS"
TIMEOUT="${GOVERN_WORKER_TIMEOUT:-3600}"

# ── --all-* precondition: refuse batch filing without the orphan-sweep safety net ──────────────────
if [[ "$sel_mode" != "ids" && -z "${GOVERN_DEPLOY_SWEEP_CMD:-}" ]]; then
  printf 'REFUSING %s — batch filing queues N billable deploys but GOVERN_DEPLOY_SWEEP_CMD is not wired.\n' "$sel_mode" >&2
  printf 'The post-worker orphan sweep is the safety net on the highest-spend path. Wire it in\n' >&2
  printf 'scripts/lib/workspace.sh, or file specific ids explicitly (which you accept the spend for).\n' >&2
  exit 2
fi

# ── Resolve the candidate set ──────────────────────────────────────────────────────────────────────
candidates=""
if [[ "$sel_mode" == "ids" ]]; then
  [[ -n "$sel_ids" ]] || govern::die "no flow ids given (or use --all-stale / --all-untested)"
  for id in $sel_ids; do
    govern::flow_exists "$id" "$FLOWS" || { govern::log "flows-file: '$id' not in the registry — skipping"; continue; }
    candidates="${candidates:+$candidates }$id"
  done
else
  want="STALE"; [[ "$sel_mode" == "all-untested" ]] && want="UNTESTED"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(govern::flow_field "$id" Status "$FLOWS")" == "$want" ]] && candidates="${candidates:+$candidates }$id"
  done < <(govern::flow_ids "$FLOWS")
fi

# Exclude BLOCKED, and apply the in-flight guard (a flow already carried by an OPEN Flow: ticket).
# `|| true` on the whole pipeline: an empty tickets.md yields no Flow: lines and grep exits 1, which
# under set -e/pipefail would abort — a no-match here is normal (nothing in flight), not an error.
inflight=" $( { grep -hInE '^[[:space:]]*[-*]?[[:space:]]*\**[Ff]low:' "$TICKETS_FILE" 2>/dev/null \
  | sed -E 's/^[^:]*:[^:]*://; s/^[[:space:]]*[-*]?[[:space:]]*\**[Ff]low:\**[[:space:]]*//' \
  | tr ',' ' ' | tr -s ' \t' '  ' | tr ' ' '\n' | grep . | tr '\n' ' '; } || true) "
filtered=""
excluded_blocked=""; excluded_inflight=""; newly_blocked=""
for id in $candidates; do
  if [[ "$(govern::flow_field "$id" Status "$FLOWS")" == "BLOCKED" ]]; then
    excluded_blocked="${excluded_blocked:+$excluded_blocked }$id"; continue
  fi
  # Capability gate (Phase 5): a flow that `Requires:` a workspace capability whose knob is UNSET can't
  # be validated headlessly — filing it would queue a runnable-then-billable ticket that only parks with
  # no evidence. Degrade it to BLOCKED with the NAMED blocker (anti-pattern #15) and exclude it, rather
  # than filing. No-op when the flow declares no `Requires:` or every required knob is wired.
  if command -v govern::flow_missing_cap_blocker >/dev/null 2>&1; then
    _cap_blocker="$(govern::flow_missing_cap_blocker "$id" "$FLOWS" 2>/dev/null || true)"
    if [[ -n "$_cap_blocker" ]]; then
      _bid="$id" _bmsg="$_cap_blocker"
      _flows_cap_block_edit() { # <flows-file>
        govern::flow_set_field "$_bid" Status  BLOCKED "$1"
        govern::flow_set_field "$_bid" Blocker "$_bmsg" "$1"
      }
      govern::cas_edit "$FLOWS" _flows_cap_block_edit "docs(flows): $id BLOCKED — $_cap_blocker" 2>/dev/null || true
      unset -f _flows_cap_block_edit
      newly_blocked="${newly_blocked:+$newly_blocked }$id ($_cap_blocker)"
      continue
    fi
  fi
  case "$inflight" in *" $id "*) excluded_inflight="${excluded_inflight:+$excluded_inflight }$id"; continue;; esac
  filtered="${filtered:+$filtered }$id"
done

[[ -n "$newly_blocked" ]]     && printf 'excluded (missing capability → marked BLOCKED): %s\n' "$newly_blocked"
[[ -n "$excluded_blocked" ]]  && printf 'excluded (BLOCKED — has a named blocker): %s\n' "$excluded_blocked"
[[ -n "$excluded_inflight" ]] && printf 'excluded (already an open Flow: ticket): %s\n' "$excluded_inflight"
if [[ -z "$filtered" ]]; then printf 'Nothing to file.\n'; exit 0; fi

# ── Group by Resource-group (ungrouped = its own solo group) ────────────────────────────────────────
# bash 3.2 — no associative arrays; carry parallel "groupkey\tid" lines and dedup keys in order.
pairs=""
for id in $filtered; do
  rg="$(govern::flow_field "$id" Resource-group "$FLOWS")"
  key="${rg:-__solo__:$id}"
  pairs="${pairs}${key}"$'\t'"${id}"$'\n'
done
# Ordered unique group keys.
group_keys="$(printf '%s' "$pairs" | cut -f1 | awk '!seen[$0]++')"

# Cost per group = min Provision-secs among its flows (absent → unknown sentinel, sorts last).
UNKNOWN=999999
cost_lines=""
while IFS= read -r key || [[ -n "$key" ]]; do   # `|| [[ -n ]]` — read the final newline-less line too
  [[ -n "$key" ]] || continue
  gmin=$UNKNOWN
  while IFS=$'\t' read -r k id; do
    [[ "$k" == "$key" ]] || continue
    ps="$(govern::flow_field "$id" Provision-secs "$FLOWS")"
    [[ "$ps" =~ ^[0-9]+$ ]] || ps=$UNKNOWN
    [[ "$ps" -lt "$gmin" ]] && gmin="$ps"
  done < <(printf '%s' "$pairs")
  cost_lines="${cost_lines}${gmin}"$'\t'"${key}"$'\n'
done < <(printf '%s' "$group_keys")
# Cheapest-first order.
ordered_keys="$(printf '%s' "$cost_lines" | sort -n -k1,1 | cut -f2-)"

# ── Spend summary + --max-deploys truncation ────────────────────────────────────────────────────────
ngroups="$(printf '%s' "$ordered_keys" | grep -c . || true)"
printf '\nSpend plan — %s validation ticket(s) / ~%s provision(s) (grouped flows share one deploy; cheapest/fastest first):\n' \
  "$ngroups" "$ngroups"

filed=0; planned=0; idx=0
while IFS= read -r key || [[ -n "$key" ]]; do   # `|| [[ -n ]]` — read the final newline-less line too
  [[ -n "$key" ]] || continue
  idx=$((idx+1))
  if [[ "$max_deploys" -gt 0 && "$idx" -gt "$max_deploys" ]]; then
    printf '  … (--max-deploys %s reached; %s further group(s) deferred)\n' "$max_deploys" "$((ngroups-max_deploys))"
    break
  fi
  gids=""; gmaxcost=0
  while IFS=$'\t' read -r k id; do
    [[ "$k" == "$key" ]] || continue
    gids="${gids:+$gids }$id"
    ps="$(govern::flow_field "$id" Provision-secs "$FLOWS")"
    [[ "$ps" =~ ^[0-9]+$ ]] && [[ "$ps" -gt "$gmaxcost" ]] && gmaxcost="$ps"
  done < <(printf '%s' "$pairs")
  set -- $gids; gn=$#
  # Label: a real resource-group name, or the solo flow id.
  case "$key" in __solo__:*) label="${key#__solo__:}";; *) label="$key";; esac
  slow=""
  if [[ "$gmaxcost" -gt 0 ]] && [[ "$gmaxcost" -gt $((TIMEOUT*6/10)) ]]; then
    slow=" ⚠ slow-provision (~${gmaxcost}s vs GOVERN_WORKER_TIMEOUT=${TIMEOUT}s — may time out)"
  fi
  printf '  [%d] %-28s %d flow(s): %s%s\n' "$idx" "$label" "$gn" "$gids" "$slow"
  planned=$((planned+1))

  if [[ "$do_file" -eq 1 ]]; then
    csv="$(printf '%s' "$gids" | tr ' ' ',')"
    title="VALIDATION: $label"; [[ "$gn" -gt 1 ]] && title="VALIDATION: $label resource-group ($gn flows)"
    body="$(cat <<EOF
Where: flow(s) $gids (.claude/shiploop/validation/flows.md)
Observed: registry status warrants a real validation run.
Fix direction: drive the REAL user path for each flow (rule #12 — real UI/API, headless browser, real
  deploy where needed), then fill the report validation.{validatedShas,environment,gatePassed,
  measured,flowIds}. Name every provisioned resource ticket-<N>-<label> so the orphan sweep can reap it.
Done when: each flow above is stamped in .claude/shiploop/validation/flows.md with a fresh verdict (PASS/FAIL or
  EFFECTIVE/INEFFECTIVE/MEASURING) pinned to the validated SHAs, with a promoted evidence summary.
EOF
)"
    n="$(printf '%s' "$body" | "$DIR/file-ticket.sh" --flow "$csv" "$title" Medium)" \
      && { printf '        → filed #%s (Flow: %s)\n' "$n" "$csv"; filed=$((filed+1)); } \
      || printf '        ✗ file-ticket failed for %s\n' "$label" >&2
  fi
done < <(printf '%s' "$ordered_keys")

printf '\n'
if [[ "$do_file" -eq 1 ]]; then
  printf 'Filed %d validation ticket(s). The governor will grind them on its next pass.\n' "$filed"
else
  printf 'DRY RUN — %d ticket(s) planned, nothing filed. Re-run with --yes to file (real spend).\n' "$planned"
fi
