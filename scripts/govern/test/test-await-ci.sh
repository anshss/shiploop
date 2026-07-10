#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
AWAIT="$DIR/../await-ci.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"  # hermetic workspace stub (independent of the live workspace.sh)

# Fake gh that branches on the subcommand so the two-signal fail-closed logic can be exercised:
#   `gh pr checks … --json bucket`        → emits $FAKE_CHECKS (or exits 1 if FAKE_CHECKS_FAIL=1)
#   `gh pr view … --json statusCheckRollup` → emits $FAKE_ROLLUP (or exits 1 if FAKE_ROLLUP_FAIL=1)
# A non-zero exit with NO stdout models a real gh error (network/auth/5xx) — the case the old
# `… 2>/dev/null || echo '[]'` conflated with "no checks" and auto-merged (#34b fail-open).
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"pr checks"* ]]; then
  [[ "${FAKE_CHECKS_FAIL:-0}" == "1" ]] && exit 1
  printf '%s' "$FAKE_CHECKS"; exit 0
fi
if [[ "$args" == *"pr view"* ]]; then
  [[ "${FAKE_ROLLUP_FAIL:-0}" == "1" ]] && exit 1
  printf '%s' "$FAKE_ROLLUP"; exit 0
fi
exit 0
EOF
chmod +x "$TMP/gh"

# run <checks-json> [rollup-json] — fast (no real sleeps): 0s grace, err after 1 gh failure.
run() {
  PATH="$TMP:$PATH" GOVERN_CI_MAX_TRIES=1 GOVERN_CI_NONE_GRACE=0 GOVERN_CI_ERR_MAX=1 \
    FAKE_CHECKS="${1:-}" FAKE_ROLLUP="${2:-}" "$AWAIT" alpha 1
}

# ── happy paths (unchanged behaviour) ────────────────────────────────────────
assert_eq "$(run '[{"bucket":"pass"},{"bucket":"pass"}]')" "green"   "all pass → green"
assert_eq "$(run '[{"bucket":"pass"},{"bucket":"fail"}]')" "red"     "any fail → red"
assert_eq "$(run '[{"bucket":"pending"}]')"                "pending" "pending → pending"

# ── verified-none: checks empty AND statusCheckRollup empty → none (exit 0) ───
assert_eq "$(run '[]' '{"statusCheckRollup":[]}')"   "none" "checks [] + rollup [] → verified none"
assert_eq "$(run '[]' '{"statusCheckRollup":null}')" "none" "checks [] + rollup null → verified none"

# ── fail-closed: an ERRORING gh (exit 1, no JSON) must NOT become none/exit-0 ─
set +e
out="$(PATH="$TMP:$PATH" GOVERN_CI_MAX_TRIES=1 GOVERN_CI_NONE_GRACE=0 GOVERN_CI_ERR_MAX=1 \
  FAKE_CHECKS_FAIL=1 FAKE_CHECKS='' FAKE_ROLLUP='' "$AWAIT" alpha 1 2>/dev/null)"; rc=$?
set -e
assert_eq "$out" "error" "gh pr checks error → 'error' (NOT none)"
assert_eq "$rc"  "3"     "gh pr checks error → non-zero exit (3)"

# ── fail-closed: checks empty but the none-VERIFICATION call fails → error ────
set +e
out="$(PATH="$TMP:$PATH" GOVERN_CI_MAX_TRIES=1 GOVERN_CI_NONE_GRACE=0 GOVERN_CI_ERR_MAX=1 \
  FAKE_CHECKS='[]' FAKE_ROLLUP_FAIL=1 FAKE_ROLLUP='' "$AWAIT" alpha 1 2>/dev/null)"; rc=$?
set -e
assert_eq "$out" "error" "checks [] but rollup verify fails → 'error' (NOT none)"
assert_eq "$rc"  "3"     "rollup verify failure → non-zero exit (3)"

# ── registration lag: checks empty but rollup HAS checks → keep polling, not none
assert_eq "$(run '[]' '{"statusCheckRollup":[{"state":"PENDING"}]}')" "pending" \
  "checks [] but rollup non-empty (fresh-PR lag) → pending, never none"

assert_done
