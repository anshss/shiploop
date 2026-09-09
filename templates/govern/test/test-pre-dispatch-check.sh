#!/usr/bin/env bash
# pre-dispatch-check.sh — the pre-spawn gates, as one entry point (shiploop 1.19.3, the loop purge).
#
# The gates are FAIL-OPEN by construction: a false "skip"/"refuse" silently drops real work, so only
# positive evidence may withhold a dispatch. These assertions pin that posture, not the individual
# gate logic (each gate keeps its own dedicated test).
#
#   1. an ordinary open ticket verdicts "proceed".
#   2. an NA-marked ticket verdicts "skip: ..." (positive evidence, so withholding is allowed).
#   3. exactly ONE line of verdict on stdout, always (the caller parses it).
#   4. GOVERN_PRE_DISPATCH_CHECK=0 forces "proceed".
#   5. an unknown ticket number does not refuse work: fail-open to "proceed".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

PDC="$DIR/../pre-dispatch-check.sh"
[[ -f "$PDC" ]] || { echo "SKIP: pre-dispatch-check.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/queue"
export GOVERN_QUEUE_DIR="$T/queue"   # TICKETS_FILE is $GOVERN_QUEUE_DIR/tickets.md
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #50 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.

---

## #51 — ops: rotate the provider credential by hand in the console

**Severity:** Low

**NOT govern-automatable:** requires a human in a third-party console; no API exists.

Done when: rotated.
TIX
( cd "$T" && git add -A && git commit -qm init )

run_pdc() { ( cd "$T" && bash "$PDC" "$1" 2>/dev/null ); }

out50="$(run_pdc 50)"
assert_contains "$out50" "proceed" "1. an ordinary open ticket verdicts proceed"
assert_eq "$(printf '%s\n' "$out50" | grep -c .)" "1" "3. the verdict is exactly one line"

out51="$(run_pdc 51)"
assert_contains "$out51" "skip" "2. an NA-marked ticket verdicts skip"

outk="$( cd "$T" && GOVERN_PRE_DISPATCH_CHECK=0 bash "$PDC" 51 2>/dev/null )"
assert_eq "$outk" "proceed" "4. GOVERN_PRE_DISPATCH_CHECK=0 forces proceed"

out99="$(run_pdc 99)"
assert_contains "$out99" "proceed" "5. an unknown ticket fails OPEN (never silently drops work)"

assert_done
