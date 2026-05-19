#!/usr/bin/env bash
# Check that all three dev servers are responding
set -euo pipefail

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

echo "Splito health check"
echo "-------------------"
check "app"     "http://localhost:3000"
check "website" "http://localhost:3001"
check "backend" "http://localhost:4000"
echo ""

if [ $FAIL -eq 0 ]; then
  echo "All services up ($PASS/3)"
  exit 0
else
  echo "$FAIL service(s) down — run 'pnpm dev' to start"
  exit 1
fi
