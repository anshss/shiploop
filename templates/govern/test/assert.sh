#!/usr/bin/env bash
# Tiny assertion helper for govern smoke tests.
set -euo pipefail
ASSERT_FAILS=0

# ── Layout resolver (#255) ──────────────────────────────────────────────────
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

# Hermetic retry-classifier inputs: govern::retry_class reads these from the ENVIRONMENT, and the
# suite is routinely run BY a governor worker whose own session exports them (a CI-fix worker runs
# with GOVERN_FIX_CI=<repo>#<pr> set). Inheriting them makes every retry classify as `ci` and turns
# the sizing tests red for reasons that have nothing to do with the code under test. Clear them here
# so a run is identical inside and outside a governor session; the tests that EXERCISE a class set
# it explicitly per case.
unset GOVERN_FIX_CI GOVERN_RETRY_CLASS GOVERN_RETRY_CLASSIFY

# Hermetic sizing: the #21 scout runs a REAL `claude -p` pass on the dispatch path, so leaving it on
# would (a) make every run-loop test issue an implicit model call and (b) burn one invocation of the
# stubbed `claude` these tests script per-attempt — shifting a "attempt 1 drops, attempt 2 resolves"
# fixture by one and failing tests that have nothing to do with sizing. Off by default here; the
# scout's own test (test-scout-survey.sh) exercises the sanitize/clamp guard directly and sets what
# it needs explicitly.
export GOVERN_SCOUT=0

# Dispatch-path mechanisms added by the token-efficiency work, forced OFF for the whole suite.
#
# This follows the GOVERN_FIX_CI precedent and the standing rule it produced: a new mechanism on the
# dispatch path perturbs this suite, because the suite drives stateful fake-`claude` stubs that COUNT
# and TRACK every invocation and script per-attempt outcomes. A mechanism that resolves a ticket
# without spawning a worker (deterministic lane), skips a dispatch entirely (staleness gate, self-ref
# cap), or kills a worker early (early abort) shifts those fixtures by one and reddens tests that have
# nothing to do with it. Each feature's OWN test enables what it needs explicitly — never a per-test
# patch here.
#
# All of these already default to the same value in their scripts; setting them here is the seam that
# stops a LIVE governor session's exported env from leaking into a suite run inside it (the documented
# failure mode where GOVERN_ALLOW_CONCURRENT=1 leaks in and reddens the orphan sweep by design).
export GOVERN_DETERMINISTIC=0        # §4.2 zero-model resolution lane
export GOVERN_STALENESS_GATE=0       # §4.5 pre-dispatch staleness skip
export GOVERN_STALENESS_RUN_TESTS=0  # §4.5 never execute a queue-authored command in a test run
export GOVERN_EARLY_ABORT=0          # §4.4 in-flight worker watchdog
export GOVERN_RUN_MAX_TOKENS=0       # §5.7 run-level spend ceiling (0 = off)
export GOVERN_EVENTS=0               # fleet event log (lib/events.sh) — OFF for the whole suite
export GOVERN_OVERLAP_NUDGE=0        # dispatch-time overlap nudge (#139): its own test opts back in
export GOVERN_AUTO_BUDGETS=0         # run-end --enforce-budgets flush (#95): its own test opts back in

# §4.3 index rebuild fires post-resolve in run-loop.sh. It is git/grep only — no model call — but it
# walks every file in every stub repo on each resolved ticket, which is pure wall-clock in a suite
# that resolves hundreds of synthetic tickets. Its own test builds a real index explicitly.
export GOVERN_INDEX=0

# Seed a hermetic workspace stub so a test never depends on the LIVE scripts/lib/workspace.sh (its repo
# list / auto-merge allowlist) — common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh", so without
# this a test only "passes" when run from inside a real workspace whose config happens to match. Call it
# right after `mktemp -d`. Pass the auto-merge repos as a comma list (default "alpha"); REPOS = those plus
# a frontend "web" repo (PR-only). Exports GOVERN_WS_ROOT (+ GOVERN_EXTERNALIZE_LANE=0, harmless where the
# externalize lane doesn't exist, required where it does so run-loop's lane doesn't fire under the stub).
#   mk_ws_stub "$T"                     # alpha auto-mergeable, web PR-only
#   mk_ws_stub "$T" "alpha,api"         # alpha + api auto-mergeable
#   mk_ws_stub "$T" "" "alpha"          # alpha PR-only AND local-first (#72)
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
assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # haystack needle message
  # `grep <<<"$1"` (here-string), NOT `printf "$1" | grep -q`: a -q grep exits on first match and
  # SIGPIPEs the printf, which `set -o pipefail` then reports as a pipeline failure once the haystack
  # exceeds the 64KB pipe buffer (e.g. cat of a large script) — a false "not found" (#183).
  if grep -qF "$2" <<<"$1"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       [%s] not found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_not_contains() { # haystack needle message
  # Same here-string reasoning as assert_contains (#183) — never pipe the haystack into a -q grep.
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly PRESENT in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}
assert_done() { [[ "$ASSERT_FAILS" -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$ASSERT_FAILS"; exit 1; }; printf '\nall assertions passed\n'; }
