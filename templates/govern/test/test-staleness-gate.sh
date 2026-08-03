#!/usr/bin/env bash
# staleness-gate.sh: exit 10 ONLY on positive evidence (every named path deleted, or the named
# failing test now passing); exit 0 — dispatch — for every other case, including every inconclusive
# one. The fail-open direction is the whole safety property: a false "stale" silently drops real work.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
GATE="$DIR/../staleness-gate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"                       # REPOS=(alpha web); WS_ROOT=$TMP
gitcfg() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; }

# A real git repo at the workspace root: `alpha/gone.js` is committed and then DELETED, so git
# history proves it once existed. `alpha/live.js` stays on disk.
git init -q "$TMP"; gitcfg "$TMP"
mkdir -p "$TMP/alpha"
printf 'export const gone = 1\n' > "$TMP/alpha/gone.js"
printf 'export const live = 1\n' > "$TMP/alpha/live.js"
( cd "$TMP" && git add -A && git commit -q -m init ) >/dev/null 2>&1
rm -f "$TMP/alpha/gone.js"
( cd "$TMP" && git commit -q -am "delete gone.js" ) >/dev/null 2>&1

# `timeout` may be absent on a bare macOS box; the gate then skips the test probe (inconclusive, by
# design). Shim it so the test-command cases are exercised identically everywhere.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift          # drop the seconds argument; the fixtures are instantaneous
exec "$@"
EOF
chmod +x "$TMP/bin/timeout"
export PATH="$TMP/bin:$PATH"

T="$TMP/tickets.md"
cat > "$T" <<'EOF'
## #1 — everything it names is gone
**Severity:** High
**Files:** `alpha/gone.js`
---
## #2 — names a file that still exists
**Severity:** High
**Files:** `alpha/live.js`
---
## #3 — names nothing path-shaped at all
**Severity:** Medium
Where: somewhere in the worker prompt assembly, probably
---
## #4 — names a path git has never heard of
**Severity:** Medium
**Files:** `alpha/never-existed-typo.js`
---
## #5 — its failing test now passes
**Severity:** High
**Files:** `alpha/live.js`
**Test command:** `true`
---
## #6 — its failing test still fails
**Severity:** High
**Files:** `alpha/live.js`
**Test command:** `false`
---
## #7 — mixed: one path gone, one alive
**Severity:** Low
**Files:** `alpha/gone.js`, `alpha/live.js`
---
EOF

run() { # <N> [env...] -> sets RC and OUT
  set +e
  OUT="$(GOVERN_STALENESS_GATE="${SG:-1}" GOVERN_STALENESS_RUN_TESTS="${SGRT:-0}" \
         GOVERN_TICKETS_FILE="$T" "$GATE" "$1" 2>/dev/null)"
  RC=$?
  set -e
}

# ── (a) every named path gone AND git knew it → confidently stale ────────────────────────────────
run 1
assert_eq "$RC" "10" "#1: every named path deleted → exit 10 (stale)"
assert_contains "$OUT" "STALE #1" "#1: verdict line says STALE"
assert_contains "$OUT" "alpha/gone.js" "#1: verdict cites the evidence path"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1" "#1: exactly one stdout line"

# ── path still present → dispatch ────────────────────────────────────────────────────────────────
run 2
assert_eq "$RC" "0" "#2: a path that still exists → exit 0 (dispatch)"
assert_contains "$OUT" "dispatch #2" "#2: verdict line says dispatch"
assert_contains "$OUT" "not stale" "#2: verdict explains why"

# ── inconclusive: no path-shaped token at all → dispatch, never stale ────────────────────────────
run 3
assert_eq "$RC" "0" "#3: no paths named → exit 0 (inconclusive dispatches)"
assert_contains "$OUT" "inconclusive" "#3: verdict is labelled inconclusive"

# ── absence of evidence is NOT evidence: a path git never knew stays inconclusive ────────────────
run 4
assert_eq "$RC" "0" "#4: unknown-to-git missing path → exit 0, NOT stale (no positive evidence)"
assert_not_contains "$OUT" "STALE" "#4: never reports stale on a path that may just be a typo"

# ── (b) executing a queue-authored command is its OWN opt-in ─────────────────────────────────────
# tickets.md is partly machine-written (worker `newTickets[]`, govern-improve-triage proposals), so
# enabling the stat()-only staleness check must NOT also authorize running a backticked string out of
# it. With the gate on but GOVERN_STALENESS_RUN_TESTS unset, the probe is declined, not run.
run 5
assert_eq "$RC" "0" "#5: test probe declined by default → exit 0 (dispatch), even though it would be stale"
assert_contains "$OUT" "GOVERN_STALENESS_RUN_TESTS=0" "#5: verdict names the knob that declined it"
assert_not_contains "$OUT" "now PASSES" "#5: the command was never executed, so there is no verdict about it"

# ── (c) opted in: the named failing test now passes → confidently stale ───────────────────────────
SGRT=1 run 5
assert_eq "$RC" "10" "#5b: opted in + named test now exits 0 → exit 10 (stale)"
assert_contains "$OUT" "now PASSES" "#5b: verdict cites the passing test as the evidence"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1" "#5b: exactly one stdout line"

SGRT=1 run 6
assert_eq "$RC" "0" "#6: opted in + named test still fails → exit 0 (dispatch)"
assert_contains "$OUT" "still exits 1" "#6: verdict reports the test's real exit code"

# ── partial deletion is NOT evidence — "every named path" means every one ────────────────────────
run 7
assert_eq "$RC" "0" "#7: one gone + one alive → exit 0, NOT stale"

# ── kill switch: ships inert, defaults to OFF ────────────────────────────────────────────────────
set +e
OUT_OFF="$(GOVERN_TICKETS_FILE="$T" "$GATE" 1 2>/dev/null)"; RC_OFF=$?
set -e
assert_eq "$RC_OFF" "0" "default (GOVERN_STALENESS_GATE unset) dispatches even the stale #1"
assert_contains "$OUT_OFF" "disabled" "default verdict says the gate is disabled"

set +e
GOVERN_STALENESS_GATE=0 GOVERN_TICKETS_FILE="$T" "$GATE" 1 >/dev/null 2>&1; RC_0=$?
set -e
assert_eq "$RC_0" "0" "GOVERN_STALENESS_GATE=0 dispatches the stale #1"

# ── unknown ticket number → dispatch, and a non-numeric argument → usage error (never 10) ────────
run 999
assert_eq "$RC" "0" "a ticket number not in the file → exit 0 (dispatch)"
set +e
GOVERN_STALENESS_GATE=1 GOVERN_TICKETS_FILE="$T" "$GATE" not-a-number >/dev/null 2>&1; RC_BAD=$?
set -e
assert_eq "$RC_BAD" "2" "non-numeric argument → usage exit 2 (callers treat any non-10 as dispatch)"

# ── deterministic by design: zero model invocations ──────────────────────────────────────────────
assert_eq "$(grep -vE '^[[:space:]]*#' "$GATE" | grep -cE '(^|[^a-zA-Z_-])claude([^a-zA-Z_.-]|$)' || true)" "0" \
  "staleness-gate.sh invokes claude ZERO times"

assert_done
