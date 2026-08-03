#!/usr/bin/env bash
# verify-filter.sh: a PASSING command collapses to one line, a FAILING one keeps its output, and the
# wrapped exit code survives verbatim (callers branch on it — this is the load-bearing property).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
VF="$DIR/../verify-filter.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"

# ── passing command: exactly one summary line, none of the command's own output ──────────────────
out="$("$VF" -- bash -c 'for i in 1 2 3 4 5; do echo "noisy pass line $i"; done' 2>&1)"; rc=$?
assert_eq "$rc" "0" "passing command exits 0"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "passing command collapses to exactly ONE line"
assert_contains "$out" "PASS:" "summary line is marked PASS"
assert_contains "$out" "5 lines suppressed" "summary reports the suppressed line count"
assert_not_contains "$out" "noisy pass line 3" "no passing output leaks into context"

# `--` is optional.
# The echoed token must NOT appear in the argv, or the summary's own command label would match it.
out_nodash="$("$VF" bash -c 'printf "%s\n" "$(echo ZAP)-OUTPUT"' 2>&1)"
assert_contains "$out_nodash" "PASS:" "works without the -- separator"
assert_not_contains "$out_nodash" "ZAP-OUTPUT" "no passing output leaks without --"

# ── failing command: output preserved, exit code preserved EXACTLY ───────────────────────────────
set +e
out2="$("$VF" -- bash -c 'echo "the actual error"; echo "second detail line"; exit 3' 2>&1)"; rc2=$?
set -e
assert_eq "$rc2" "3" "failing command's exit code is reproduced exactly (3, not 1)"
assert_contains "$out2" "the actual error" "failing output is preserved"
assert_contains "$out2" "second detail line" "all failing output is preserved when under the cap"
assert_contains "$out2" "FAIL(3):" "summary line reports the real exit code"
assert_not_contains "$out2" "output truncated" "no truncation marker when under the cap"

# stderr is captured too — a test runner that writes diagnostics to fd 2 must not lose them.
set +e
out3="$("$VF" -- bash -c 'echo "stderr detail" >&2; exit 1' 2>&1)"; rc3=$?
set -e
assert_eq "$rc3" "1" "exit 1 preserved"
assert_contains "$out3" "stderr detail" "stderr of a failing command is preserved"

# ── tail bound on failing output ────────────────────────────────────────────────────────────────
set +e
out4="$(GOVERN_VERIFY_FILTER_MAX_LINES=5 "$VF" -- bash -c \
  'for i in $(seq 1 40); do echo "line $i"; done; exit 2' 2>&1)"; rc4=$?
set -e
assert_eq "$rc4" "2" "exit 2 preserved under truncation"
assert_contains "$out4" "output truncated: showing the LAST 5 of 40 lines" "truncation is clearly marked"
assert_contains "$out4" "line 40" "the TAIL is kept (where the failure actually is)"
assert_not_contains "$out4" "line 20" "the head is dropped"

# ── kill switch: transparent pass-through ───────────────────────────────────────────────────────
out5="$(GOVERN_VERIFY_FILTER=0 "$VF" -- bash -c 'echo verbatim-output' 2>&1)"; rc5=$?
assert_eq "$rc5" "0" "kill switch preserves a passing exit code"
assert_eq "$out5" "verbatim-output" "GOVERN_VERIFY_FILTER=0 is a fully transparent wrapper"

set +e
GOVERN_VERIFY_FILTER=0 "$VF" -- bash -c 'exit 7' >/dev/null 2>&1; rc6=$?
set -e
assert_eq "$rc6" "7" "kill switch preserves a failing exit code"

# ── hygiene: no temp files left behind, and zero model invocations in the script ─────────────────
before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'govern-verify-filter.*' 2>/dev/null | wc -l | tr -d ' ')"
"$VF" -- true >/dev/null 2>&1
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'govern-verify-filter.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$after" "$before" "temp capture file is cleaned up on exit"

# The three new mechanisms are deterministic BY DESIGN — a `claude` invocation here would be a
# recurring bill on the hottest path in the loop. Guard it in the test, not just in review.
assert_eq "$(grep -vE '^[[:space:]]*#' "$VF" | grep -cE '(^|[^a-zA-Z_-])claude([^a-zA-Z_.-]|$)' || true)" "0" \
  "verify-filter.sh invokes claude ZERO times"

assert_done
