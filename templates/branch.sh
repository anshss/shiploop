#!/usr/bin/env bash
# Create a feature branch across root + all sub-repos (or a scoped subset).
# usage:  pnpm branch <name> [--only sub1,sub2,...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "usage: pnpm branch <name> [--only root,app,backend,website]"
  exit 2
fi

NAME="$1"; shift
SCOPE="root,app,backend,website"

while [ $# -gt 0 ]; do
  case "$1" in
    --only) SCOPE="$2"; shift 2 ;;
    -h|--help) echo "usage: pnpm branch <name> [--only root,app,backend,website]"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

create_branch() {
  local repo="$1" dir="$2"
  [[ ",$SCOPE," == *",$repo,"* ]] || return
  echo "── $repo ──"
  if ! cd "$dir" 2>/dev/null; then echo "  (missing)"; return; fi

  if git show-ref --verify --quiet "refs/heads/$NAME"; then
    echo "  branch '$NAME' already exists — checking out"
    git checkout "$NAME"
  else
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
      echo "  ⚠ dirty working tree — branch will carry uncommitted changes"
    fi
    git checkout -b "$NAME"
  fi
  cd "$ROOT"
}

create_branch "root"    "$ROOT"
create_branch "app"     "$ROOT/app"
create_branch "backend" "$ROOT/backend"
create_branch "website" "$ROOT/website"

echo ""
echo "created/checked out '$NAME' in: $SCOPE"
