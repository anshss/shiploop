#!/usr/bin/env bash
# Regression for #183: the single-run lock (.govern.lock) must RELIABLY serialize drivers. Observed:
# two run-loops ran concurrently though the lock dir existed and GOVERN_ALLOW_CONCURRENT was unset —
# the plain `mkdir` lock had no liveness check, so a stale lock forced a manual `rm -rf`, and a live
# lock mistaken for stale + cleared let a 2nd unflagged driver through. The hardened lock records the
# holder pid INSIDE the lock dir and validates liveness. Hermetic + generic. Proves every branch:
#   1. live, non-self holder      → REFUSE with the existing die message (the core Done-when),
#   2. dead holder (crashed run)  → reclaim automatically (no manual rm needed),
#   3. unattributed FRESH lock    → refuse (don't steal a maybe-live pre-#183 lock),
#   4. unattributed STALE lock    → reclaim once past the stale window,
#   5. GOVERN_ALLOW_CONCURRENT=1  → proceed alongside, never touch the other holder's lock,
#   6. clean acquire              → always logs which concurrency mode it took.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/logs"
printf '# Tickets\n' > "$T/tickets.md"                       # header only → no eligible tickets → clean exit
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

# Run run-loop in dry mode (skips live preflight/escalations) so it reaches the lock then exits at
# "no eligible tickets". $RC = its exit code; $OUT = combined stdout+stderr. Extra env via positional
# args. `env -u GOVERN_ALLOW_CONCURRENT` strips any AMBIENT flag (a govern worker runs WITH it set) so
# the single-run path is exercised deterministically; cases that want PARALLEL pass it back in.
run_rl() { # extra "VAR=val"... -> sets OUT, RC
  # `&& RC=0 || RC=$?` captures run-loop's exit WITHOUT tripping the sourced `set -e` on a refusal.
  OUT="$(env -u GOVERN_ALLOW_CONCURRENT -u GOVERN_RUN_DIR "$@" \
    GOVERN_WS_ROOT="$T" \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
    GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_LOCK="$T/lock" \
    bash "$RL" --dry-run </dev/null 2>&1)" && RC=0 || RC=$?
}

# A guaranteed-LIVE, non-self holder = this test's own pid ($$): alive for the whole run and distinct
# from the run-loop child's pid, so run-loop sees a live OTHER holder.
LIVE="$$"
# A guaranteed-DEAD holder = a pid far above any pid_max, so `kill -0` always fails → treated crashed.
DEAD=99999999

# ── 1. live, non-self holder → REFUSE (the core Done-when) ──
mkdir -p "$T/lock"; printf 'run=run-old pid=%s started=1\n' "$LIVE" > "$T/lock/holder"
run_rl
assert_eq "$RC" "1"                                       "live holder → second run-loop refuses (exit 1)"
assert_contains "$OUT" "another govern run holds"         "refusal uses the existing die message"
assert_contains "$OUT" "live holder"                      "die message names the live holder"
case "$OUT" in *"no eligible tickets"*) assert_eq "entered-loop" "refused" "refused run must NOT enter the loop";; esac
assert_eq "$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$T/lock/holder")" "$LIVE" "live holder's lock left intact (not stolen)"

# ── 2. dead holder (crashed run) → reclaim automatically ──
rm -rf "$T/lock"; mkdir -p "$T/lock"
printf 'run=run-crashed pid=%s started=1\n' "$DEAD" > "$T/lock/holder"
run_rl
assert_eq "$RC" "0"                                       "dead-holder lock reclaimed → run proceeds (exit 0)"
assert_contains "$OUT" "STALE .govern.lock"               "stale (dead-holder) reclaim is logged"
assert_contains "$OUT" "concurrency mode: SINGLE-RUN"     "mode logged after reclaim"

# ── 3. unattributed FRESH lock (no holder pid) → REFUSE (don't steal a maybe-live pre-#183 lock) ──
rm -rf "$T/lock"; mkdir -p "$T/lock"                      # empty, fresh mtime
run_rl GOVERN_LOCK_STALE_S=3600
assert_eq "$RC" "1"                                       "fresh unattributed lock → refused"
assert_contains "$OUT" "another govern run holds"         "fresh unattributed lock refused with die message"

# ── 4. unattributed STALE lock (old mtime) → reclaim past the stale window ──
rm -rf "$T/lock"; mkdir -p "$T/lock"; touch -t 202001010000 "$T/lock"
run_rl GOVERN_LOCK_STALE_S=3600
assert_eq "$RC" "0"                                       "old unattributed lock (> stale window) → reclaimed"
assert_contains "$OUT" "UNATTRIBUTED .govern.lock"        "unattributed-stale reclaim logged"

# ── 5. GOVERN_ALLOW_CONCURRENT=1 → proceed alongside, never touch the other holder's lock ──
rm -rf "$T/lock"; mkdir -p "$T/lock"; printf 'run=other pid=%s started=1\n' "$LIVE" > "$T/lock/holder"
run_rl GOVERN_ALLOW_CONCURRENT=1
assert_eq "$RC" "0"                                       "GOVERN_ALLOW_CONCURRENT=1 runs alongside a live holder"
assert_contains "$OUT" "concurrency mode: PARALLEL"       "parallel mode logged"
assert_eq "$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$T/lock/holder")" "$LIVE" "parallel driver left the existing lock untouched"

# ── 6. clean acquire → always logs the mode ──
rm -rf "$T/lock"
run_rl
assert_eq "$RC" "0"                                       "no lock present → acquires cleanly"
assert_contains "$OUT" "concurrency mode: SINGLE-RUN — exclusive lock acquired by run" "clean single-run acquisition logged with run id"

# ── wiring assertions (so the hardening can't silently regress) ──
# grep the file directly (not `printf "$(cat …)" | grep -q`): a -q grep exits on first match and
# SIGPIPEs the printf, which `set -o pipefail` then reports as a failure on a large haystack.
grep -qF "_take_single_lock" "$RL" && w=ok || w=miss; assert_eq "$w" "ok" "run-loop uses the pid-validated single-run lock helper"
grep -qF "concurrency mode:" "$RL" && w=ok || w=miss; assert_eq "$w" "ok" "run-loop always logs the concurrency mode"

assert_done
