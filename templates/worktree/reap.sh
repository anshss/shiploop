#!/usr/bin/env bash
# Reclaim disk from worktrees nothing needs any more.
#
# Usage:  <pm> run worktree:reap [-- --yes] [--strip]
#
# WHY THIS EXISTS
# ---------------
# Worktrees accumulate from two directions and neither is a bug in worktree:rm:
#
#   1. run-loop.sh PRESERVES the worktree for parked/failed tickets on purpose — you
#      want the evidence when you come back to it. Nothing ever ages those out.
#   2. Worktrees created BY HAND (`<pm> run worktree:new -- <slug>` from a session) have
#      no cleanup path at all. run-loop.sh only ever removes the ones it made.
#
# Measured on one workspace: 26 GB across 12 worktrees, most of it node_modules that
# would be reinstalled from a lockfile in minutes anyway.
#
# SAFETY IS THE WHOLE DESIGN
# --------------------------
# "The branch is merged" is NOT sufficient, and this was learned by measurement, not
# assumed: of four worktrees with zero commits off origin/main, one had a LIVE session
# working in it (9 processes) and another had uncommitted files. Deleting on the merge
# check alone would have destroyed both.
#
# A worktree is reaped only when EVERY check says yes, and any check that cannot be
# ANSWERED blocks the reap — could-not-look is never treated as a clean bill of health.
# The checks span every sub-repo AND the meta worktree root, which is itself a git
# worktree; scanning only the sub-repo name list silently misses unpushed meta commits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh"

APPLY=0; STRIP=0
for a in "$@"; do
  case "$a" in
    --yes|-y) APPLY=1 ;;
    --strip)  STRIP=1 ;;
    --) ;;
    -h|--help)
      cat <<USAGE
usage: $ROOT_PM run worktree:reap [-- --yes] [--strip]

  (default)  dry run — report what WOULD be reaped, change nothing
  --yes      actually remove the worktrees reported as reapable
  --strip    for KEPT worktrees that are idle+clean but still hold unmerged commits,
             delete node_modules/.next/dist/target/build. Reclaims most of the bytes,
             keeps the work.

A worktree is reapable only when ALL of:
  · no live process has its cwd inside it
  · no repo has uncommitted changes
  · no repo has commits absent from origin/main
Anything unanswerable (missing checkout, failed fetch) blocks the reap.
USAGE
      exit 0 ;;
    *) echo "unknown flag: $a (try --help)" >&2; exit 2 ;;
  esac
done

[ -d "$WORKTREE_BASE" ] || { echo "no worktree base at $WORKTREE_BASE — nothing to do"; exit 0; }

# Refresh origin/main ONCE per repo, in the main checkout. A git worktree shares its
# repo's object store and refs with the checkout it was made from, so this updates
# origin/main for every worktree of that repo at once. Fetching per worktree-repo pair
# instead means (repos x worktrees) sequential fetches — minutes of silence on a
# workspace of any size. Repos that fail to fetch are recorded and BLOCK the reap of any
# worktree using them, rather than being silently judged against a stale ref.
declare -a FETCH_FAILED=()
echo "refreshing origin/main (${#REPOS[@]} repos) ..."
for r in "${REPOS[@]}"; do
  if [ -e "$ROOT/$r/.git" ]; then
    git -C "$ROOT/$r" fetch -q origin 2>/dev/null || FETCH_FAILED+=("$r")
  fi
done
[ "${#FETCH_FAILED[@]}" -gt 0 ] && echo "  WARNING: fetch failed for: ${FETCH_FAILED[*]} — worktrees using them will be KEPT, not judged on a stale ref"
echo

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

reapable=(); kept=()

for wt in "$WORKTREE_BASE"/*/; do
  [ -d "$wt" ] || continue
  wt="${wt%/}"
  slug="$(basename "$wt")"
  printf '\033[2K  checking %s ...\r' "$slug" >&2
  size="$(human "$wt")"
  blockers=""

  # 1. LIVE — any process whose cwd is inside. Checked FIRST and reported even in a dry
  #    run, because a busy worktree is the one case where a human would otherwise reach
  #    for --yes without looking.
  livepids="$(lsof -a +D "$wt" -d cwd 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | tr '\n' ' ')"
  [ -n "$livepids" ] && blockers="$blockers live-session(pids: ${livepids% })"

  # 2/3. Per repo: uncommitted work, and commits not on origin/main. The list is REPOS
  #      *plus the meta worktree root itself* — sizing this loop by the sub-repo name
  #      list alone lets an unpushed meta commit read as clean, and nothing fails.
  for r in "${REPOS[@]}" .; do
    d="$wt/$r"
    [ "$r" = "." ] && d="$wt"
    [ -e "$d/.git" ] || continue
    label="$r"; [ "$r" = "." ] && label="meta"
    if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
      blockers="$blockers unreadable-git($label)"; continue
    fi
    if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
      n="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      blockers="$blockers uncommitted($label:$n)"
    fi
    # origin/main was refreshed once per repo above. If that fetch failed we cannot judge
    # this repo's ancestry against a trustworthy ref, so it blocks — a stale ref can
    # report an unmerged branch as merged after a force-push.
    case " ${FETCH_FAILED[*]:-} " in
      *" $r "*) blockers="$blockers fetch-failed($label)"; continue ;;
    esac
    if ! git -C "$d" rev-parse --verify -q origin/main >/dev/null 2>&1; then
      blockers="$blockers no-origin-main($label)"; continue
    fi
    ahead="$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null)"
    if [ -z "$ahead" ]; then
      blockers="$blockers ancestry-unknown($label)"
    elif [ "$ahead" -gt 0 ]; then
      blockers="$blockers unmerged($label:$ahead)"
    fi
  done

  if [ -z "$blockers" ]; then
    reapable+=("$slug|$size")
  else
    kept+=("$slug|$size|${blockers# }")
  fi
done

printf '\033[2K' >&2
echo "worktree base: $WORKTREE_BASE"
echo

if [ "${#kept[@]}" -gt 0 ]; then
  echo "KEEPING (${#kept[@]}):"
  for k in "${kept[@]}"; do
    IFS='|' read -r s sz b <<< "$k"
    printf '  %-24s %6s  %s\n' "$s" "$sz" "$b"
  done
  echo
fi

if [ "${#reapable[@]}" -eq 0 ]; then
  echo "REAPABLE (0): nothing to reclaim."
  exit 0
fi

echo "REAPABLE (${#reapable[@]}):"
for k in "${reapable[@]}"; do
  IFS='|' read -r s sz <<< "$k"
  printf '  %-24s %6s\n' "$s" "$sz"
done
echo

if [ "$APPLY" -ne 1 ]; then
  echo "dry run — nothing removed. Re-run with:  $ROOT_PM run worktree:reap -- --yes"
  exit 0
fi

rc=0
for k in "${reapable[@]}"; do
  IFS='|' read -r s sz <<< "$k"
  echo "→ removing $s ($sz)"
  rmlog="$(mktemp)"
  if bash "$ROOT/scripts/worktree/rm.sh" "$s" >"$rmlog" 2>&1; then
    rm -f "$rmlog"
  else
    # Never swallow the reason: rm.sh carries its own refusals (unpushed commits, dirty
    # tree) and printing only "FAILED" makes a correct refusal look like a bug.
    echo "  FAILED to remove $s — left in place. rm.sh said:" >&2
    sed 's/^/    /' "$rmlog" | tail -10 >&2
    rm -f "$rmlog"
    rc=1
  fi
done

if [ "$STRIP" -eq 1 ] && [ "${#kept[@]}" -gt 0 ]; then
  echo
  for k in "${kept[@]}"; do
    IFS='|' read -r s sz b <<< "$k"
    # Only strip what is idle and clean — build output is regenerable, but a live
    # session's dependency tree is not something to pull out from under it.
    case "$b" in *live-session*|*uncommitted*) continue ;; esac
    echo "→ stripping build output from $s (was $sz)"
    find "$WORKTREE_BASE/$s" -type d \
      \( -name node_modules -o -name .next -o -name dist -o -name target -o -name build \) \
      -prune -exec rm -rf {} + 2>/dev/null || true
    echo "  now $(human "$WORKTREE_BASE/$s")"
  done
fi

echo
echo "done. worktree base now $(human "$WORKTREE_BASE")"
exit "$rc"
