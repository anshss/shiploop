#!/usr/bin/env bash
# Unit proof for govern::validation_gate_action (#67 + #73): the pure gate-decision helper that
# run-loop.sh uses to decide whether a validation-type resolved report auto-resolves, parks for a
# missing test (#67), or parks+escalates a gate-FAILED (measured-negative) result (#73).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

action() { GOVERN_TICKETS_FILE=/dev/null bash -c 'source "'"$COMMON"'"; govern::validation_gate_action "$1"' _ "$1"; }

# #73: ran the test, gate FAILED (gatePassed=false) → must PARK, not auto-ship.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"gatePassed":false,"evidence":"measured negative — FAIL"}}')" \
  "park-gate-failed" "#73: ran + gate FAILED → park-gate-failed (jq // false-vs-null trap covered)"

# gate PASSED → auto-resolve.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"gatePassed":true,"evidence":"measured positive — PASS"}}')" \
  "resolve" "gate passed → resolve"

# #67: no evidence / test not run → park for a real test.
assert_eq "$(action '{"validation":null}')" \
  "park-no-evidence" "#67: validation null → park-no-evidence"
assert_eq "$(action '{"validation":{"ranLiveTest":false,"evidence":""}}')" \
  "park-no-evidence" "#67: ranLiveTest false → park-no-evidence"
assert_eq "$(action '{"validation":{"ranLiveTest":true,"evidence":""}}')" \
  "park-no-evidence" "#67: ran but empty evidence → park-no-evidence"

# Backward-compat: ran with evidence but NO explicit gate field (pre-#73 workers / non-gated) → resolve.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"evidence":"ran, no explicit gate"}}')" \
  "resolve" "no gatePassed field → resolve (pre-#73 workers unaffected)"

assert_done
