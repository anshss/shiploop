#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

pull() {
  local dir="$1" name="$2"
  echo "── $name ──────────────────────────"
  if [ ! -d "$dir/.git" ]; then echo "  (not a git repo, skipping)"; return; fi
  cd "$dir"
  local branch
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [ -z "$branch" ]; then
    echo "  (detached HEAD, skipping)"
  else
    echo "  on branch: $branch"
    git pull --ff-only origin "$branch" || echo "  ⚠ pull failed"
  fi
  cd "$ROOT"
}

pull "$ROOT" "root"
for repo in "${REPOS[@]}"; do
  pull "$ROOT/$repo" "$repo"
done

echo ""
echo "Pull complete."
