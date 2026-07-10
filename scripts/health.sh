#!/usr/bin/env bash
# Liveness check — HTTP curl each sub-repo's dev server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

# ── worktree env (no-op in main checkout) ──
# Inside a per-task worktree this exports WORKTREE_*_PORT offsets.
# shellcheck source=/dev/null
[ -f "$ROOT/worktree.env" ] && source "$ROOT/worktree.env"

# Resolve slot from worktree.env (WORKTREE_SLOT), default 0 (main checkout).
SLOT="${WORKTREE_SLOT:-0}"

PASS=0
FAIL=0

check() {
  local name=$1 url=$2
  if curl -sf --max-time 3 "$url" > /dev/null 2>&1; then
    echo "  ✓ $name ($url)"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name ($url) — not responding"
    FAIL=$((FAIL + 1))
  fi
}

echo "Workspace health check"
echo "----------------------"

# Only check repos that have a configured port (CLI/lib repos have none).
for repo in "${REPOS[@]}"; do
  port=$(wsp_repo_port "$repo" "$SLOT")
  [ -n "$port" ] || continue
  check "$repo" "http://localhost:$port"
done

echo ""

TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
  echo "All services up ($PASS/$TOTAL)"
  exit 0
else
  echo "$FAIL service(s) down — run '$ROOT_PM run dev' to start"
  exit 1
fi
