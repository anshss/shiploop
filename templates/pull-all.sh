#!/usr/bin/env bash
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pull() {
  local dir="$1"
  local name="$2"
  echo "── $name ──────────────────────────"
  cd "$dir"
  local branch
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [ -z "$branch" ]; then
    echo "  (detached HEAD, skipping)"
  else
    echo "  on branch: $branch"
    git pull --ff-only origin "$branch"
  fi
  cd "$ROOT"
}

pull "$ROOT"              "root"
pull "$ROOT/app"          "app"
pull "$ROOT/backend"      "backend"
pull "$ROOT/website"      "website"

echo ""
echo "All repos up to date."
