#!/usr/bin/env bash
# The suite runner (tools/run-suite.sh) must reproduce the shard job's semantics
# with ONE definition of the run order, and its guards must actually fire:
#   1. order = the hint's live entries (slowest first, stale skipped) + every
#      remaining test file alphabetically in the tail;
#   2. the coverage assertion FAILS if the built order ever drops or duplicates
#      a test file (a shard split would silently lose coverage while CI stayed
#      green): negative controls are a dropped line and a duplicated line;
#   3. --shard round-robin partitions union to the full order, each file exactly
#      once;
#   4. --jobs N reports the SAME pass/fail/skip set as the sequential run on a
#      fixture suite with a deliberately broken test, and exits nonzero naming
#      the failure;
#   5. with --hub-context given, a skip NOT covered by the list is a hard
#      failure (a skip that runs in no job is silently dead coverage);
#   6. the order check runs the selection REVERSED and fails naming any test
#      whose verdict differs between the two passes; default ON for a full run,
#      OFF for a shard run, an explicit --order-check 0|1 always wins.
#
# Runs with -e OFF throughout (the runner's failure paths are exercised as
# return codes, and assert.sh records failures without aborting).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +e
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
RUNNER="$HUB/tools/run-suite.sh"
if [ ! -f "$RUNNER" ]; then
  echo "SKIP: hub runner not found at $RUNNER"
  exit 77
fi
bash -n "$RUNNER" || { echo "FAIL: run-suite.sh does not parse"; exit 1; }

# Load the runner's functions WITHOUT executing it (its main entry only fires
# when the file is run directly).
# shellcheck disable=SC1090
source "$RUNNER"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FX="$T/suite"
LOGS="$T/logs"
mkdir -p "$FX"

printf '#!/usr/bin/env bash\nexit 0\n'                         > "$FX/test-aa-pass.sh"
printf '#!/usr/bin/env bash\necho broken on purpose\nexit 3\n' > "$FX/test-bb-broken.sh"
printf '#!/usr/bin/env bash\nexit 77\n'                        > "$FX/test-cc-skips.sh"
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 0\n'              > "$FX/test-dd-slow-pass.sh"

printf '%s\n' \
  '# comment line' \
  'test-bb-broken' \
  'test-zz-gone' \
  > "$T/hint.txt"

# ── 1. order: live hint entries first, stale skipped, tail alphabetically ────
build_order "$FX" "$T/hint.txt" "$T/order.txt"
assert_eq "$(cat "$T/order.txt")" \
          "$(printf 'test-bb-broken\ntest-aa-pass\ntest-cc-skips\ntest-dd-slow-pass')" \
          "order = hint entries then alphabetical tail"
if grep -q 'test-zz-gone' "$T/order.txt"; then
  echo "FAIL: stale hint entry leaked into order"
  exit 1
fi
echo "ok - stale hint entry skipped"

# ── 2. coverage assertion: fires on a dropped file, and on a duplicate ──────
assert_coverage "$FX" "$T/order.txt" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: coverage assertion rejected the correct order"
  exit 1
fi
echo "ok - coverage assertion accepts the built order"

head -3 "$T/order.txt" > "$T/order-dropped.txt"   # test-dd-slow-pass removed
assert_coverage "$FX" "$T/order-dropped.txt" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL: coverage assertion did NOT fire on a dropped test file"
  exit 1
fi
echo "ok - coverage assertion fires on a dropped test file (negative control)"

{ cat "$T/order.txt"; echo 'test-aa-pass'; } > "$T/order-dup.txt"
assert_coverage "$FX" "$T/order-dup.txt" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL: coverage assertion did NOT fire on a duplicated test file"
  exit 1
fi
echo "ok - coverage assertion fires on a duplicated test file (negative control)"

# ── 3. shard partitions: union = full order, each exactly once ───────────────
: > "$T/union.txt"
for i in 1 2 3; do
  select_shard "$T/order.txt" "$i" 3 "$T/shard-$i.txt"
  cat "$T/shard-$i.txt" >> "$T/union.txt"
done
assert_eq "$(sort "$T/union.txt")" "$(sort "$T/order.txt")" "shard 1..3 of 3 union == order"
if [ "$(sort -u "$T/union.txt" | wc -l | tr -d ' ')" != "4" ]; then
  echo "FAIL: shard partitions overlap or drop coverage"
  exit 1
fi
echo "ok - 3 shard partitions cover all files exactly once"

# ── 4. sequential vs --jobs: same pass/fail set, nonzero exit naming the fail ─
run_suite_case() { # <extra flags...> <out_file>; returns the runner's exit code
  local rc=0 extra_out="$1"
  shift
  main --suite-dir "$FX" --hint "$T/hint.txt" --log-dir "$LOGS" "$@" > "$extra_out" 2>&1 || rc=$?
  return "$rc"
}

set +e
run_suite_case "$T/seq.out" --jobs 1
rc_seq=$?
set -e
set +e
if [ "$rc_seq" -ne 1 ]; then
  echo "FAIL: sequential run exit=$rc_seq, want 1"
  exit 1
fi
grep -q '^FAIL - test-bb-broken$' "$T/seq.out" \
  || { echo "FAIL: sequential output does not name the broken test"; cat "$T/seq.out"; exit 1; }
grep -q '^ok   - test-aa-pass$' "$T/seq.out" \
  || { echo "FAIL: sequential output missing pass line"; exit 1; }
grep -q '^skip - test-cc-skips' "$T/seq.out" \
  || { echo "FAIL: sequential output missing skip line"; exit 1; }
echo "ok - sequential run: exit 1, names the broken test, pass+skip lines present"

run_suite_case "$T/par.out" --jobs 2
rc_par=$?
if [ "$rc_par" -ne "$rc_seq" ]; then
  echo "FAIL: --jobs 2 exit=$rc_par, sequential was $rc_seq"
  exit 1
fi
set -e
set +e
# Same pass/fail/skip SET as sequential, independent of line order.
assert_eq "$(grep -E '^(ok|FAIL|skip) - ' "$T/par.out" | sort)" \
          "$(grep -E '^(ok|FAIL|skip) - ' "$T/seq.out" | sort)" \
          "--jobs 2 reports the same pass/fail/skip set as sequential"
if [ "$(cat "$LOGS/test-bb-broken.rc")" != "3" ]; then
  echo "FAIL: --jobs mode lost the broken test's exit code"
  exit 1
fi
if ! grep -q 'broken on purpose' "$LOGS/test-bb-broken.log"; then
  echo "FAIL: per-test log not captured in --jobs mode"
  exit 1
fi
echo "ok - --jobs 2: same pass/fail set as sequential, per-test logs and exit codes captured"

# ── 5. skip accounting: an uncovered skip is a hard failure only when asked ──
printf 'test-cc-skips\n' > "$T/ctx-listed.txt"
printf 'nothing-here\n'  > "$T/ctx-empty.txt"
run_suite_case "$T/ctx-listed.out" --hub-context "$T/ctx-listed.txt"
grep -q 'covered by the hub-context list' "$T/ctx-listed.out" \
  || { echo "FAIL: listed skip not recognized as covered"; exit 1; }
run_suite_case "$T/ctx-empty.out" --hub-context "$T/ctx-empty.txt"
rc_uncovered=$?
set -e
set +e
if [ "$rc_uncovered" -eq 0 ]; then
  echo "FAIL: uncovered skip did not fail the run"
  exit 1
fi
grep -q 'runs in NO job' "$T/ctx-empty.out" \
  || { echo "FAIL: uncovered skip not reported"; exit 1; }
echo "ok - --hub-context: uncovered skip fails the run, listed skip passes"

# ── 6. order check: a verdict that flips with run order is named and fails ───
# Fixture pair that is order-dependent BY CONSTRUCTION: the planter writes a
# marker file at a fixed path, the detector consumes it and fails when it is
# present. Canonical order (planter, detector): detector fails. Reversed:
# detector passes. The verdicts differ, so the order check must fail the run
# naming the detector.
FXO="$T/suite-order"
mkdir -p "$FXO"
printf '#!/usr/bin/env bash\nprintf x > "$ORDERCHECK_MARKER_DIR/marker"\necho planted\nexit 0\n' > "$FXO/test-ka-planter.sh"
cat > "$FXO/test-kz-detect.sh" <<'EOF'
#!/usr/bin/env bash
if [ -f "$ORDERCHECK_MARKER_DIR/marker" ]; then
  rm -f "$ORDERCHECK_MARKER_DIR/marker"
  echo "marker present"
  exit 1
fi
echo "clean"
exit 0
EOF
chmod +x "$FXO"/test-*.sh
ORDERCHECK_MARKER_DIR="$T/marker-dir"
mkdir -p "$ORDERCHECK_MARKER_DIR"
export ORDERCHECK_MARKER_DIR

rm -f "$ORDERCHECK_MARKER_DIR/marker"
rc_ord=0
main --suite-dir "$FXO" --order-check 1 --log-dir "$T/logs-ord" > "$T/order.out" 2>&1 || rc_ord=$?
if [ "$rc_ord" -eq 0 ]; then
  echo "FAIL: order check passed a suite whose verdict flips with order"; cat "$T/order.out"; exit 1
fi
grep -q '^::error::order-dependent test: test-kz-detect' "$T/order.out" \
  || { echo "FAIL: order check did not name the order-dependent test"; cat "$T/order.out"; exit 1; }
grep -q '^order-check reversed pass:' "$T/order.out" \
  || { echo "FAIL: order check did not report the reversed pass"; cat "$T/order.out"; exit 1; }
echo "ok - order check fails the run naming the order-dependent test"

rm -f "$ORDERCHECK_MARKER_DIR/marker"
rc_noord=0
main --suite-dir "$FXO" --order-check 0 --log-dir "$T/logs-noord" > "$T/order-off.out" 2>&1 || rc_noord=$?
if grep -q '^order-check reversed pass:' "$T/order-off.out"; then
  echo "FAIL: --order-check 0 still ran the reversed pass"; exit 1
fi
if [ "$rc_noord" -ne 1 ]; then
  echo "FAIL: --order-check 0 lost the canonical failure (exit=$rc_noord)"; exit 1
fi
echo "ok - --order-check 0 runs the canonical pass only"

rm -f "$ORDERCHECK_MARKER_DIR/marker"
rc_shard=0
main --suite-dir "$FXO" --shard 1/1 --log-dir "$T/logs-shard" > "$T/order-shard.out" 2>&1 || rc_shard=$?
if grep -q '^order-check reversed pass:' "$T/order-shard.out"; then
  echo "FAIL: a shard run defaulted the order check ON"; exit 1
fi
echo "ok - shard runs default the order check OFF"

# Green control: verdicts identical in both orders pass the check and the run.
FXG="$T/suite-order-green"
mkdir -p "$FXG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FXG/test-ka-ok.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FXG/test-kz-ok.sh"
rc_green=0
main --suite-dir "$FXG" --order-check 1 --log-dir "$T/logs-green" > "$T/order-green.out" 2>&1 || rc_green=$?
if [ "$rc_green" -ne 0 ]; then
  echo "FAIL: order check reddened an order-independent suite (exit=$rc_green)"; cat "$T/order-green.out"; exit 1
fi
grep -q '^ok - order check: every verdict identical in both orders$' "$T/order-green.out" \
  || { echo "FAIL: green order check did not report the invariant"; cat "$T/order-green.out"; exit 1; }
echo "ok - order check passes an order-independent suite"

unset ORDERCHECK_MARKER_DIR

assert_done
