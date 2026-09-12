#!/usr/bin/env bash
# Unit proof for govern::validation_gate_action: the pure gate-decision helper that
# resolve-ticket.sh uses to decide whether a validation-type resolved report auto-resolves, parks for a
# missing test, or parks+escalates a gate-FAILED (measured-negative) result.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

action() { GOVERN_TICKETS_FILE=/dev/null bash -c 'source "'"$COMMON"'"; govern::validation_gate_action "$1"' _ "$1"; }

# Ran the test, gate FAILED (gatePassed=false) → must PARK, not auto-ship.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"gatePassed":false,"evidence":"measured negative — FAIL"}}')" \
  "park-gate-failed" "ran + gate FAILED → park-gate-failed (jq // false-vs-null trap covered)"

# gate PASSED → auto-resolve.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"gatePassed":true,"evidence":"measured positive — PASS"}}')" \
  "resolve" "gate passed → resolve"

# No evidence / test not run → park for a real test.
assert_eq "$(action '{"validation":null}')" \
  "park-no-evidence" "validation null → park-no-evidence"
assert_eq "$(action '{"validation":{"ranLiveTest":false,"evidence":""}}')" \
  "park-no-evidence" "ranLiveTest false → park-no-evidence"
assert_eq "$(action '{"validation":{"ranLiveTest":true,"evidence":""}}')" \
  "park-no-evidence" "ran but empty evidence → park-no-evidence"

# Backward-compat: ran with evidence but NO explicit gate field (workers predating the gate / non-gated) → resolve.
assert_eq "$(action '{"validation":{"ranLiveTest":true,"evidence":"ran, no explicit gate"}}')" \
  "resolve" "no gatePassed field → resolve (workers predating the gate unaffected)"

assert_done
