#!/usr/bin/env bash
# Liveness check — HTTP curl each sub-repo's dev server (web projects only).
set -euo pipefail

# ── customize: list each sub-repo and its dev port as "name:port" ──
REPOS_PORTS=("app:3001" "backend:4000" "website:3000")

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
for entry in "${REPOS_PORTS[@]}"; do
  name="${entry%:*}"
  port="${entry#*:}"
  check "$name" "http://localhost:$port"
done
echo ""

TOTAL=${#REPOS_PORTS[@]}
if [ $FAIL -eq 0 ]; then
  echo "All services up ($PASS/$TOTAL)"
  exit 0
else
  echo "$FAIL service(s) down — run 'pnpm dev' to start"
  exit 1
fi
