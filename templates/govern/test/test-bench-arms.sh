#!/usr/bin/env bash
# bench: both arm shapes, and the --max-turns / --forward-subagent-text capability gates.
#
# Contract:
#   1. the vanilla arm is ONE session for the whole backlog; the shiploop arm is ALSO one session
#      for the whole backlog now — the only difference between arms is which directory the session
#      opens in, never the shape of the dispatch
#   2. `task` is recorded per row: the backlog name for both the vanilla and the shiploop session
#   3. ticket text is byte-identical across arms (an asymmetric prompt voids even true numbers)
#   4. NEITHER arm is handed a curated --tools list any more: no `--tools` flag on the spawn path at
#      all, and the shiploop arm sets no GOVERN_WORKER_TOOLS / GOVERN_WORKER_MODEL either — the
#      tool-schema trim and the worker's model are levers under test, not something bench hands out
#      or withholds from either arm
#   5. --max-turns is gated on a cached --help probe with a _GOVERN_MAXTURNS_SUPPORTED pre-seed
#      seam and a BENCH_MAX_TURNS_FLAG kill switch, never a version compare; --max-budget-usd is
#      the fallback ceiling, gated on its own probe/seam, for a CLI with no --max-turns
#   6. a CLI with NEITHER flag is a HARD STOP, not a silent uncapped spawn; BENCH_ALLOW_UNCAPPED_TURNS=1
#      is the only way past it
#   7. the shiploop arm seeds one queue ticket per backlog line, hands the advisor the SAME
#      whole-backlog prompt as vanilla, and runs NO scripted dispatch shell-outs of its own — the
#      session invokes whatever the doctrine tells it to. It scopes the run to one directory so
#      lever-events.jsonl is findable, and it never sets a worker's model or tools.
#   8. the seeded queue is really dispatchable: the shipped select-ticket.sh orders every ticket.
#      Without this the arm could scaffold, seed a queue the selector rejects, record zero cost,
#      and have the rollup report that as a 100% saving
#   9. --forward-subagent-text is gated exactly like --max-turns (cached probe, pre-seed seam, kill
#      switch) but with NO degraded fallback: an unsupported CLI is a hard stop for the shiploop arm
#  10. subagent_stats.spawned>0 && completed>0 is asserted directly off the arm's own result event,
#      never the exit code — a subagent refused for zero tools still exits 0
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
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="shiploop") ] | length' "$R")" "1" \
  "1. shiploop is ALSO exactly one session for the whole backlog now"
assert_eq "$(jq -sr '[ .[] | select(.kind=="session" and .arm=="vanilla-fresh") ] | length' "$R")" "6" \
  "1. vanilla-fresh is one session per ticket, no driver"
assert_eq "$(jq -r 'select(.kind=="rollup" and .arm=="shiploop") | .sessions' "$R")" "1" \
  "1. the shiploop rollup counts the one session the arm spent"

assert_eq "$(jq -r 'select(.kind=="session" and .arm=="vanilla") | .task' "$R")" "fixture-backlog" \
  "2. the vanilla session's task is the backlog"
assert_eq "$(jq -r 'select(.kind=="session" and .arm=="shiploop") | .task' "$R")" "fixture-backlog" \
  "2. the shiploop session's task is ALSO the backlog — it is one whole-backlog session, not a per-ticket loop"

# ── 3 + 4 + 5 + 6 + 9. the arm library, loaded directly ─────────────────────
armsh() { # <script body> -> stdout+stderr, rc preserved
  BENCH_STATE_DIR="$T/state" BENCH_TURNS=200 \
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

# 4. No curated tool list on the spawn path at all, for either arm, and no worker-tier override
# from the shiploop arm either — every one of those was a lever under test (spec section 3a/3b).
# grep -F treats a leading-dash NEEDLE as a flag (the OLD suite hit this on --version), so a literal
# "--xyz" needle is counted with an explicit -e pattern rather than pushed through assert_*_contains.
spawn_body="$(sed -n '/^bench::spawn()/,/^}/p' "$HUB/bench/arms.sh")"
assert_eq "$(printf '%s' "$spawn_body" | grep -c -e '\-\-tools')" "0" \
  "4. bench::spawn passes no --tools flag at all"
assert_not_contains "$(cat "$HUB/bench/arms.sh")" "BENCH_TOOLS" \
  "4. BENCH_TOOLS does not exist any more — a curated tool list was itself one of the levers under test"
# The var names are named in the arm's own explanatory comment (to say they are deliberately
# absent), so the assertion is on `export NAME`, the only form that would actually set one.
shiploop_body="$(sed -n '/^bench::arm_shiploop()/,/^}/p' "$HUB/bench/arms.sh")"
assert_not_contains "$shiploop_body" "export GOVERN_WORKER_TOOLS" \
  "4. the shiploop arm sets no GOVERN_WORKER_TOOLS — the scaffolded worker.md's own frontmatter is the only source"
assert_not_contains "$shiploop_body" "export GOVERN_WORKER_MODEL" \
  "4. and no GOVERN_WORKER_MODEL — the worker's tier is a lever under test, never pinned by bench"
assert_not_contains "$shiploop_body" "export GOVERN_WORKER_MAX_TURNS" \
  "4. nor GOVERN_WORKER_MAX_TURNS — no scripted spawn-worker.sh call exists here to hand a flag to"
assert_eq "$(printf '%s' "$shiploop_body" | grep -c -e '\-\-agents')" "0" \
  "4. no --agents flag: the project's own .claude/agents/*.md load with none"

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
# workers (which reach them through spawn-worker.sh, if the session chooses that path) can never
# disagree about CLI support.
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

# 6. Refusal.
got="$(armsh 'bench_max_turns_flag=""; bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "Refusing to spawn an uncapped session" "6. no ceiling flag means no spawn"
got="$(armsh 'bench_max_turns_flag=""; BENCH_ALLOW_UNCAPPED_TURNS=1 bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "rc=0" "6. the explicit operator override is the only way past it"
assert_contains "$got" "running UNCAPPED" "6. and the override is logged"
# A cell hard-stops only when NEITHER flag resolves; the budget fallback alone is enough to pass.
got="$(armsh '_GOVERN_MAXTURNS_SUPPORTED=0 _GOVERN_MAXBUDGETUSD_SUPPORTED=1 bench::resolve_max_turns_flag /bin/true 200 5; bench::require_turn_ceiling vanilla; echo "rc=$?"')"
assert_contains "$got" "rc=0" "6. the budget fallback alone satisfies the ceiling requirement, no override needed"

# ── 7. the shiploop arm seeds a real queue and scripts no dispatch loop ─────
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
# The three scripted dispatch shell-outs are GONE: the session invokes whatever the doctrine tells
# it to, like a real operator's session, never a bash loop bench runs on its behalf.
assert_not_contains "$shiploop_body" "pre-dispatch-check.sh" \
  "7. no scripted pre-dispatch-check.sh loop — the session decides whether and when to run it"
assert_not_contains "$shiploop_body" "spawn-worker.sh" \
  "7. no scripted spawn-worker.sh call — workers are the session's own Agent tool calls"
assert_not_contains "$shiploop_body" "resolve-ticket.sh" \
  "7. no scripted resolve-ticket.sh call — landing a worker's report is the session's own choice"
# It IS scoped to one run directory, so lever-events.jsonl (still emitted, spec section 9) is
# findable afterward instead of landing in the unscoped flat file a live interactive session uses.
assert_contains "$shiploop_body" 'export GOVERN_RUN_DIR="$rundir"' \
  "7. the arm still scopes the session to one run directory so lever-events.jsonl is findable"
# The advisor gets the SAME whole-backlog prompt bench::backlog_prompt renders for vanilla, not a
# per-ticket loop — this is what makes it directly comparable to the vanilla arm's one session.
assert_contains "$shiploop_body" 'bench::backlog_prompt "$backlog"' \
  "7. the shiploop arm is handed the SAME whole-backlog prompt as vanilla"

# ── 8. the seeded queue is really selectable by the shipped governor ────────
# Spawn-free end-to-end check of the seam: scaffold a throwaway workspace the way the arm does,
# seed it, and ask the REAL select-ticket.sh to order the named set. If the seeding shape is
# wrong, this returns nothing and the shiploop arm would have silently measured an empty run.
mkdir -p "$T/state/wd-y"
( cd "$T/state/wd-y" && git init -q -b main && echo hi > README.md \
  && git -c user.email=a@b -c user.name=a add -A \
  && git -c user.email=a@b -c user.name=a commit -qm init ) >/dev/null 2>&1
ws="$(armsh "bench::scaffold_workspace '$T/state/wd-y' probe bench" | tail -1)"
if [ -x "$ws/scripts/govern/spawn-worker.sh" ] && [ -x "$ws/scripts/govern/resolve-ticket.sh" ]; then
  printf 'ok   - 8. the arm scaffolds a workspace carrying the real lane scripts\n'
  armsh "bench::seed_tickets '$BL' '$ws/queue/tickets.md' bench" >/dev/null
  sel="$(cd "$ws" && GOVERN_WS_ROOT="$ws" bash "$ws/scripts/govern/select-ticket.sh" "" "1,2,3,4,5,6" 2>&1 | tr '\n' ',')"
  assert_eq "$sel" "1,2,3,4,5,6," "8. the real selector orders every seeded ticket for dispatch"
else
  printf 'FAIL - 8. scaffold_workspace produced no lane scripts (ws=%s)\n' "$ws"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# ── 9. --forward-subagent-text: the same probe shape as --max-turns, no degraded fallback ──
got="$(armsh '_GOVERN_FWDSUBAGENT_SUPPORTED=1 bench::resolve_forward_subagent_flag /bin/true; printf "%s" "$bench_fwd_subagent_flag"')"
assert_eq "$got" "--forward-subagent-text" "9. probe seam 1 puts the flag on the command line"
# bench::die exits the whole subshell immediately (never a `return`), so nothing after the call
# runs — the message itself, captured on stderr, is the only evidence of the hard stop.
got="$(armsh '_GOVERN_FWDSUBAGENT_SUPPORTED=0 bench::resolve_forward_subagent_flag /bin/true; echo "UNREACHABLE"')"
assert_contains "$got" "does not support --forward-subagent-text" "9. an unsupported CLI says so"
assert_not_contains "$got" "UNREACHABLE" "9. and HARD STOPS — there is no degraded-arm fallback for attribution"
got="$(armsh 'BENCH_FORWARD_SUBAGENT_TEXT=0 _GOVERN_FWDSUBAGENT_SUPPORTED=0 bench::resolve_forward_subagent_flag /bin/true; echo "rc=$?"')"
assert_contains "$got" "rc=0" "9. the kill switch is the only way past an unsupported CLI"
assert_contains "$got" "BENCH_FORWARD_SUBAGENT_TEXT=0" "9. and it is logged when used"
fwd_probe_body="$(sed -n '/^bench::claude_supports_forward_subagent_text/,/^}/p' "$HUB/bench/arms.sh")"
assert_contains "$fwd_probe_body" "_bounded_help_grep" "9. the forward-subagent-text probe is also a bounded --help grep"
assert_contains "$fwd_probe_body" "_GOVERN_FWDSUBAGENT_SUPPORTED" "9. with its own pre-seed test seam"
assert_eq "$(printf '%s' "$fwd_probe_body" | grep -c -e '--version')" "0" \
  "9. and it never shells out to --version either"

# ── 10. subagent-activity assertion, off the arm's own result event ────────
got="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  set +e
  bench::stream_had_subagent_activity "'"$HUB"'/bench/fixtures/shiploop-session.jsonl"
  echo "rc=$?"
' 2>&1)"
assert_contains "$got" "rc=0" "10. the checked-in shiploop fixture shows real subagent activity"
got="$(BENCH_STATE_DIR="$T/state" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  set +e
  bench::stream_had_subagent_activity "'"$HUB"'/bench/fixtures/vanilla-session.jsonl"
  echo "rc=$?"
' 2>&1)"
assert_contains "$got" "rc=1" \
  "10. a stream with no subagent_stats at all (the vanilla fixture) reports NO activity, never a false pass"
assert_contains "$shiploop_body" "bench::stream_had_subagent_activity" \
  "10. the arm asserts subagent activity directly, never trusting the spawn's exit code"

assert_done
