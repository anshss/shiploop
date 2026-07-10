#!/usr/bin/env bash
# List registered worktrees in a table. Flag (orphaned) entries whose path is
# missing on disk. --gc removes orphaned entries from the registry.
#
# Usage:  <pm> run worktree:status -- [--gc]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"
# shellcheck source=lib/registry.sh
source "$ROOT/scripts/worktree/lib/registry.sh"

GC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gc) GC=1; shift ;;
    -h|--help) echo "usage: $ROOT_PM run worktree:status -- [--gc]"; exit 0 ;;
    --) shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Build a list of repos that have ports, for the column header.
# We print up to 4 port columns (the first 4 repos with a base port) to keep
# the table width reasonable; additional ported repos are visible via PATH.
PORT_REPOS=()
for repo in "${REPOS[@]}"; do
  [ -n "$(wsp_repo_port "$repo" 0)" ] || continue
  PORT_REPOS+=("$repo")
done

# Header — SLOT + NAME + one column per ported repo (up to 4) + PATH
header_fmt="%-4s %-32s"
header_args=("SLOT" "NAME")
sep_fmt="%-4s %-32s"
sep_args=("----" "----")
col_count=0
for repo in ${PORT_REPOS[@]+"${PORT_REPOS[@]}"}; do
  [ "$col_count" -lt 4 ] || break
  col_label=$(echo "$repo" | tr '[:lower:]' '[:upper:]' | cut -c1-5)
  header_fmt+=" %-5s"
  header_args+=("$col_label")
  sep_fmt+=" %-5s"
  sep_args+=("-----")
  col_count=$((col_count + 1))
done
header_fmt+=" %s\n"
header_args+=("PATH")
sep_fmt+=" %s\n"
sep_args+=("----")

# shellcheck disable=SC2059
printf "$header_fmt" "${header_args[@]}"
# shellcheck disable=SC2059
printf "$sep_fmt" "${sep_args[@]}"

ORPHANS=()
while IFS=$'\t' read -r slot name path; do
  row_fmt="%-4s %-32s"
  row_args=("$slot" "$name")
  col_count=0
  for repo in ${PORT_REPOS[@]+"${PORT_REPOS[@]}"}; do
    [ "$col_count" -lt 4 ] || break
    port=$(wsp_repo_port "$repo" "$slot")
    row_fmt+=" %-5s"
    row_args+=("${port:-—}")
    col_count=$((col_count + 1))
  done
  marker=""
  if [ "$slot" != "0" ] && [ ! -d "$path" ]; then
    marker=" (orphaned)"
    ORPHANS+=("$name")
  fi
  row_fmt+=" %s%s\n"
  row_args+=("$path" "$marker")
  # shellcheck disable=SC2059
  printf "$row_fmt" "${row_args[@]}"
done < <(wt_registry_read | jq -r '.slots | to_entries[] | [.key, .value.name, .value.path] | @tsv' | sort -n)

if [ "$GC" -eq 1 ] && [ "${#ORPHANS[@]}" -gt 0 ]; then
  echo ""
  echo "→ gc: removing ${#ORPHANS[@]} orphaned entries"
  for name in "${ORPHANS[@]}"; do
    slot=$(wt_registry_with_lock wt_registry_remove "$name")
    echo "  freed slot $slot ($name)"
  done
elif [ "$GC" -eq 1 ]; then
  echo ""
  echo "→ gc: no orphans to clean"
fi
