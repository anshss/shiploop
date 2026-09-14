#!/usr/bin/env bash
# resolve-ticket.sh's root-scope landing path: a ticket whose fix reaches into ONLY root paths
# (scripts/**, governor/**) has no sub-repo PR of its own — the worker commits on its meta
# worktree's detached HEAD instead, names those commits in the report's `rootScope`, and this
# script cherry-picks them onto the main checkout's local `main` BEFORE handing the report to
# land-resolution.sh (ordering is load-bearing: a landing failure must refuse the WHOLE resolve
# while the ticket is still queued, never delete the block against work that never landed).
#
# Covered, against a REAL git repo (no stubbed land-resolution.sh — the block-delete is real):
#   1. a valid rootScope commit lands on main AND the queue block is then deleted.
#   2. a cherry-pick conflict refuses BEFORE any bookkeeping: main is rolled back to its prehead,
#      the working tree is left clean, and the queue block survives byte-identical.
#   3. a rootScope commit that touches a sub-repo path is refused outright — never cherry-picked.
#   4. teardown's safety net: a worktree holding a commit the report never named in
#      rootScope.commits is left INTACT (rm.sh is never even invoked), never silently destroyed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
LR="$DIR/../land-resolution.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }
[[ -f "$LR" ]] || { echo "SKIP: land-resolution.sh not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }

TICKET_BODY='# Tickets

## #9 — root-only fix with no sub-repo PR

**Severity:** Medium

Done when: it lands on main.
'

# Sets $CASE_T as a side effect — MUST be called un-subshelled (`setup_case; t="$CASE_T"`, never
# `t="$(setup_case)"`): mk_ws_stub's `export`s only reach the caller's environment when this runs
# in the current shell, a command-substitution subshell would swallow every one of them silently.
setup_case() {
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mk_ws_stub "$t"
  export GOVERN_QUEUE_DIR="$t/queue"
  mkdir -p "$t/bin/lib" "$t/queue" "$t/governor"
  ( cd "$t" && git init -q && git checkout -q -b main \
      && git config user.email t@t && git config user.name t )
  printf '%s' "$TICKET_BODY" > "$t/queue/tickets.md"
  # governor/ here only ever holds RUNTIME artifacts (ticket-history.jsonl, the bookkeep lock) —
  # gitignored in a real workspace too — so a resolve-ticket.sh run writing into it must never
  # trip this fixture's own "is the tree clean" checks.
  printf 'governor/\n' > "$t/.gitignore"
  # The scaffolding (bin/) is committed BEFORE any assertion runs against the tree's cleanliness —
  # the main checkout dirty-tree gate (the rootScope landing step's own precondition) must see a
  # genuinely clean tree here, exactly like a real main checkout between resolves.
  cp "$RT" "$t/bin/resolve-ticket.sh"
  cp "$LR" "$t/bin/land-resolution.sh"
  cp "$DIR/../lib/common.sh" "$t/bin/lib/common.sh"
  [[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$t/bin/lib/"
  chmod +x "$t/bin"/*.sh
  ( cd "$t" && git add -A && git commit -qm init )
}
run_rt() { # <root> <ticket> <report-json> -> combined stdout+stderr, use $? for rc
  local t="$1" n="$2" report="$3"
  ( cd "$t" && GOVERN_INDEX=0 printf '%s' "$report" | GOVERN_INDEX=0 bash "$t/bin/resolve-ticket.sh" "$n" 2>&1 )
}
block_present() { command grep -qE '^##[[:space:]]+#9([^0-9]|$)' "$1/queue/tickets.md"; }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 1. a valid rootScope commit lands on main and the queue block is deleted
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case; T1="$CASE_T"
( cd "$T1" && git checkout -q -b scratch \
    && mkdir -p scripts && echo hello > scripts/rootwork.txt \
    && git add scripts/rootwork.txt && git commit -qm "root work" \
    && git checkout -q main )
SHA1="$(git -C "$T1" rev-parse scratch)"
report1="$(printf '{"status":"resolved","rootScope":{"worktree":"t9","commits":["%s"]}}' "$SHA1")"
out1="$(run_rt "$T1" 9 "$report1")"; rc1=$?
assert_eq "$rc1" "0" "1. a valid rootScope commit: resolve-ticket exits 0"
assert_eq "$(cat "$T1/scripts/rootwork.txt" 2>/dev/null)" "hello" "1. the commit's content is on main's working tree"
if block_present "$T1"; then assert_eq present absent "1. the queue block is deleted after landing"
else assert_eq absent absent "1. the queue block is deleted after landing"; fi
rm -rf "$T1"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 2. a cherry-pick CONFLICT refuses before any bookkeeping: rollback to prehead, block survives
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case; T2="$CASE_T"
( cd "$T2" && mkdir -p scripts && printf 'line1\n' > scripts/conflict.txt \
    && git add scripts/conflict.txt && git commit -qm "base state" )
( cd "$T2" && git checkout -q -b scratch \
    && printf 'scratch-edit\n' > scripts/conflict.txt \
    && git commit -qam "scratch edit" \
    && git checkout -q main )
SHA2="$(git -C "$T2" rev-parse scratch)"
# main diverges incompatibly on the SAME line after the scratch commit was taken — this is what
# makes the later cherry-pick conflict rather than fast-forward cleanly.
( cd "$T2" && printf 'main-edit\n' > scripts/conflict.txt && git commit -qam "main diverged" )
PREHEAD2="$(git -C "$T2" rev-parse HEAD)"
report2="$(printf '{"status":"resolved","rootScope":{"worktree":"t9","commits":["%s"]}}' "$SHA2")"
out2="$(run_rt "$T2" 9 "$report2")"; rc2=$?
assert_eq "$rc2" "10" "2. a cherry-pick conflict: resolve-ticket refuses (exit 10)"
assert_eq "$(git -C "$T2" rev-parse HEAD)" "$PREHEAD2" "2. main is rolled back to its captured prehead"
assert_eq "$(git -C "$T2" status --porcelain)" "" "2. the working tree is left clean (no conflict markers, no stray cherry-pick state)"
if block_present "$T2"; then assert_eq present present "2. the queue block survives byte-identical"
else assert_eq absent present "2. the queue block survives byte-identical"; fi
assert_contains "$out2" "cherry-pick failed" "2. the refusal names itself on stderr"
rm -rf "$T2"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 3. a rootScope commit touching a sub-repo path is refused outright, never cherry-picked
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case; T3="$CASE_T"
PREHEAD3="$(git -C "$T3" rev-parse HEAD)"
( cd "$T3" && git checkout -q -b scratch \
    && mkdir -p alpha && echo x > alpha/subrepo-file.txt \
    && git add alpha/subrepo-file.txt && git commit -qm "touches a sub-repo path" \
    && git checkout -q main )
SHA3="$(git -C "$T3" rev-parse scratch)"
report3="$(printf '{"status":"resolved","rootScope":{"worktree":"t9","commits":["%s"]}}' "$SHA3")"
out3="$(run_rt "$T3" 9 "$report3")"; rc3=$?
assert_eq "$rc3" "10" "3. a sub-repo-path commit: resolve-ticket refuses (exit 10)"
assert_eq "$(git -C "$T3" rev-parse HEAD)" "$PREHEAD3" "3. main is untouched (never even attempted the cherry-pick)"
assert_contains "$out3" "touches sub-repo path" "3. the refusal names the offending path"
if block_present "$T3"; then assert_eq present present "3. the queue block survives byte-identical"
else assert_eq absent present "3. the queue block survives byte-identical"; fi
rm -rf "$T3"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 4. teardown's safety net: an unreported commit on the worktree blocks its own removal
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case; T4="$CASE_T"
REGISTRY_LIB="$DIR/../../worktree/lib/registry.sh"
mkdir -p "$T4/scripts/worktree/lib"
cp "$REGISTRY_LIB" "$T4/scripts/worktree/lib/registry.sh"
RM_CALLS="$T4/rm-calls.log"; : > "$RM_CALLS"
cat > "$T4/scripts/worktree/rm.sh" <<'STUB'
#!/usr/bin/env bash
echo "rm.sh called with: $1" >> "$RM_CALLS_LOG"
exit 0
STUB
chmod +x "$T4/scripts/worktree/rm.sh"
export RM_CALLS_LOG="$RM_CALLS"

git -C "$T4" worktree add -q --detach "$T4/wt/ticket-9" main
mkdir -p "$T4/wt/ticket-9/scripts"
echo forgotten > "$T4/wt/ticket-9/scripts/extra.txt"
( cd "$T4/wt/ticket-9" && git add scripts/extra.txt && git commit -qm "root work never reported" )
mkdir -p "$T4/.worktrees"
jq -n --arg root "$T4" \
  '{slots: {"0": {name: "__main__", path: $root}, "1": {name: "ticket-9", path: ($root + "/wt/ticket-9")}}, nextSlot: 2}' \
  > "$T4/.worktrees/registry.json"

# lessonPatch (not rootScope) is what makes THIS resolve non-empty — the whole point of the case is
# that the worker forgot to report rootScope entirely while its worktree still holds real commits.
report4='{"status":"resolved","lessonPatch":{"file":"CLAUDE.md","anchor":"## Misc","text":"x"}}'
out4="$(run_rt "$T4" 9 "$report4")"; rc4=$?
assert_eq "$rc4" "0" "4. the ticket's own resolution still lands (teardown is best-effort, not a landing blocker)"
if block_present "$T4"; then assert_eq present absent "4. the queue block is deleted (the resolve itself succeeded)"
else assert_eq absent absent "4. the queue block is deleted (the resolve itself succeeded)"; fi
assert_eq "$(cat "$RM_CALLS")" "" "4. rm.sh is NEVER invoked — the safety net refuses before the teardown call"
assert_contains "$out4" "refusing to tear it down" "4. the refusal names itself on stderr"
assert_eq "$(git -C "$T4/wt/ticket-9" log -1 --format=%s)" "root work never reported" "4. the unreported commit is still sitting on the worktree, untouched"
rm -rf "$T4"

assert_done
