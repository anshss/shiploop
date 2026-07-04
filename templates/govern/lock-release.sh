#!/usr/bin/env bash
# lock-release.sh — reclaim the governor's single-run lock when the previous
# holder crashed and left it behind.
#
# The governor uses a directory lock at $GOVERNOR_DIR/.govern.lock. run-loop.sh
# stamps a holder file inside it (run=… pid=… started=…) and DOES already
# self-reclaim when it finds a lock whose holder pid is dead — see
# templates/govern/run-loop.sh:81-103. So this script is only needed when the
# adopter is NOT about to run the governor and just wants to clear the lock
# proactively (e.g. before scaffold.sh refreshes files under scripts/govern/),
# or when they see a lingering lock and want to confirm it's safe to remove.
# It performs the SAME liveness check as run-loop, so no live-holder lock is
# ever stolen — the manual `rm -rf` footgun the doctrine used to force is
# eliminated.
#
# Usage:
#   scripts/govern/lock-release.sh          # inspect; reclaim iff dead-holder
#   scripts/govern/lock-release.sh --force  # reclaim regardless (STILL PRINTS
#                                             the holder for the record — use
#                                             only if you truly know the
#                                             process is gone)
#   scripts/govern/lock-release.sh --status # print holder info, exit 0 if
#                                             lock is live-held / dead / absent
#
# Exit codes:
#   0  reclaimed (or already absent, or --status live-held reported)
#   1  live holder present — refused (default) / unable to read state
#   2  arg error
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
LOCK="${GOVERN_LOCK:-$GOVERNOR_DIR/.govern.lock}"

MODE=reclaim
case "${1:-}" in
  --force)  MODE=force ;;
  --status) MODE=status ;;
  "")       : ;;
  -h|--help)
    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) echo "lock-release: unknown arg '$1' (use --force, --status, or no arg)" >&2; exit 2 ;;
esac

if [[ ! -d "$LOCK" ]]; then
  echo "lock-release: no lock present at $LOCK — nothing to do"
  exit 0
fi

holder="$(cat "$LOCK/holder" 2>/dev/null || true)"
holder_pid="$(printf '%s' "$holder" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"

if [[ "$MODE" == status ]]; then
  echo "lock : $LOCK"
  echo "holder: ${holder:-<no holder file>}"
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    echo "state: LIVE (pid $holder_pid alive)"
    exit 0
  elif [[ -n "$holder_pid" ]]; then
    echo "state: STALE (pid $holder_pid dead)"
    exit 0
  else
    echo "state: UNATTRIBUTED (no holder pid — pre-lifecycle lock or partial write)"
    exit 0
  fi
fi

if [[ "$MODE" == force ]]; then
  echo "lock-release: --force — reclaiming $LOCK  (was: ${holder:-<no holder>})"
  rm -rf "$LOCK" 2>/dev/null || { echo "lock-release: rm -rf failed" >&2; exit 1; }
  echo "lock-release: reclaimed"
  exit 0
fi

# Default MODE=reclaim: only proceed if the holder pid is dead / unknown.
if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
  echo "lock-release: LIVE holder — refusing to reclaim." >&2
  echo "  lock  : $LOCK" >&2
  echo "  holder: $holder" >&2
  echo "  action: wait for the run to finish, or (only if certain the process is gone) --force" >&2
  exit 1
fi

if [[ -n "$holder_pid" ]]; then
  echo "lock-release: dead holder (pid $holder_pid) — reclaiming $LOCK"
else
  echo "lock-release: unattributed holder — reclaiming $LOCK  (was: ${holder:-<no holder>})"
fi
rm -rf "$LOCK" 2>/dev/null || { echo "lock-release: rm -rf failed" >&2; exit 1; }
echo "lock-release: reclaimed — safe to run scaffold.sh / the governor again"
exit 0
