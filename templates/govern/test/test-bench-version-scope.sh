#!/usr/bin/env bash
# bench: version-scoped replay corpus.
#
# `bench/fixtures/replay-version-fleet` has three run directories: one unstamped-legacy (no
# shiploop-version file, as if dispatched before version-scoping shipped), one stamped 1.18.0, one
# stamped 1.19.0. Each run holds exactly one ticket with one session, so run count == session count ==
# ticket count throughout, which makes every assertion below unambiguous.
#
#   run-20260501-000000  ticket-200  unstamped-legacy       input 1,000 / output 100
#   run-20260601-000000  ticket-201  shiploop-version 1.18.0 input 2,000 / output 200
#   run-20260701-000000  ticket-202  shiploop-version 1.19.0 input 3,000 / output 300
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/replay.mjs" ] && [ -d "$HUB/bench/fixtures/replay-version-fleet" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 77; }

FLEET="$HUB/bench/fixtures/replay-version-fleet"
run_replay() { node "$HUB/bench/replay.mjs" --fleet "$FLEET" "$@" 2>&1; }

# ── default: scoped to the newest stamped version ────────────────────────────
def_j="$(run_replay --arm 1m --json)"
assert_eq "$?" "0" "replay.mjs exits 0 on the version fixture"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.mode')" "latest" \
  "default mode is latest-version-only"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.selected')" "1.19.0" \
  "the newest STAMPED version is selected, not the newest run regardless of stamp"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.fellBack')" "false" \
  "a corpus with at least one stamp never silently falls back"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.runsTotal')" "3" "three runs total"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.runsKept')" "1" \
  "only the 1.19.0 run is kept"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.runsExcludedOlder')" "1" \
  "the 1.18.0 run is excluded as older-stamped"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.runsExcludedUnstamped')" "1" \
  "the unstamped run is excluded and counted SEPARATELY from the older-stamped one"
assert_eq "$(printf '%s' "$def_j" | jq -r '.meta.versionScope.sessionsKept')" "1" \
  "session counts track run counts 1:1 in this fixture"
assert_eq "$(printf '%s' "$def_j" | jq -r '.arms["1m"].tickets')" "1" \
  "only ticket 202 (the 1.19.0 run) feeds the arm"
assert_eq "$(printf '%s' "$def_j" | jq -r '.arms["1m"].shiploopTokens')" "3300" \
  "ticket 202's own tokens (3,000 input + 300 output), not the pooled corpus"

def_report="$(run_replay --arm 1m)"
assert_contains "$def_report" "1.19.0 (newest stamped)" "the human report names the selected version"
assert_contains "$def_report" "kept 1/3 runs, 1/3 sessions" "and how much of the corpus that kept"
assert_contains "$def_report" "excluded 1 older-stamped, 1 unstamped-legacy" \
  "and splits the exclusions into the two disclosed reasons"
assert_contains "$def_report" "Pass --all for the full history" "and points at the escape hatch"

# ── --all: restores the full sweep across every version ──────────────────────
all_j="$(run_replay --arm 1m --all --json)"
assert_eq "$(printf '%s' "$all_j" | jq -r '.meta.versionScope.mode')" "all" "--all sets mode to all"
assert_eq "$(printf '%s' "$all_j" | jq -r '.meta.versionScope.selected')" "null" \
  "--all does not pin to a single version"
assert_eq "$(printf '%s' "$all_j" | jq -r '.meta.versionScope.runsKept')" "3" \
  "--all keeps every run regardless of stamp"
assert_eq "$(printf '%s' "$all_j" | jq -r '.arms["1m"].tickets')" "3" \
  "--all replays all three tickets"
assert_eq "$(printf '%s' "$all_j" | jq -r '.arms["1m"].shiploopTokens')" "6600" \
  "and sums all three sessions' tokens: (1000+100)+(2000+200)+(3000+300)"

all_report="$(run_replay --arm 1m --all)"
assert_contains "$all_report" "shiploop version: --all" "the human report names the --all mode"
assert_contains "$all_report" "3 runs / 3 sessions, every version" "and states the unfiltered corpus size"

# ── --since composes with the default version scope ──────────────────────────
# Cutting off before the 1.18.0 run's timestamp still leaves the default version filter in force:
# the 1.19.0 run is unaffected (it is after the cutoff), the unstamped run is dropped by --since
# alone, and the 1.18.0 run is dropped by --since AND would have been dropped by the version scope
# anyway.
since_j="$(run_replay --arm 1m --since 20260601-000000 --json)"
assert_eq "$(printf '%s' "$since_j" | jq -r '.meta.runsSeenKept')" "2" \
  "--since 20260601 keeps the 1.18.0 and 1.19.0 runs, drops the unstamped 20260501 run"
assert_eq "$(printf '%s' "$since_j" | jq -r '.meta.versionScope.runsTotal')" "2" \
  "the version scope's own corpus is the POST-since set, not the full three"
assert_eq "$(printf '%s' "$since_j" | jq -r '.meta.versionScope.runsKept')" "1" \
  "and still narrows to just the 1.19.0 run within it"
assert_eq "$(printf '%s' "$since_j" | jq -r '.arms["1m"].tickets')" "1" \
  "so composing --since with the default still yields exactly ticket 202"

assert_done
