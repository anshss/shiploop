#!/usr/bin/env bash
# Driver-model run-dir stamp: logs/govern/<run>/driver-model, one line, the orchestrating (driver)
# session's own bare tier (haiku/sonnet/opus). Sibling of govern::stamp_run_version's
# logs/govern/<run>/shiploop-version, same file, same never-abort-a-dispatch contract, called from
# the SAME spot in spawn-worker.sh. Not a lever event: this stamp exists so a cost comparison can
# price what it credits at the tier that actually dispatched a run instead of guessing the highest
# tier observed anywhere in it, which is biased toward the most expensive tier and so toward
# shiploop's own credit. Unconditional: it must work on corpora where GOVERN_LEVER_EVENTS stays off.
#
# Covered:
#   1. govern::model_family: bare alias, full id, a [1m] context-window suffix, a dated build id,
#      an unknown model, and empty input.
#   2. govern::stamp_driver_model PRESENT: a detectable session model writes the bare family name.
#   3. govern::stamp_driver_model ABSENT: a genuinely undetectable session (every resolution source
#      unset at once, matching test-model-ceiling.sh's own idiom) writes nothing, and the function
#      still returns 0.
#   4. an unwritable run dir does not abort the caller (return 0, no file), the same property
#      test-lever-events.sh asserts for the lever-events emitter.
#   4b. the SAME unwritable-run-dir property for govern::stamp_run_version's own write, which had
#       the identical shape and the identical "never aborts" claim without the guard to back it up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# ── 1. govern::model_family ─────────────────────────────────────────────────────────────────────
fam() { ( source "$COMMON"; govern::model_family "$1" ); }
assert_eq "$(fam opus)"                              "opus"   "1. bare alias 'opus'"
assert_eq "$(fam claude-sonnet-5)"                    "sonnet" "1. full id 'claude-sonnet-5'"
assert_eq "$(fam 'claude-opus-5[1m]')"                 "opus"   "1. a [1m] context-window suffix does not change the family"
assert_eq "$(fam claude-haiku-4-5-20251001)"          "haiku"  "1. a dated build id still resolves to its family"
assert_eq "$(fam gpt-nano)"                           ""       "1. an unknown model → empty (no family)"
assert_eq "$(fam '')"                                 ""       "1. empty input → empty"

# ── 2. PRESENT ───────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/run-present"
GOVERN_WS_ROOT="$T" GOVERN_SESSION_MODEL="claude-sonnet-5" bash -c '
  set -euo pipefail
  source "$1"
  govern::stamp_driver_model "$2"
' _ "$COMMON" "$T/run-present"
assert_eq "$(cat "$T/run-present/driver-model" 2>/dev/null || echo MISSING)" "sonnet" \
  "2. a detectable session model → driver-model carries the bare family name"

# ── 3. ABSENT (genuinely undetectable) ──────────────────────────────────────────────────────────
# env -u, not unset: the ambient session driving THIS suite really does have a transcript on disk
# (test-model-ceiling.sh's own reasoning for the same idiom), so this must be `env -u`, never a bare
# `unset` inside the sourcing shell.
mkdir -p "$T/run-absent"
out3="$(env -u GOVERN_SESSION_MODEL -u ANTHROPIC_MODEL -u CLAUDE_CODE_SESSION_ID \
  GOVERN_WS_ROOT="$T" bash -c '
    set -euo pipefail
    source "$1"
    govern::stamp_driver_model "$2"
    echo "rc=$?"
  ' _ "$COMMON" "$T/run-absent")"
assert_contains "$out3" "rc=0" "3. an undetectable session still returns 0 (never a caller-visible failure)"
[[ -f "$T/run-absent/driver-model" ]] && present3=yes || present3=no
assert_eq "$present3" "no" "3. an undetectable session model writes NOTHING, not a guess"

# ── 4. unwritable run dir does not abort the caller ─────────────────────────────────────────────
RO="$T/readonly"; mkdir -p "$RO"; chmod 0555 "$RO"
if ( : > "$RO/sub/probe" ) 2>/dev/null; then
  echo "SKIP: sandbox permits writes under a chmod 0555 dir (likely running as root): case 4 not exercisable" >&2
else
  out4="$(GOVERN_WS_ROOT="$T" GOVERN_SESSION_MODEL=opus bash -c '
    set -euo pipefail
    source "$1"
    govern::stamp_driver_model "$2"
    echo "SURVIVED rc=$?"
  ' _ "$COMMON" "$RO/sub" 2>/dev/null)"
  assert_contains "$out4" "SURVIVED rc=0" \
    "4. an unwritable run dir (mkdir -p fails, the write fails) still returns 0 under set -e"
  [[ -f "$RO/sub/driver-model" ]] && wrote4=yes || wrote4=no
  assert_eq "$wrote4" "no" "4. nothing is written when the target directory could not be created"

  # 4b. govern::stamp_run_version's SIBLING write has the exact same shape and the same "never
  # aborts" claim in its own comment; this asserts the property this ticket's fix restores for it.
  # A non-empty .harness-version is required first, or `$v` is empty and the write never fires at
  # all, proving nothing about the guard.
  printf '9.9.9\n' > "$T/scripts/lib/.harness-version"
  out4b="$(GOVERN_WS_ROOT="$T" bash -c '
    set -euo pipefail
    source "$1"
    govern::stamp_run_version "$2"
    echo "SURVIVED rc=$?"
  ' _ "$COMMON" "$RO/sub" 2>/dev/null)"
  assert_contains "$out4b" "SURVIVED rc=0" \
    "4b. govern::stamp_run_version: same unwritable-run-dir property now holds (its own write, fixed alongside)"
  [[ -f "$RO/sub/shiploop-version" ]] && wrote4b=yes || wrote4b=no
  assert_eq "$wrote4b" "no" "4b. nothing is written for the version stamp either when the target directory could not be created"
fi
chmod 0755 "$RO"

assert_done
