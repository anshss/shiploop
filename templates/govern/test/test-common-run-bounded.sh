#!/usr/bin/env bash
# Unit test of the manual-timeout fallback, govern::_run_with_manual_timeout (lib/common.sh),
# exercised directly regardless of whether `timeout`/`gtimeout` happen to be on THIS machine's
# PATH — stock macOS ships neither, and the fallback must be independently correct, not just
# "never hit in CI".
#
# Covered:
#   1. an expired command reports rc=124 (mirrors GNU timeout) and the expiry is bounded, not
#      left hanging.
#   2. a command that finishes in time returns its real output.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; mk_ws_stub "$T"; source "$DIR/../lib/common.sh"

start=$(date +%s)
out="$(govern::_run_with_manual_timeout 1 sleep 30 2>&1)" && rc=0 || rc=$?
end=$(date +%s)
elapsed=$((end-start))
assert_eq "$rc" "124" "manual-timeout fallback: expired command reports rc=124 (mirrors GNU timeout)"
if [[ "$elapsed" -lt 10 ]]; then
  printf 'ok   - %s\n' "manual-timeout fallback: expiry is bounded (~1s bound, ${elapsed}s elapsed), not left hanging"
else
  printf 'FAIL - %s\n       took %ss\n' "manual-timeout fallback: expiry is bounded" "$elapsed"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

out_b="$(govern::_run_with_manual_timeout 5 printf 'hello-world')"
assert_eq "$out_b" "hello-world" "manual-timeout fallback: a command that finishes in time returns its real output"

rm -rf "$T"
assert_done
