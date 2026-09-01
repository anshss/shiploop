#!/usr/bin/env bash
# The install semaphore must bound CONCURRENT holders across independent PROCESSES,
# which is the entire point: a per-worktree `wait` cannot see a peer session's
# subshells. So this spawns real background processes, not subshells of one parent,
# and asserts on the observed high-water mark.
#
# Includes a POSITIVE CONTROL — the same workload with the semaphore bypassed MUST
# exceed the cap. Without it, a no-op semaphore (or a typo'd source path) would make
# the capped assertion pass vacuously.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# lib/install-semaphore.sh: templates/lib (template layout) | <root>/scripts/lib (workspace).
SEM=""
for _cand in "$DIR/../../lib/install-semaphore.sh" "$DIR/../../../lib/install-semaphore.sh"; do
  [ -f "$_cand" ] && { SEM="$(cd "$(dirname "$_cand")" && pwd)/install-semaphore.sh"; break; }
done
[ -n "$SEM" ] || { echo "cannot locate install-semaphore.sh from $DIR" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CAP=3
WORKERS=9

# Each worker acquires, stamps arrival/departure into a shared event log, holds
# briefly, releases. The high-water mark is replayed from the +1/-1 events.
run_workers() { # <capped|uncapped>
  local mode="$1"
  local events="$TMP/events.$mode"
  : > "$events"
  local i
  for i in $(seq 1 "$WORKERS"); do
    (
      export WORKTREE_INSTALL_PARALLEL="$CAP"
      export WORKTREE_INSTALL_WAIT_TIMEOUT=60
      ROOT="$TMP/root.$mode"; mkdir -p "$ROOT/logs"
      log() { :; }
      # shellcheck source=/dev/null
      source "$SEM"
      [ "$mode" = "capped" ] && sem_acquire "w$i"
      echo "+" >> "$events"
      sleep 0.4
      echo "-" >> "$events"
      [ "$mode" = "capped" ] && sem_release
      true
    ) &
  done
  wait
  awk '{ if ($0=="+") n++; else n--; if (n>max) max=n } END { print max+0 }' "$events"
}

peak_capped="$(run_workers capped)"
[ "$peak_capped" -le "$CAP" ] \
  && assert_eq "within-cap" "within-cap" "peak concurrent holders = $peak_capped, never exceeds cap $CAP" \
  || assert_eq "peak=$peak_capped" "<= $CAP" "peak concurrent holders must not exceed the cap"

# A semaphore that serialized everything would also satisfy "never exceeds cap", and
# would silently destroy the parallelism the bootstrap wants. Assert it still fans out.
[ "$peak_capped" -gt 1 ] \
  && assert_eq "parallel" "parallel" "peak $peak_capped > 1 — still genuinely parallel, not a queue of one" \
  || assert_eq "serialized" "parallel" "semaphore serialized every worker; the cap is not being used"

peak_raw="$(run_workers uncapped)"
[ "$peak_raw" -gt "$CAP" ] \
  && assert_eq "sensitive" "sensitive" "positive control: uncapped peak = $peak_raw > $CAP, so the capped result is meaningful" \
  || assert_eq "insensitive" "sensitive" "uncapped peak = $peak_raw did not exceed $CAP — test is not sensitive; the capped pass proves nothing"

# A slot whose holder was killed must be reclaimed, or one ^C'd bootstrap permanently
# shrinks the cap for every later run on the machine.
SEMDIR="$TMP/reclaim/logs/.install-slots"; mkdir -p "$SEMDIR"
for i in $(seq 1 "$CAP"); do mkdir -p "$SEMDIR/$i"; echo "999999" > "$SEMDIR/$i/holder"; done
got="$(
  export WORKTREE_INSTALL_PARALLEL="$CAP" WORKTREE_INSTALL_WAIT_TIMEOUT=30
  ROOT="$TMP/reclaim"; log() { :; }
  # shellcheck source=/dev/null
  source "$SEM"
  sem_acquire "reclaimer" && [ -n "$INSTALL_SEM_HELD" ] && echo yes
)"
assert_eq "$got" "yes" "a slot held by a dead pid is reclaimed rather than blocking until timeout"

assert_done
