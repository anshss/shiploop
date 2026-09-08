#!/usr/bin/env bash
# bench: both arm shapes, and the --max-turns capability gate.
#
# Contract:
#   1. the vanilla arm is ONE session for the whole backlog; the shiploop arm is a driver plus one
#      session per ticket, and every one of them lands in the cost total
#   2. `task` is recorded per row: the backlog name for the single vanilla session, the ticket for
#      each shiploop worker
#   3. ticket text is byte-identical across arms (an asymmetric prompt voids even true numbers)
#   4. neither arm can reach the network: no WebFetch, no WebSearch in the tool list
#   5. --max-turns is gated on a cached --help probe with a _GOVERN_MAXTURNS_SUPPORTED pre-seed
#      seam and a BENCH_MAX_TURNS_FLAG kill switch, never a version compare; --max-budget-usd is
#      the fallback ceiling, gated on its own probe/seam, for a CLI with no --max-turns
#   6. a CLI with NEITHER flag is a HARD STOP, not a silent uncapped spawn; BENCH_ALLOW_UNCAPPED_TURNS=1
#      is the only way past it
#   7. the shiploop arm seeds one queue ticket per backlog line, numbered so run-loop.sh can be
#      handed the whole set in ONE named dispatch (a per-ticket fan-out would bypass the loop's
#      dependency gate and escalation, which are part of what is being measured)
#   8. the seeded queue is really dispatchable: the shipped select-ticket.sh orders every ticket.
#      Without this the arm could scaffold, seed a queue the selector rejects, record zero cost,
#      and have the rollup report that as a 100% saving
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/arms.sh" ] && [ -f "$HUB/bench/run.sh" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BL="$HUB/bench/backlogs/fixture-backlog/backlog.jsonl"

# ── 1 + 2. arm shapes, through the real driver ──────────────────────────────
BENCH_OUT_ROOT="$T/r" bash "$HUB/bench/run.sh" --dry-run --run-id arms \
  --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog \
  --arm vanilla --arm vanilla-fresh --arm shiploop >/dev/null 2>&1
R="$T/r/arms-dry/results.jsonl"

assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="vanilla") ] | length' "$R")" "1" \
  "1. vanilla is exactly one session for the whole backlog"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="shiploop") ] | length' "$R")" "7" \
  "1. shiploop is a driver plus one session per ticket"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="vanilla-fresh") ] | length' "$R")" "6" \
  "1. vanilla-fresh is one session per ticket, no driver"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .sessions' "$R")" "7" \
  "1. the shiploop rollup counts every session the loop spent, driver included"

assert_eq "$(jq -r 'select(.kind=="session" and .arm=="vanilla") | .task' "$R")" "fixture-backlog" \
  "2. the vanilla session's task is the backlog"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="shiploop") | .task ] | join(",")' "$R")" \
  "driver,worker-t1,worker-t2,worker-t3,worker-t4,worker-t5,worker-t6" \
  "2. each shiploop session records the ticket it worked"

# ── 3 + 4 + 5 + 6. the arm library, loaded directly ─────────────────────────
armsh() { # <script body> -> stdout+stderr, rc preserved
  BENCH_STATE_DIR="$T/state" BENCH_TURNS_VANILLA=200 BENCH_TURNS_WORKER=80 \
  BENCH_CLAUDE_BIN=/bin/true bash -c '
    source "'"$HUB"'/bench/record.sh"
    bench::load_govern_lib "'"$T"'/state"
    source "'"$HUB"'/bench/arms.sh"
    set +e
    '"$1" 2>&1
}

# 3. Both prompt renderers pull the same fields through the same jq program, so a ticket's text is
# the same bytes in the one-session prompt and in the per-ticket prompt.
full="$(armsh 'bench::backlog_prompt "'"$BL"'"')"
one="$(armsh 'bench::ticket_prompt "'"$BL"'" t3')"
title="$(jq -r 'select(.id=="t3") | .title' "$BL")"
body="$(jq -r 'select(.id=="t3") | .body' "$BL")"
assert_contains "$full" "$title" "3. the backlog prompt carries ticket t3's title verbatim"
assert_contains "$full" "$body" "3. the backlog prompt carries ticket t3's body verbatim"
assert_contains "$one" "$title" "3. the per-ticket prompt carries the same title"
assert_contains "$one" "$body" "3. the per-ticket prompt carries the same body"
assert_not_contains "$full" "shiploop" "3. neither arm's prompt hints at the treatment"
assert_not_contains "$full" "upstream_pr" "3. the prompt never leaks the upstream PR"
# The oracle must stay invisible to the session. The golden test_patch is applied at VERIFY time,
# after the arm has finished; a prompt carrying it (or the merge sha, or the test file name) would
# hand the arm the answer and void the whole measurement.
patch="$(jq -r 'select(.id=="t3") | .test_patch' "$BL")"
sha="$(jq -r 'select(.id=="t3") | .merge_sha' "$BL")"
assert_not_contains "$full" "$sha" "3. the prompt never leaks merge_sha"
assert_not_contains "$one" "$sha" "3. nor does the per-ticket prompt"
assert_not_contains "$full" "diff --git" "3. the prompt never carries a golden test_patch"
assert_not_contains "$one" "diff --git" "3. nor does the per-ticket prompt"
assert_not_contains "$full" "tests/t3.sh" "3. and it never names the test file the oracle will add"
assert_not_contains "$one" "tests/t3.sh" "3. nor does the per-ticket prompt"
assert_not_contains "$full" "Verify with" \
  "3. verify_cmd is not in the prompt at all: it names the gold test the oracle adds later"
# The seeded governor queue is the shiploop arm's prompt source, so it must be just as clean.
slug="$(armsh "bench::repo_slug '$BL'")"
armsh "bench::seed_tickets '$BL' '$T/leak.md' '$slug'" >/dev/null
leak="$(cat "$T/leak.md")"
assert_not_contains "$leak" "diff --git" "3. the seeded queue carries no golden test_patch"
assert_not_contains "$leak" "$sha" "3. and no merge_sha"
assert_not_contains "$leak" "local://pr" "3. and no upstream PR link"
assert_not_contains "$leak" "tests/t1.sh" "3. and never the gold test file name"
[ -n "$patch" ] && printf 'ok   - 3. (the fixture really does carry a non-empty test_patch to leak)\n' || \
  { printf 'FAIL - 3. fixture has no test_patch, so the leak checks prove nothing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# 4. One tool list, shared by both arms, with the two web tools removed.
tools="$(armsh 'printf "%s" "$BENCH_TOOLS"')"
assert_not_contains "$tools" "WebFetch" "4. WebFetch is not in either arm's tool list"
assert_not_contains "$tools" "WebSearch" "4. WebSearch is not in either arm's tool list"
assert_contains "$tools" "Bash" "4. the working tools are still there"
assert_contains "$tools" "Edit" "4. the working tools are still there (Edit)"

# 5. The probe: pre-seed supported, pre-seed unsupported, kill switch, and the --max-budget-usd
# FALLBACK for a CLI that has neither turns support nor... has budget support but not turns. No
# version compare anywhere.
got="$(armsh '_GOVERN_MAXTURNS_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; printf "%s" "$bench_max_turns_flag"')"
assert_eq "$got" "--max-turns 200" "5. probe seam 1 puts the rail on the command line"
got="$(armsh '_GOVERN_MAXTURNS_SUPPORTED=0 _GOVERN_MAXBUDGETUSD_SUPPORTED=0 bench::resolve_max_turns_flag /bin/true 200 5; printf "[%s]" "$bench_max_turns_flag"')"
assert_contains "$got" "[]" "5. neither flag supported omits the flag rather than passing an unknown one"
assert_contains "$got" "does not support --max-turns" "5. and says so out loud"
got="$(armsh 'BENCH_MAX_TURNS_FLAG=0 _GOVERN_MAXTURNS_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; printf "[%s]" "$bench_max_turns_flag"')"
assert_contains "$got" "[]" "5. the kill switch wins over a supported CLI"
# The fallback: --max-turns unsupported, --max-budget-usd IS. This is the observed shape on
# claude 2.1.246, the CLI that motivated the fallback.
got="$(armsh '_GOVERN_MAXTURNS_SUPPORTED=0 _GOVERN_MAXBUDGETUSD_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; printf "[%s]" "$bench_max_turns_flag"')"
assert_contains "$got" "[--max-budget-usd 5]" "5. --max-turns absent falls back to --max-budget-usd"
got="$(armsh 'BENCH_MAX_TURNS_FLAG=0 _GOVERN_MAXTURNS_SUPPORTED=0 _GOVERN_MAXBUDGETUSD_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; printf "[%s]" "$bench_max_turns_flag"')"
assert_contains "$got" "[]" "5. the kill switch also suppresses the budget fallback"
# The probes are NOT bench-local reimplementations: they live in common.sh beside the --tools and
# --exclude-dynamic-system-prompt-sections probes, so the vanilla arm and the shiploop arm's
# workers (which reach them through spawn-worker.sh) can never disagree about CLI support.
probe="$(sed -n '/^govern::claude_supports_max_turns/,/^}/p' "$HUB/templates/govern/lib/common.sh")"
assert_contains "$probe" "_bounded_help_grep" "5. the max-turns probe is a bounded --help grep"
assert_contains "$probe" "_GOVERN_MAXTURNS_SUPPORTED" "5. with the pre-seed test seam"
budget_probe="$(sed -n '/^govern::claude_supports_max_budget_usd/,/^}/p' "$HUB/templates/govern/lib/common.sh")"
assert_contains "$budget_probe" "_bounded_help_grep" "5. the max-budget-usd probe is also a bounded --help grep"
assert_contains "$budget_probe" "_GOVERN_MAXBUDGETUSD_SUPPORTED" "5. with its own pre-seed test seam"
assert_contains "$(cat "$HUB/templates/govern/lib/common.sh")" "_GOVERN_MAXTURNS_PROBE_CACHE" \
  "5. and a run-scoped cache, so a long run probes at most once"
assert_contains "$(cat "$HUB/templates/govern/lib/common.sh")" "_GOVERN_MAXBUDGETUSD_PROBE_CACHE" \
  "5. same for the budget probe's cache"
# grep -F still treats a leading-dash NEEDLE as a flag, so count the matches with an explicit
# pattern argument rather than pushing "--version" through assert_not_contains.
assert_eq "$(printf '%s' "$probe" | grep -c -e '--version')" "0" \
  "5. the probe never shells out to --version"
spawn_worker_resolve="$(sed -n '/^resolve_max_turns_flag/,/^}/p' "$HUB/templates/govern/spawn-worker.sh")"
assert_contains "$spawn_worker_resolve" "govern::claude_supports_max_turns" \
  "5. spawn-worker gates GOVERN_WORKER_MAX_TURNS on the same probe"
assert_contains "$spawn_worker_resolve" "govern::claude_supports_max_budget_usd" \
  "5. and GOVERN_WORKER_MAX_BUDGET_USD on the matching budget probe"
assert_contains "$spawn_worker_resolve" 'GOVERN_WORKER_MAX_TURNS:-0' \
  "5. both knobs default to 0 (off), so an unset fleet spawns exactly as it did before"
assert_contains "$spawn_worker_resolve" 'GOVERN_WORKER_MAX_BUDGET_USD:-0' \
  "5. same default-off shape for the budget knob"

# 6. Refusal.
got="$(armsh 'bench_max_turns_flag=""; bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "Refusing to spawn an uncapped session" "6. no ceiling flag means no spawn"
got="$(armsh 'bench_max_turns_flag=""; BENCH_ALLOW_UNCAPPED_TURNS=1 bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "rc=0" "6. the explicit operator override is the only way past it"
assert_contains "$got" "running UNCAPPED" "6. and the override is logged"
# A cell hard-stops only when NEITHER flag resolves; the budget fallback alone is enough to pass.
got="$(armsh '_GOVERN_MAXTURNS_SUPPORTED=0 _GOVERN_MAXBUDGETUSD_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "rc=0" "6. the budget fallback alone satisfies the ceiling requirement, no override needed"

# ── 7. the shiploop arm seeds a real queue ──────────────────────────────────
assert_eq "$slug" "bench" "7. the sub-repo slug is a NAME derived from the repo, not the clone URL"
armsh "bench::seed_tickets '$BL' '$T/tickets.md' '$slug'" >/dev/null
seeded="$(cat "$T/tickets.md")"
assert_eq "$(grep -c '^## #' "$T/tickets.md")" "6" "7. one queue ticket per backlog line"
assert_contains "$seeded" "## #1 " "7. tickets are numbered from 1 so the whole set can be named"
assert_contains "$seeded" "## #6 " "7. through to the last one"
assert_contains "$seeded" "$body" "7. the queue body is the same bytes the vanilla prompt gets"
assert_not_contains "$seeded" "Verify with" "7. and carries no verify_cmd, same as the vanilla prompt"
# The `Repo:` field must be the workspace sub-repo NAME. Seeding the clone URL there would make
# every ticket unselectable, the shiploop arm would record zero cost, and the rollup would read
# that as a 100% saving. This is the assertion that stops a silent 100%.
assert_contains "$seeded" "Repo: bench" "7. Repo: is the sub-repo name the selector matches on"
assert_not_contains "$seeded" "Repo: fixture://" "7. never the clone URL"
# One named dispatch of the full set, not a per-ticket fan-out: the dependency gate, the
# cross-driver re-verify, and the failure-streak escalation only exist in the full loop.
assert_contains "$(cat "$HUB/bench/arms.sh")" 'run-loop.sh" --serial $nums' \
  "7. the arm hands run-loop.sh every ticket number in one dispatch"
# The shiploop arm carries the SAME two rails as the vanilla arm, through the governor's own knobs.
assert_contains "$(cat "$HUB/bench/arms.sh")" 'GOVERN_WORKER_MAX_TURNS="$worker_turns"' \
  "7. the per-worker turn ceiling reaches the loop's workers"
assert_contains "$(cat "$HUB/bench/arms.sh")" 'GOVERN_WORKER_MAX_BUDGET_USD="$worker_budget"' \
  "7. and so does the budget fallback, whichever one the probe resolved"
assert_contains "$(cat "$HUB/bench/arms.sh")" 'GOVERN_WORKER_TOOLS="$BENCH_TOOLS"' \
  "7. and so does the web-free tool list"

# ── 8. the seeded queue is really selectable by the shipped governor ────────
# Spawn-free end-to-end check of the seam: scaffold a throwaway workspace the way the arm does,
# seed it, and ask the REAL select-ticket.sh to order the named set. If the seeding shape is
# wrong, this returns nothing and the shiploop arm would have silently measured an empty run.
mkdir -p "$T/state/wd-y"
( cd "$T/state/wd-y" && git init -q -b main && echo hi > README.md \
  && git -c user.email=a@b -c user.name=a add -A \
  && git -c user.email=a@b -c user.name=a commit -qm init ) >/dev/null 2>&1
ws="$(armsh "bench::scaffold_workspace '$T/state/wd-y' probe bench" | tail -1)"
if [ -x "$ws/scripts/govern/run-loop.sh" ]; then
  printf 'ok   - 8. the arm scaffolds a workspace carrying the real run-loop.sh\n'
  armsh "bench::seed_tickets '$BL' '$ws/queue/tickets.md' bench" >/dev/null
  sel="$(cd "$ws" && GOVERN_WS_ROOT="$ws" bash "$ws/scripts/govern/select-ticket.sh" "" "1,2,3,4,5,6" 2>&1 | tr '\n' ',')"
  assert_eq "$sel" "1,2,3,4,5,6," "8. the real selector orders every seeded ticket for dispatch"
else
  printf 'FAIL - 8. scaffold_workspace produced no run-loop.sh (ws=%s)\n' "$ws"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

assert_done
