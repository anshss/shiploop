#!/usr/bin/env bash
# Regression for lock-release.sh — the manual reclaim path for a run-lock left
# behind by a crashed worker. run-loop.sh already reclaims dead-holder locks
# automatically; this script is the OFFLINE version an adopter runs before
# scaffold.sh / a fresh /govern.
#
# Contract:
#   1. no lock present → exit 0, "nothing to do"
#   2. DEAD holder → reclaimed, lock gone, exit 0
#   3. LIVE holder → refused, exit 1, lock preserved
#   4. --status LIVE  → exit 0, prints "LIVE" (no side effect)
#   5. --status DEAD  → exit 0, prints "STALE"
#   6. --status absent → exit 0, "nothing to do"
#   7. --force → reclaimed regardless of holder, exit 0
#   8. unattributed holder (no pid line) → reclaimed with warning, exit 0
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/lock-release.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

mk_ws_stub "$ROOT"
# lock-release sources common.sh which needs GOVERNOR_DIR resolved from workspace.sh's
# meta root. mk_ws_stub already stitches that together.
LOCK="$ROOT/governor/.govern.lock"
mkdir -p "$ROOT/governor"

# ── 1. no lock present → exit 0 ─────────────────────────────────────────────
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. no lock → exit 0"
assert_contains "$out" "nothing to do" "1. no-lock message"

# ── 2. DEAD holder → reclaimed ───────────────────────────────────────────────
mkdir -p "$LOCK"
# Use a pid that is highly unlikely to exist (max pid on most systems is 32k; use 999999).
echo "run=r pid=999999 started=1" > "$LOCK/holder"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "2. dead-holder → exit 0"
assert_contains "$out" "reclaimed" "2. reports reclaimed"
[ ! -d "$LOCK" ] && printf 'ok   - 2. lock actually removed\n' || { printf 'FAIL - 2. lock still present\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 3. LIVE holder ($$) → refused ────────────────────────────────────────────
mkdir -p "$LOCK"
echo "run=r pid=$$ started=1" > "$LOCK/holder"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "3. live-holder → exit 1"
assert_contains "$out" "LIVE" "3. states LIVE holder"
[ -d "$LOCK" ] && printf 'ok   - 3. lock preserved on refuse\n' || { printf 'FAIL - 3. lock removed on live-holder refuse\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 4. --status LIVE → exit 0, prints LIVE ──────────────────────────────────
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" --status 2>&1)"; rc=$?
assert_eq "$rc" "0" "4. --status live → exit 0"
assert_contains "$out" "LIVE" "4. --status prints LIVE"
[ -d "$LOCK" ] && printf 'ok   - 4. --status is read-only (lock preserved)\n' || { printf 'FAIL - 4. --status removed the lock\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 5. --status DEAD → exit 0, prints STALE ─────────────────────────────────
rm -rf "$LOCK"; mkdir -p "$LOCK"
echo "run=r pid=999999 started=1" > "$LOCK/holder"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" --status 2>&1)"; rc=$?
assert_eq "$rc" "0" "5. --status dead → exit 0"
assert_contains "$out" "STALE" "5. --status prints STALE"

# ── 6. --status absent → exit 0 ─────────────────────────────────────────────
rm -rf "$LOCK"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" --status 2>&1)"; rc=$?
assert_eq "$rc" "0" "6. --status absent → exit 0"
assert_contains "$out" "nothing to do" "6. --status absent → nothing-to-do"

# ── 7. --force → reclaimed regardless ────────────────────────────────────────
mkdir -p "$LOCK"
echo "run=r pid=$$ started=1" > "$LOCK/holder"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" --force 2>&1)"; rc=$?
assert_eq "$rc" "0" "7. --force → exit 0"
assert_contains "$out" "reclaimed" "7. --force reports reclaimed"
[ ! -d "$LOCK" ] && printf 'ok   - 7. --force removed the lock\n' || { printf 'FAIL - 7. --force left the lock\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 8. unattributed holder (no pid) → reclaimed ──────────────────────────────
mkdir -p "$LOCK"
echo "no-pid-line here" > "$LOCK/holder"
out="$(GOVERN_LOCK="$LOCK" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "8. unattributed holder → exit 0"
assert_contains "$out" "unattributed" "8. calls out unattributed"
[ ! -d "$LOCK" ] && printf 'ok   - 8. unattributed → reclaimed\n' || { printf 'FAIL - 8. unattributed NOT reclaimed\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

assert_done
