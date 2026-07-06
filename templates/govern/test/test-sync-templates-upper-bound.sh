#!/usr/bin/env bash
# N4 — enumeration upper-bound pinning (GOVERN_SYNC_UPPER_BOUND). sync-port must
# be able to pin every drift walk to ONE HEAD capture so a mirrored-file commit
# landing on live main MID-RUN (between drift enumeration and the marker advance)
# is excluded from BOTH the port and the marker advance — not silently swept into
# the marker as "ported" while never actually being ported (silent drift loss).
#
# Proves, with a base marker and TWO drifting commits C1 (pinned bound) and C2
# (the "mid-run" commit past the bound):
#   1. --check / --files / --diff bounded to C1 see ONLY C1's change, not C2's.
#   2. after --mark C1, an UNBOUNDED --check still reports C2 as drift — i.e. the
#      mid-run commit survives as future drift rather than being lost.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-templates.sh"

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly found\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"; mkdir -p "$REPO/scripts/govern/test"
TPL_ROOT="$SANDBOX/templates"; TPL="$TPL_ROOT/govern"; mkdir -p "$TPL/test"

git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo 'echo run' > "$TPL/run-loop.sh"                          # template counterpart exists
echo 'echo run' > "$REPO/scripts/govern/run-loop.sh"
echo 'echo assert' > "$REPO/scripts/govern/test/assert.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

export GOVERN_DIR="$REPO/scripts/govern"
export GOVERN_SYNC_MARKER="$REPO/scripts/govern/.templates-synced-at"
export GOVERN_TEMPLATE_DIR="$TPL"
bash "$TOOL" --mark "$BASE" >/dev/null

# C1 — the change that WILL be ported (append so both lines stay visible in a diff).
printf 'echo C1_LOCAL_IMPROVEMENT\n' >> "$REPO/scripts/govern/run-loop.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(govern): C1 local improvement"
C1="$(git -C "$REPO" rev-parse HEAD)"

# C2 — the "mid-run" commit that lands AFTER the bound is captured.
printf 'echo C2_MIDRUN_COMMIT\n' >> "$REPO/scripts/govern/run-loop.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(govern): C2 mid-run commit"

# ── 1. bounded to C1: C1 is in scope, C2 is excluded ─────────────────────────────────────────────
rc=0; out="$(GOVERN_SYNC_UPPER_BOUND="$C1" bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "bounded --check → drift exit 3"
assert_contains "$out" "C1 local improvement" "bounded --check sees C1"
assert_not_contains "$out" "C2 mid-run commit" "bounded --check EXCLUDES the mid-run C2"
diff_out="$(GOVERN_SYNC_UPPER_BOUND="$C1" bash "$TOOL" --diff)"
assert_contains "$diff_out" "C1_LOCAL_IMPROVEMENT" "bounded --diff carries C1's change"
assert_not_contains "$diff_out" "C2_MIDRUN_COMMIT" "bounded --diff EXCLUDES C2's change"

# ── 2. advance the marker to C1 → C2 must survive as future drift (not silently lost) ────────────
GOVERN_SYNC_UPPER_BOUND="$C1" bash "$TOOL" --mark "$C1" >/dev/null
rc=0; out="$(bash "$TOOL" --check)" || rc=$?     # unbounded — the real world after the marker moved
assert_eq "$rc" "3" "after --mark C1, unbounded --check STILL reports drift (C2 not lost)"
assert_contains "$out" "C2 mid-run commit" "the mid-run C2 survives as future drift"

assert_done
