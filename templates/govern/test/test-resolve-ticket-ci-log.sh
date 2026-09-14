#!/usr/bin/env bash
# resolve-ticket.sh's red-CI excerpt: on a merge-pr.sh rc=3 refusal (CI red/pending),
# resolve-ticket.sh calls the REAL ci-log.sh (stubbing only `gh`, never the network) and prints
# its bounded excerpt on stderr alongside the refusal.
#
#   1. a red-CI refusal with a fetchable log prints the excerpt AND still refuses to land.
#   2. a red-CI refusal whose log fetch fails prints the refusal alone, still refuses, with the
#      SAME exit status as case 1 — the excerpt must never change the outcome.
#   3. the excerpt is bounded by GOVERN_CI_LOG_MAX_LINES.
#   4. a green PR path never invokes the log fetch (no `gh ... checks` / `gh ... run view` call).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
CILOG="$DIR/../ci-log.sh"
[[ -f "$RT" && -f "$CILOG" ]] || { echo "SKIP: resolve-ticket.sh/ci-log.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# Sandbox next to STUBS of every collaborator EXCEPT ci-log.sh, which is the REAL script — only
# `gh` underneath it is stubbed, so this exercises ci-log.sh's actual fail-open behavior, not a
# fake of it.
cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$CILOG" "$T/bin/ci-log.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"

LANDED="$T/landed.log"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_CI_STATE:-green}"
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_MERGE_RC:-0}"
STUB

# `gh` stub, PATH-resolved (ci-log.sh and resolve-ticket.sh's worktree-teardown fallback both call
# `gh` by bare name). Logs every invocation to $GH_CALLS_LOG so a case can assert a call NEVER
# happened, and answers `pr checks` / `run view --log-failed` per STUB_GH_* knobs so a case can
# drive ci-log.sh through its real fail-open branches.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ -n "${GH_CALLS_LOG:-}" ]] && printf '%s\n' "$*" >> "$GH_CALLS_LOG"
case "$*" in
  *headRefName*) echo "stub-branch" ;;
  *"pr checks"*)
    if [[ "${STUB_GH_CHECKS_OK:-0}" == "1" ]]; then
      echo "https://github.com/acme/alpha/actions/runs/${STUB_GH_RUN_ID:-999}/job/1"
    fi
    ;;
  *"run view"*"--log-failed"*)
    [[ -n "${STUB_GH_LOG:-}" ]] && printf '%s\n' "$STUB_GH_LOG"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin"/*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH"
export LANDED_LOG="$LANDED"

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #41 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.
TIX
( cd "$T" && git add -A && git commit -qm init )

rpt() { printf '{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"prs":[]}'; }
run_rt() { # <ticket> ; STUB_* env passed by caller; writes stderr to $ERR, returns exit code
  ( cd "$T" && printf '%s' "$(rpt)" | bash "$T/bin/resolve-ticket.sh" "$1" >/dev/null 2>"$T/err.log" )
  echo "$?"
}
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

# ── 1. red CI, log fetches OK: excerpt printed, still refuses ──────────────────────────────────
: > "$LANDED"
rc="$(STUB_MERGE_RC=3 STUB_GH_CHECKS_OK=1 STUB_GH_LOG=$'boom: assertion failed\nexit 1' run_rt 41)"
err1="$(cat "$T/err.log")"
assert_eq "$(landed_count)" "0" "1. red-CI refusal with a fetchable log does not land"
assert_contains "$err1" "refused — CI is red or still pending" "1. the refusal message still prints"
assert_contains "$err1" "Failing CI log" "1. ci-log.sh's excerpt header prints alongside the refusal"
assert_contains "$err1" "boom: assertion failed" "1. the actual failing-step text is in the excerpt"
RC1="$rc"

# ── 2. red CI, log fetch fails (no failing check yet — e.g. still pending): refusal alone ──────
: > "$LANDED"
rc="$(STUB_MERGE_RC=3 STUB_GH_CHECKS_OK=0 run_rt 41)"
err2="$(cat "$T/err.log")"
assert_eq "$(landed_count)" "0" "2. red-CI refusal with a failed log fetch does not land"
assert_contains "$err2" "refused — CI is red or still pending" "2. the refusal message still prints"
assert_not_contains "$err2" "Failing CI log" "2. no excerpt header when the log fetch fails"
assert_eq "$rc" "$RC1" "2. a failed log fetch leaves the exit status identical to a fetched one"

# ── 3. the excerpt is bounded by GOVERN_CI_LOG_MAX_LINES ───────────────────────────────────────
: > "$LANDED"
biglog="$(for i in $(seq 1 50); do printf 'logline-%02d\n' "$i"; done)"
rc="$(STUB_MERGE_RC=3 STUB_GH_CHECKS_OK=1 STUB_GH_LOG="$biglog" GOVERN_CI_LOG_MAX_LINES=5 run_rt 41)"
err3="$(cat "$T/err.log")"
assert_contains "$err3" "logline-50" "3. the tail of the log (within bound) is present"
assert_not_contains "$err3" "logline-45" "3. lines past the GOVERN_CI_LOG_MAX_LINES bound are dropped"
n3="$(grep -c '^logline-' <<<"$err3")"
assert_eq "$n3" "5" "3. exactly GOVERN_CI_LOG_MAX_LINES log lines are printed"

# ── 4. green path never invokes the log fetch at all ───────────────────────────────────────────
: > "$LANDED"
GH_CALLS="$T/gh-calls.log"; : > "$GH_CALLS"
rc="$(STUB_MERGE_RC=0 GH_CALLS_LOG="$GH_CALLS" run_rt 41)"
assert_eq "$(landed_count)" "1" "4. a green merge still lands"
assert_not_contains "$(cat "$GH_CALLS")" "pr checks" "4. no gh pr-checks call on the green path"
assert_not_contains "$(cat "$GH_CALLS")" "run view" "4. no gh run-view (log-failed) call on the green path"

assert_done
