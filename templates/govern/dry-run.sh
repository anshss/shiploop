#!/usr/bin/env bash
# Preview everything that happens to a ticket AFTER its worker has done the work, with zero real
# side effects: which PRs would be merged and in what order, what tickets.md bookkeeping the
# resolution would apply, and whether the CI poller is wired. Nothing is merged, committed or
# modified. Resolving a ticket for real is `resolve-ticket.sh <N>`.
#
# The worker itself is not rehearsed here. A worker runs in-session as Agent(subagent_type:
# "worker"), so there is no subprocess to launch in a plan mode and capture a report from -- the
# steps below read the ticket's real open PRs instead of a worker's JSON.
# Usage: dry-run.sh <ticket-number>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

echo "=== govern dry-run ==="

# 1. The ticket to rehearse. Named, always: there is no backlog selection to fall back on.
N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "usage: dry-run.sh <ticket-number> — name the ticket to rehearse"
echo "[1/4] ticket #$N"

# 2. Echo the merge decision, for EVERY open PR of the ticket (discovered `ticket-<N>` heads),
#    merge-repo-first, so a multi-repo ticket's siblings are previewed too, not just the first one.
echo "[2/4] merge decision:"
pr_lines="$(govern::collect_ticket_prs "$N" "")"
if [[ -n "$pr_lines" ]]; then
  while IFS=$'\t' read -r prepo pnum _purl; do
    [[ -n "$prepo" && -n "$pnum" ]] || continue
    GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$DIR/merge-pr.sh" "$prepo" "$pnum" || echo "    (would refuse $prepo#$pnum: frontend PR-only, left open)"
  done <<< "$pr_lines"
else
  echo "    no open PR found for ticket #$N, nothing to merge"
fi

# 3. Echo the tickets.md bookkeeping (computed, NOT applied). Which branch fires for real depends
#    on the status in the worker's report, which only exists once a worker has actually run.
echo "[3/4] bookkeeping (echo only, tickets.md NOT modified):"
if [[ -n "$pr_lines" ]]; then
  echo "    on a resolved report: WOULD delete '## #$N' block from tickets.md, append its newTickets,"
  echo "                          and apply its lessonPatch to CLAUDE.md"
else
  echo "    no open PR, so a report here would not be resolved:"
fi
echo "    on a parked report:   WOULD append the escalation to governor/escalations.md ## Open: and leave ticket #$N"
echo "    on a failed report:   WOULD append a failed escalation and leave ticket #$N"

# 4. Prove the CI poller wiring read-only against an existing open PR, if one exists.
#    Probe the first auto-merge repo (e.g. a backend): it's the one whose PRs get merged.
echo "[4/4] CI poller wiring check:"
probe_repo="${GOVERN_MERGE_REPOS[0]:-}"
if [[ -n "$probe_repo" ]]; then
  openpr="$(gh pr list --repo "$GITHUB_ORG/$probe_repo" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
else
  openpr=""
fi
if [[ -n "$probe_repo" && -n "$openpr" ]]; then
  echo "    await-ci.sh $probe_repo #$openpr → $(GOVERN_CI_MAX_TRIES=1 "$DIR/await-ci.sh" "$probe_repo" "$openpr")"
else
  echo "    (no open $probe_repo PR to probe — wiring exercised in unit test instead)"
fi

echo "=== dry-run complete — zero real side effects ==="
