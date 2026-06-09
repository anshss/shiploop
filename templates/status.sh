#!/usr/bin/env bash
# Single-read table of live state across all sub-repos.
# Columns: branch | dirty | ahead | behind | PR | CI
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

# ── worktree env (no-op in main checkout) ──
# shellcheck source=/dev/null
[ -f "$ROOT/worktree.env" ] && source "$ROOT/worktree.env"

GH_AVAILABLE=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_AVAILABLE=1
fi

printf "%-18s %-32s %-6s %-6s %-7s %-8s %-10s\n" "REPO" "BRANCH" "DIRTY" "AHEAD" "BEHIND" "PR" "CI"
printf "%-18s %-32s %-6s %-6s %-7s %-8s %-10s\n" "----" "------" "-----" "-----" "------" "--" "--"

report() {
  local dir="$1" name="$2"
  if [ ! -d "$dir/.git" ]; then
    printf "%-18s %s\n" "$name" "(not a git repo)"
    return
  fi
  cd "$dir" 2>/dev/null || { printf "%-18s %s\n" "$name" "(missing)"; return; }

  local branch dirty ahead behind pr_num ci
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" = "0" ] && dirty="-"

  ahead="-"; behind="-"
  if upstream=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null); then
    ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo "-")
    behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo "-")
    [ "$ahead" = "0" ] && ahead="-"
    [ "$behind" = "0" ] && behind="-"
  fi

  pr_num="-"; ci="-"
  if [ $GH_AVAILABLE -eq 1 ] && [ "$branch" != "detached" ]; then
    local pr_json
    pr_json=$(gh pr list --head "$branch" --json number,statusCheckRollup --limit 1 2>/dev/null || echo "[]")
    if [ "$pr_json" != "[]" ] && [ -n "$pr_json" ]; then
      pr_num=$(printf "%s" "$pr_json" | grep -o '"number":[0-9]*' | head -1 | cut -d: -f2)
      [ -n "$pr_num" ] && pr_num="#$pr_num"
      if printf "%s" "$pr_json" | grep -q '"conclusion":"FAILURE"'; then
        ci="fail"
      elif printf "%s" "$pr_json" | grep -q '"status":"IN_PROGRESS"'; then
        ci="running"
      elif printf "%s" "$pr_json" | grep -q '"conclusion":"SUCCESS"'; then
        ci="pass"
      fi
    fi
  fi

  printf "%-18s %-32s %-6s %-6s %-7s %-8s %-10s\n" \
    "$name" "${branch:0:32}" "$dirty" "$ahead" "$behind" "$pr_num" "$ci"
  cd "$ROOT"
}

report "$ROOT" "root"
for repo in "${REPOS[@]}"; do
  report "$ROOT/$repo" "$repo"
done

echo ""
if [ $GH_AVAILABLE -eq 0 ]; then
  echo "(gh not authenticated — PR/CI columns blank. run 'gh auth login')"
fi

echo ""
echo "── worktrees ──"
bash "$ROOT/scripts/worktree/status.sh"
