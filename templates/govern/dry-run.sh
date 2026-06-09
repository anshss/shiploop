#!/usr/bin/env bash
# Prove the whole pipeline with zero real side effects:
#  - worker runs in PLAN mode (no edits, no PR)
#  - merge + tickets.md bookkeeping run in ECHO mode (printed, not executed)
#  - the selected ticket and a synthetic worktree are used; nothing is committed.
# Usage: dry-run.sh [ticket-number]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

echo "=== govern dry-run ==="

# 1. Select (real selector against real tickets.md).
N="${1:-$("$DIR/select-ticket.sh")}"
[[ -n "$N" ]] || govern::die "no eligible ticket to dry-run"
echo "[1/5] selected ticket #$N"

# 2. Spawn the worker in dry (plan) mode. Plan mode is read-only, so we point the worker at
#    the REAL main checkout for genuine context — no worktree is created, nothing is copied,
#    and the worker physically cannot write (no edits / no PR). This is faithful AND fast.
sandbox="$(mktemp -d)"; trap 'rm -rf "$sandbox"' EXIT
cat > "$sandbox/wt.sh" <<EOF
#!/usr/bin/env bash
echo "$WS_ROOT"
EOF
chmod +x "$sandbox/wt.sh"

echo "[2/5] spawning worker in PLAN mode (no edits / no PR)..."
report="$(GOVERN_MODE=dry GOVERN_WORKTREE_CMD="$sandbox/wt.sh" GOVERN_LOG_ROOT="$sandbox/logs" \
  "$DIR/spawn-worker.sh" "$N" || true)"
echo "    worker report:"; printf '%s\n' "$report" | jq . 2>/dev/null || printf '%s\n' "$report"

status="$(printf '%s' "$report" | jq -r '.status // "failed"' 2>/dev/null || echo failed)"

# 3. Echo the merge decision.
echo "[3/5] merge decision:"
repo="$(printf '%s' "$report" | jq -r '.pr.repo // empty' 2>/dev/null || true)"
pr="$(printf '%s' "$report" | jq -r '.pr.number // empty' 2>/dev/null || true)"
if [[ "$status" == "resolved" && -n "$repo" && -n "$pr" ]]; then
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$DIR/merge-pr.sh" "$repo" "$pr" || echo "    (would refuse: frontend PR-only)"
else
  echo "    no PR to merge (status=$status) — nothing to do"
fi

# 4. Echo the tickets.md bookkeeping diff (computed, NOT applied).
echo "[4/5] bookkeeping (echo only — tickets.md NOT modified):"
if [[ "$status" == "resolved" ]]; then
  echo "    WOULD delete '## #$N' block from tickets.md"
  echo "    WOULD append $(printf '%s' "$report" | jq '.newTickets | length' 2>/dev/null || echo 0) new ticket(s)"
  lesson="$(printf '%s' "$report" | jq -r '.lessonToPromote // empty' 2>/dev/null || true)"
  [[ -n "$lesson" ]] && echo "    WOULD promote lesson to CLAUDE.md: $lesson"
elif [[ "$status" == "parked" ]]; then
  echo "    WOULD append escalation to governor/escalations.md ## Open:"
  printf '%s' "$report" | jq '.escalation' 2>/dev/null || true
  echo "    WOULD leave ticket #$N in tickets.md"
else
  echo "    status=$status → WOULD append a failed escalation and leave ticket #$N"
fi

# 5. Prove the CI poller wiring read-only against an existing open PR, if one exists.
#    Probe the first auto-merge repo (e.g. a backend) — it's the one whose PRs the loop merges.
echo "[5/5] CI poller wiring check:"
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
