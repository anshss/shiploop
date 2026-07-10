#!/usr/bin/env bash
# Checkout a branch across root + all sub-repos.
# Falls back to tracking origin/<name> if a local branch doesn't exist.
# usage:  <pm> run switch -- <name> [--only sub1,sub2,...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

DEFAULT_SCOPE="root,$(wsp_repos_csv)"

if [ $# -lt 1 ]; then
  echo "usage: $ROOT_PM run switch -- <name> [--only $DEFAULT_SCOPE]"
  exit 2
fi

NAME="$1"; shift
SCOPE="$DEFAULT_SCOPE"
while [ $# -gt 0 ]; do
  case "$1" in
    --only) SCOPE="$2"; shift 2 ;;
    -h|--help) echo "usage: $ROOT_PM run switch -- <name> [--only $DEFAULT_SCOPE]"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

switch_one() {
  local repo="$1" dir="$2"
  [[ ",$SCOPE," == *",$repo,"* ]] || return
  echo "── $repo ──"
  if [ ! -d "$dir/.git" ]; then echo "  (not a git repo, skipping)"; return; fi
  if ! cd "$dir" 2>/dev/null; then echo "  (missing)"; return; fi

  if git show-ref --verify --quiet "refs/heads/$NAME"; then
    git checkout "$NAME"
  elif git ls-remote --exit-code --heads origin "$NAME" >/dev/null 2>&1; then
    echo "  no local branch — tracking origin/$NAME"
    git checkout -b "$NAME" --track "origin/$NAME"
  else
    echo "  ⚠ no local or remote branch '$NAME' — skipping"
  fi
  cd "$ROOT"
}

switch_one "root" "$ROOT"
for repo in "${REPOS[@]}"; do
  switch_one "$repo" "$ROOT/$repo"
done
