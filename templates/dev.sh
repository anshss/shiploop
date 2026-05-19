#!/usr/bin/env bash
# Run all three dev servers in parallel, tee each one's output to logs/<name>.log
# (visible on stdout too, prefixed). Ctrl-C cleans up all children.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

: > "$LOGS/app.log"
: > "$LOGS/backend.log"
: > "$LOGS/website.log"

pids=()

cleanup() {
  echo ""
  echo "stopping dev servers..."
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # give children a moment to exit, then force
  sleep 1
  for pid in "${pids[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  exit 0
}
trap cleanup INT TERM

run_one() {
  local name="$1" dir="$2" log="$3"
  (
    cd "$dir" || exit 1
    # Line-buffered tee: prefix on stdout, raw on disk.
    pnpm dev 2>&1 | while IFS= read -r line; do
      printf '[%s] %s\n' "$name" "$line"
      printf '%s\n' "$line" >> "$log"
    done
  ) &
  pids+=("$!")
}

run_one "app"     "$ROOT/app"     "$LOGS/app.log"
run_one "backend" "$ROOT/backend" "$LOGS/backend.log"
run_one "website" "$ROOT/website" "$LOGS/website.log"

echo "logs → $LOGS/{app,backend,website}.log"
echo "(ctrl-c to stop)"
wait
