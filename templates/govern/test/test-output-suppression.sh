#!/usr/bin/env bash
# bench lever: verify-filter.sh's output-suppression event (bench/LEVER-EVENTS.md).
#
# The lever is the one whose evidence is destroyed by design: verify-filter.sh captures a passing
# command's output to a temp file, prints only a summary, and deletes the file on exit. These
# assertions pin the ONE moment the withheld size is knowable, and pin the wrapper's hard contract
# (the wrapped command's exit code) against the new emit path.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

VF="$DIR/../verify-filter.sh"
[ -f "$VF" ] || { echo "SKIP: verify-filter.sh not present" >&2; exit 77; }

setup() { T="$(mktemp -d)"; mkdir -p "$T/run"; }
teardown() { rm -rf "$T"; }
ev() { cat "$T/run/lever-events.jsonl" 2>/dev/null; }
noise() { seq 1 400 | sed 's/^/green output line /'; }

# ── 1. PASS: the event is written, and it carries the real withheld size ─────
setup
out="$(GOVERN_LEVER_EVENTS=1 GOVERN_RUN_DIR="$T/run" GOVERN_TICKET=108 \
  bash "$VF" -- bash -c 'seq 1 400 | sed "s/^/green output line /"' 2>&1)"
rc=$?
assert_eq "$rc" "0" "a passing command still exits 0 through the wrapper"
assert_contains "$out" "PASS:" "the summary line is still printed"
line="$(ev)"
assert_eq "$(printf '%s' "$line" | jq -r '.event')" "output-suppression" "event name"
assert_eq "$(printf '%s' "$line" | jq -r '.ticket')" "108" "ticket comes from GOVERN_TICKET"
assert_eq "$(printf '%s' "$line" | jq -r '.outcome')" "pass" "outcome is pass"
assert_eq "$(printf '%s' "$line" | jq -r '.withheldLines')" "400" "withheldLines is the real count"
# withheldBytes must be a NUMBER and must match the bytes the command actually produced.
expected_bytes="$(noise | wc -c | tr -d '[:space:]')"
assert_eq "$(printf '%s' "$line" | jq -r '.withheldBytes')" "$expected_bytes" \
  "withheldBytes equals the bytes the wrapped command actually produced"
assert_eq "$(printf '%s' "$line" | jq -r '.withheldBytes | type')" "number" "withheldBytes is JSON number, not string"
teardown

# ── 2. FAIL: no event, and the exit code is reproduced exactly ───────────────
# A failing run is passed through (tail-bounded), so only PART of it is withheld. Crediting the
# full capture there would inflate the lever, so nothing is emitted at all.
setup
GOVERN_LEVER_EVENTS=1 GOVERN_RUN_DIR="$T/run" bash "$VF" -- bash -c 'echo boom; exit 7' >/dev/null 2>&1
assert_eq "$?" "7" "a failing command's exit code is reproduced exactly"
assert_eq "$(ev | wc -l | tr -d '[:space:]')" "0" "a FAILING run emits no suppression event"
teardown

# ── 3. kill switch ──────────────────────────────────────────────────────────
setup
GOVERN_LEVER_EVENTS=0 GOVERN_RUN_DIR="$T/run" bash "$VF" -- bash -c 'echo hi' >/dev/null 2>&1
assert_eq "$?" "0" "kill switch does not disturb the exit code"
assert_eq "$(ev | wc -l | tr -d '[:space:]')" "0" "GOVERN_LEVER_EVENTS=0 emits nothing"
teardown

# ── 4. default ON: nothing set at all still records ─────────────────────────
setup
env -u GOVERN_LEVER_EVENTS GOVERN_RUN_DIR="$T/run" bash "$VF" -- bash -c 'echo hi' >/dev/null 2>&1
assert_eq "$(ev | wc -l | tr -d '[:space:]')" "1" "with the flag unset entirely, the default records"
teardown

# ── 5. unwritable run dir must not break the wrapped command ────────────────
setup
chmod 0555 "$T/run"
GOVERN_LEVER_EVENTS=1 GOVERN_RUN_DIR="$T/run" bash "$VF" -- bash -c 'echo hi' >/dev/null 2>&1
assert_eq "$?" "0" "an unwritable run dir never changes the wrapped command's exit code"
chmod 0755 "$T/run"
teardown

# ── 6. transparent mode is untouched by the emit path ───────────────────────
setup
out="$(GOVERN_VERIFY_FILTER=0 GOVERN_LEVER_EVENTS=1 GOVERN_RUN_DIR="$T/run" \
  bash "$VF" -- bash -c 'echo verbatim' 2>&1)"
assert_contains "$out" "verbatim" "transparent mode still passes output through verbatim"
assert_eq "$(ev | wc -l | tr -d '[:space:]')" "0" "transparent mode suppresses nothing, so records nothing"
teardown

assert_done
