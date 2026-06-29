#!/usr/bin/env bash
# Interleaved tail of all sub-repo dev-server logs with [name] prefixes.
# Useful for following a cross-repo flow (UI click → backend route → worker call)
# without juggling several windows. Pairs with dev.sh, which tees each sub-repo's
# dev output to logs/<name>.log.
#
# Usage:
#   <pm> run tail                    # tail all logs from now forward
#   <pm> run tail -- --grep foo      # filter to lines matching "foo"
#   <pm> run tail -- --since 5m      # show prior history then follow (best-effort)
#   <pm> run tail -- repo1 repo2     # restrict to specific sub-repos
#
# Each line is prefixed with [<sub-repo>] so flows are readable when interleaved.
# Color-coded by sub-repo position when stdout is a terminal. Generic — repo list
# from scripts/lib/workspace.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS_DIR="$ROOT/logs"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"
DEFAULT_REPOS=("${REPOS[@]}")

# Color per sub-repo by its index in REPOS (macOS bash 3.2 has no associative
# arrays, so cycle a fixed palette by position). No hardcoded repo names.
PALETTE=(36 35 33 34 32 31 96 95 93 94 92 91)   # cyan magenta yellow blue green red + bright
color_for() {
  local name="$1" i idx
  idx=0
  for i in "${!DEFAULT_REPOS[@]}"; do
    if [ "${DEFAULT_REPOS[$i]}" = "$name" ]; then idx="$i"; break; fi
  done
  local code="${PALETTE[$(( idx % ${#PALETTE[@]} ))]}"
  printf '\033[%sm' "$code"
}
if [ -t 1 ]; then RESET=$'\033[0m'; else RESET=""; fi

GREP_PATTERN=""
SINCE=""
SEL_REPOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --grep) GREP_PATTERN="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) SEL_REPOS+=("$1"); shift ;;
  esac
done

if [ ${#SEL_REPOS[@]} -eq 0 ]; then
  SEL_REPOS=("${DEFAULT_REPOS[@]}")
fi

# Verify logs/ has files for the requested repos
existing=()
for r in "${SEL_REPOS[@]}"; do
  if [ -f "$LOGS_DIR/$r.log" ]; then
    existing+=("$r")
  fi
done
if [ ${#existing[@]} -eq 0 ]; then
  echo "no logs found in $LOGS_DIR/ — run '$ROOT_PM run dev' first to start dev servers" >&2
  exit 1
fi

# Prefix-and-color each line as it comes through. tail -n0 starts from "now"
# unless --since is set, in which case we show prior history and follow (the
# --since value itself is best-effort: sub-repos use different timestamp formats,
# so we don't try to be precise).
tail_with_prefix() {
  local repo="$1"
  local color
  if [ -t 1 ]; then color=$(color_for "$repo"); else color=""; fi
  local file="$LOGS_DIR/$repo.log"
  local tail_args="-F"
  if [ -z "$SINCE" ]; then
    tail_args="-n0 -F"
  fi
  # shellcheck disable=SC2086
  tail $tail_args "$file" 2>/dev/null | while IFS= read -r line; do
    if [ -n "$GREP_PATTERN" ]; then
      if ! echo "$line" | grep -qE "$GREP_PATTERN"; then
        continue
      fi
    fi
    printf "%s[%s]%s %s\n" "$color" "$repo" "$RESET" "$line"
  done
}

# Trap so child tails get killed on Ctrl-C
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

for r in "${existing[@]}"; do
  tail_with_prefix "$r" &
  PIDS+=($!)
done

wait
