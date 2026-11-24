#!/usr/bin/env bash
# Tiny assertion helper for govern smoke tests.
set -euo pipefail
ASSERT_FAILS=0

# ── Layout resolver ──────────────────────────────────────────────────────────
# These tests run in TWO layouts: a live workspace (govern at scripts/govern/, prompt
# files at <root>/governor/, hooks at <root>/scripts/) and the template repo itself
# (govern at templates/govern/, prompts at templates/governor/, hooks at templates/hooks/).
# Probe both so the suite is green out-of-the-box in either — with NO scaffolded workspace
# present. assert.sh sits in <…>/govern/test/, so resolve relative to its own location.
ASSERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Governor prompt dir: templates/governor (template) | <root>/governor (workspace).
for _cand in "$ASSERT_DIR/../../governor" "$ASSERT_DIR/../../../governor"; do
  if [[ -f "$_cand/worker-prompt.md" ]]; then GOVERN_PROMPTS_DIR="$(cd "$_cand" && pwd)"; break; fi
done
# Hooks dir (session-snapshot.sh + ticket-sweep-reminder.sh): templates/hooks (template) |
# <root>/scripts (workspace, where the hooks install beside govern/).
for _cand in "$ASSERT_DIR/../../hooks" "$ASSERT_DIR/../.."; do
  if [[ -f "$_cand/session-snapshot.sh" ]]; then GOVERN_HOOKS_DIR="$(cd "$_cand" && pwd)"; break; fi
done
export GOVERN_PROMPTS_DIR="${GOVERN_PROMPTS_DIR:-}" GOVERN_HOOKS_DIR="${GOVERN_HOOKS_DIR:-}"

# Merge-guard test seam (top-level, back-compat): pre-v1.2.0 this lived at the top of assert.sh,
# so adopter tests that source assert.sh WITHOUT calling mk_ws_stub still get the seam. mk_ws_stub
# re-sets it (below) so callers that unset it earlier still land on 1 after the stub runs. Tests
# that need to EXERCISE the guard (test-automerge-guard.sh) explicitly `unset` this after sourcing.
export _GOVERN_ASSUME_MERGE_ALLOWED=1

# Hermetic driver-context input: the suite is routinely run BY a governor worker whose own session
# exports GOVERN_FIX_CI=<repo>#<pr> for a CI-fix re-dispatch. Inheriting it would leak that context
# into tests that have nothing to do with it. Clear it here so a run is identical inside and outside
# a governor session: the precedent the dispatch-path mechanisms below follow.
unset GOVERN_FIX_CI

# Hermetic sizing: a scout pass would run a REAL `claude -p` on the dispatch path, so leaving this on
# would (a) make every dispatch test issue an implicit model call and (b) burn one invocation of the
# stubbed `claude` these tests script per-attempt — shifting a "attempt 1 drops, attempt 2 resolves"
# fixture by one and failing tests that have nothing to do with sizing. Off by default here.
export GOVERN_SCOUT=0

# Hermetic model ceiling: govern::model_clamp derives its ceiling from the model of the session that
# is spawning the process, and this suite is routinely run BY a governor worker (or a driver session)
# whose model is whatever the operator happened to be on. Leaving it ambient would make the sizing
# tests assert against a moving ceiling: a haiku-driven run clamps nothing (opus is the floor of the
# ceiling), but a run driven from a tier above opus would let a fable tier through where the fixture
# expects it clamped. Pin it to `opus`, the same value an undetectable session falls back to, so the
# suite behaves exactly like the fail-safe path. The ceiling's own test sets what it needs per case.
export GOVERN_SESSION_MODEL=opus

# Dispatch-path mechanisms that skip, cap or cut short a worker dispatch, forced OFF for the whole suite.
#
# This follows the GOVERN_FIX_CI precedent and the standing rule it produced: a new mechanism on the
# dispatch path perturbs this suite, because the suite drives stateful fake-`claude` stubs that COUNT
# and TRACK every invocation and script per-attempt outcomes. A mechanism that skips a dispatch
# entirely (staleness gate, self-ref cap) or kills a worker early (early abort) shifts those
# fixtures by one and reddens tests that have nothing to do with it. Each feature's OWN test
# enables what it needs explicitly — never a per-test patch here.
#
# All of these already default to the same value in their scripts; setting them here is the seam that
# stops a LIVE governor session's exported env from leaking into a suite run inside it (the documented
# failure mode where GOVERN_ALLOW_CONCURRENT=1 leaks in and reddens the orphan sweep by design).
export GOVERN_STALENESS_GATE=0       # pre-dispatch staleness skip
export GOVERN_STALENESS_RUN_TESTS=0  # never execute a queue-authored command in a test run
export GOVERN_EARLY_ABORT=0          # in-flight worker watchdog
export GOVERN_RUN_MAX_TOKENS=0       # run-level spend ceiling (0 = off)
export GOVERN_EVENTS=0               # fleet event log (lib/common.sh): OFF for the whole suite
export GOVERN_OVERLAP_NUDGE=0        # dispatch-time overlap nudge: its own test opts back in
export GOVERN_MERGED_PR_PROBE=0      # pre-dispatch merged-PR mirror probe (live gh): its own test opts back in
export GOVERN_KEEP_BLOCK_UNTIL_MERGE=0  # keep the ticket block until the PR merges: its own test opts back in
export GOVERN_AUTO_BUDGETS=0         # run-end --enforce-budgets flush: its own test opts back in
export GOVERN_GOTCHA_INJECT=0        # CLAUDE.md/learnings.md **Paths:** gotcha injection — several
                                      # existing tests (test-claudemd-trim.sh etc.) write their OWN CLAUDE.md at
                                      # the stub root for unrelated reasons; a coincidental `### `+`**Paths:**`
                                      # match there must never leak into an unrelated test's assembled prompt.
                                      # Its own test (test-gotchas-for-paths.sh) opts back in.
export GOVERN_ADVISOR=0              # the advisor consult kill switch. Already the
                                      # script's own default, restated here per the GOVERN_FIX_CI precedent
                                      # (a live governor session's exported env must never leak into a suite
                                      # run). Its own test (test-advisor-consult.sh) opts back in explicitly.
export GOVERN_PROPOSAL_GATE=0        # unlike the knobs
                                      # above, this gate's SHIPPED default is ON (an
                                      # inert-by-default gate is the defect this design is written
                                      # against), so it is the one line here where the suite default
                                      # genuinely diverges from production. Forced off so every
                                      # pre-existing pre-dispatch-check.sh fixture (none of which
                                      # carry a **Proposed solution:** section) keeps testing what it
                                      # was written to test. Its own tests opt back in explicitly.
export GOVERN_DISPATCH_GATE=0        # router-posture-guard.sh's dispatch-packet gate ships ON (same
                                      # divergence as GOVERN_PROPOSAL_GATE above): it denies any worker
                                      # spawn that names no fresh packet, which would deny every
                                      # pre-existing worker-dispatch fixture. Its own test
                                      # (test-dispatch-gate.sh) opts back in explicitly.
export GOVERN_VF_DENY=0              # same shape of divergence: router-posture-guard.sh's
                                      # verify-filter denial ships ON by default (per CLAUDE.md
                                      # rule 12, a new blocking mechanism defaults off in THIS
                                      # file, not in the shipped script). Forced off so no
                                      # pre-existing fixture whose command field happens to look
                                      # like an unwrapped test/build runner picks up a surprise
                                      # deny. Its own test (test-router-posture-vf-deny.sh) opts
                                      # back in explicitly.
export GOVERN_AGENT_SUPERVISION=1    # same shape
                                      # of divergence as GOVERN_PROPOSAL_GATE just above — this
                                      # hook's SHIPPED default is ON.
                                      # Pinned explicitly (not left ambient) so a live governor
                                      # session's own GOVERN_AGENT_SUPERVISION=0 export can't leak
                                      # into a suite run and mask a regression. Unlike the knobs
                                      # forced OFF above, there is no pre-existing fixture to
                                      # protect: test-agent-progress-guard.sh is the only test that
                                      # ever invokes this hook, and it covers the ON default and
                                      # the GOVERN_AGENT_SUPERVISION=0 kill switch directly.
export GOVERN_STEER_CAP=12           # advisor-steer-guard.sh's per-session cap on messages sent
                                      # down to a dispatched worker. Pinned at the shipped default,
                                      # not forced off: this gate only ever DENIES a message, it
                                      # never spawns, so no dispatch fixture is perturbed by it.
                                      # Explicit so a live session's own override cannot leak in.
export GOVERN_BG_WAIT_GUARD=0 GOVERN_BG_LEDGER=0 GOVERN_REPORT_CAPTURE=0
                                      # the background-task wait guard (ships ON, and can hold a
                                      # stop), its PostToolUse ledger and the SubagentStop report
                                      # capture (both ship ON and write under governor/). Forced off
                                      # so no other fixture blocks, waits or writes through them;
                                      # their own tests opt back in.

# The auto-merge guard's branch-name check ships ON and blocks any PR whose head is not a governor
# branch. Fixtures open PRs under arbitrary stub branch names, so it is off here; the guard tests
# (test-automerge-guard.sh, test-public-pr-hygiene.sh) turn it back on.
export GOVERN_MERGE_BRANCH_GUARD=0

# Index rebuild fires post-resolve in resolve-ticket.sh. It is git/grep only, no model call, but it
# walks every file in every stub repo on each resolved ticket, which is pure wall-clock in a suite
# that resolves hundreds of synthetic tickets. Its own test builds a real index explicitly.
export GOVERN_INDEX=0

# The stale-copy check runs git history scans on every queue writer. Fixtures that write the queue by
# hand would trip it for reasons that are not their subject, so it is off here; its own test turns it on.
export GOVERN_QUEUE_STALE_GUARD=0

# Seed a hermetic workspace stub so a test never depends on the LIVE scripts/lib/workspace.sh (its repo
# list / auto-merge allowlist) — common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh", so without
# this a test only "passes" when run from inside a real workspace whose config happens to match. Call it
# right after `mktemp -d`. Pass the auto-merge repos as a comma list (default "alpha"); REPOS = those plus
# a frontend "web" repo (PR-only). Exports GOVERN_WS_ROOT (+ GOVERN_EXTERNALIZE_LANE=0, harmless where the
# externalize lane doesn't exist, required where it does so the externalize lane doesn't fire under the stub).
#   mk_ws_stub "$T"                     # alpha auto-mergeable, web PR-only
#   mk_ws_stub "$T" "alpha,api"         # alpha + api auto-mergeable
#   mk_ws_stub "$T" "" "alpha"          # alpha PR-only AND local-first
mk_ws_stub() { # <root> [merge-csv] [local-first-csv]
  local root="$1" merge="${2:-alpha}" localfirst="${3:-}"
  export GOVERN_WS_ROOT="$root"
  export GOVERN_EXTERNALIZE_LANE=0
  # Test seam: bypass the external-PR auto-merge safety guard (govern::pr_automerge_allowed) so a
  # test using mk_ws_stub doesn't need to stub `gh api user` + `gh api repos/.../pulls/N`. The guard
  # itself has DEDICATED tests (test-automerge-guard.sh) that explicitly UNSET this to exercise it.
  export _GOVERN_ASSUME_MERGE_ALLOWED=1
  mkdir -p "$root/scripts/lib"
  cat > "$root/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$root}"
GITHUB_ORG="acme"
REPOS=(${merge//,/ } web)
GOVERN_MERGE_REPOS="${merge//,/ }"
GOVERN_LOCAL_FIRST_REPOS="${localfirst//,/ }"
WORKTREE_BASE="$root/wt"
wsp_is_merge_repo() { case ",$merge," in *",\$1,"*) return 0;; *) return 1;; esac; }
wsp_is_local_first_repo() { case ",$localfirst," in *",\$1,"*) return 0;; *) return 1;; esac; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
}
# ── Background-fixture reap ──────────────────────────────────────────────────
# A backgrounded fixture that outlives its test holds the test's stdout pipe open,
# so a runner that captures output via command substitution blocks on the orphan,
# not the test (the run hangs; a `>file` runner just accumulates strays that
# outlive the session). bg_reap records a spawned pid; on the test's EXIT, pass or
# fail, the chained trap reaps every recorded pid with govern::kill_tree
# (lib/common.sh, reused, never re-derived). bg_kill_all reaps on demand. The
# chaining captures whatever EXIT trap the test had installed at bg_reap time and
# runs it after the reap, so set the test's own trap BEFORE the first bg_reap
# call; a trap installed later replaces the chain (re-arm by calling bg_reap
# again, or call bg_kill_all from the new trap).
GOVERN_TEST_BG_PIDS=()
bg_reap_one() { # <pid> reap one recorded fixture's subtree
  local pid="$1" i=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  # A `set -m` leader (the spawned-in-its-own-group shape kill_tree's group-wide
  # first strike is built for) gets kill_tree whole. A plain `cmd &` fixture is
  # NOT a group leader: it shares the test's own process group, so `kill -- -pid`
  # would TERM the test itself. There the walk alone is used, children first so
  # nothing escapes by re-parenting.
  if [[ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" == "$pid" ]]; then
    govern::kill_tree "$pid" 2
    return 0
  fi
  govern::_kill_tree_walk "$pid" TERM
  while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt 10 ]]; do sleep 0.2; i=$((i+1)); done
  govern::_kill_tree_walk "$pid" KILL
  return 0
}
bg_kill_all() { # reap every recorded pid's whole subtree
  local p had_e=0 had_u=0
  case $- in *e*) had_e=1 ;; esac
  case $- in *u*) had_u=1 ;; esac
  [[ "${#GOVERN_TEST_BG_PIDS[@]}" -gt 0 ]] || return 0
  if ! command -v govern::kill_tree >/dev/null 2>&1; then
    # common.sh sources scripts/lib/workspace.sh from the workspace root at source
    # time, so a test that never seeded a stub (or ran inside a real workspace)
    # gets a throwaway one, removed after the source; a test that DID seed one
    # keeps its own root untouched.
    if [[ -z "${GOVERN_WS_ROOT:-}" ]]; then
      local stubroot
      stubroot="$(mktemp -d)"
      mk_ws_stub "$stubroot"
      # shellcheck source=../lib/common.sh
      . "$ASSERT_DIR/../lib/common.sh"
      unset GOVERN_WS_ROOT
      rm -rf "$stubroot"
    else
      # shellcheck source=../lib/common.sh
      . "$ASSERT_DIR/../lib/common.sh"
    fi
    # common.sh sources with `set -euo pipefail`; a test that opted out (set +e)
    # must not inherit the stricter mode from a reap it never asked for.
    [[ "$had_e" == 1 ]] || set +e
    [[ "$had_u" == 1 ]] || set +u
  fi
  for p in ${GOVERN_TEST_BG_PIDS[@]+"${GOVERN_TEST_BG_PIDS[@]}"}; do
    bg_reap_one "$p"
  done
  GOVERN_TEST_BG_PIDS=()
  return 0
}
govern_bg_exit() { # chained EXIT trap: reap recorded fixtures, then the test's own trap
  bg_kill_all
  if [[ -n "${GOVERN_BG_PREV_EXIT_CMD:-}" ]]; then eval "$GOVERN_BG_PREV_EXIT_CMD"; fi
}
bg_reap() { # pid... call right after `cmd &` with "$!"
  local p spec
  if [[ "${BASHPID:-}" != "$$" ]]; then
    # A subshell (a command substitution, a function run inside one) cannot pass
    # its records to the main shell's list, and arming the trap here would reap
    # the recorded pids when the SUBSHELL exits, killing live fixtures. Refuse.
    return 0
  fi
  for p in "$@"; do GOVERN_TEST_BG_PIDS+=("$p"); done
  spec="$(trap -p EXIT)"
  if [[ "$spec" == "trap -- 'govern_bg_exit' EXIT" ]]; then return 0; fi
  GOVERN_BG_PREV_EXIT_CMD=""
  if [[ -n "$spec" ]]; then
    # `trap -p` prints `trap -- '<command>' EXIT`; peel the frame so what remains
    # is the bare command text, ready for eval. A trap whose own text contains
    # single quotes would need the escapes preserved instead; none in this suite.
    GOVERN_BG_PREV_EXIT_CMD="${spec#trap -- }"
    GOVERN_BG_PREV_EXIT_CMD="${GOVERN_BG_PREV_EXIT_CMD% EXIT}"
    GOVERN_BG_PREV_EXIT_CMD="${GOVERN_BG_PREV_EXIT_CMD#\'}"
    GOVERN_BG_PREV_EXIT_CMD="${GOVERN_BG_PREV_EXIT_CMD%\'}"
  fi
  trap 'govern_bg_exit' EXIT
  return 0
}

assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # haystack needle message
  # `grep <<<"$1"` (here-string), NOT `printf "$1" | grep -q`: a -q grep exits on first match and
  # SIGPIPEs the printf, which `set -o pipefail` then reports as a pipeline failure once the haystack
  # exceeds the 64KB pipe buffer (e.g. cat of a large script) — a false "not found".
  if grep -qF "$2" <<<"$1"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       [%s] not found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_not_contains() { # haystack needle message
  # Same here-string reasoning as assert_contains — never pipe the haystack into a -q grep.
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly PRESENT in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}
assert_done() { [[ "$ASSERT_FAILS" -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$ASSERT_FAILS"; exit 1; }; printf '\nall assertions passed\n'; }
