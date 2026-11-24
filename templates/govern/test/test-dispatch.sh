#!/usr/bin/env bash
# dispatch.sh: one command that runs the pre-dispatch gates, writes the packet (with its Model:
# line) and prints the ticket's own Proposed solution and Done when blocks plus the ready Agent call.
#
#   1. a proceeding ticket prints both blocks verbatim and an Agent call carrying the packet prompt,
#      with NO model param for the default sonnet.
#   2. --model opus records `Model: opus` in the packet and puts model: "opus" in the printed call.
#   3. a `skip:` verdict is passed through and writes no packet (negative control for 1).
#   4. a bad --model alias is refused.
#   5. a comma group prints one call naming the primary and both tickets' blocks.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

DS="$DIR/../dispatch.sh"
[[ -f "$DS" ]] || { echo "SKIP: dispatch.sh not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }

TICKETS_BODY='# Tickets

## #7 — tighten the alpha retry ladder

**Severity:** Low

**Where:** `alpha/retry.conf`

**Done when:** the ladder stops at three, and a test pins it.

**Proposed solution:** cap it at three.
Edit retry.conf only.

**Precision:** stated

---

## #8 — alpha: log every retry attempt

**Severity:** Low

**Where:** `alpha/retry.conf`

**Proposed solution:** add one log line per retry.

**Precision:** stated

Done when: a log line appears per retry.

---

## #9 — ops: rotate the provider credential by hand

**Severity:** Low

**NOT govern-automatable:** requires a human in a third-party console.

**Proposed solution:** n/a

Done when: rotated.
'

setup_case() { # sets CASE_T; a real meta root + a real "alpha" sub-repo, worktree:new copied in
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mkdir -p "$t/scripts/worktree/lib" "$t/scripts/lib" "$t/alpha" "$t/queue" "$t/governor"
  cp "$DIR/../../worktree/new.sh" "$t/scripts/worktree/new.sh"
  cp "$DIR/../../worktree/lib/registry.sh" "$t/scripts/worktree/lib/registry.sh"
  cp "$DIR/../../worktree/lib/base-ref.sh" "$t/scripts/worktree/lib/base-ref.sh"
  cat > "$t/scripts/lib/workspace.sh" <<EOF2
ROOT_PM=npm
GITHUB_ORG=acme
WORKTREE_BASE="$t/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
wsp_repo_slug() { printf 'acme/%s' "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "$t" "\$1"; }
wsp_is_merge_repo() { return 1; }
EOF2
  printf '%s' "$TICKETS_BODY" > "$t/queue/tickets.md"
  git -C "$t" init -q -b main
  git -C "$t" config user.email t@t; git -C "$t" config user.name t
  echo root > "$t/root.txt"; git -C "$t" add -A; git -C "$t" commit -qm init >/dev/null
  git -C "$t/alpha" init -q -b main
  git -C "$t/alpha" config user.email t@t; git -C "$t/alpha" config user.name t
  echo "retry = 5" > "$t/alpha/retry.conf"; git -C "$t/alpha" add -A; git -C "$t/alpha" commit -qm init >/dev/null
  export GOVERN_WS_ROOT="$t"
  export GOVERN_QUEUE_DIR="$t/queue"
  export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10 GOVERN_MIN_FREE_GB=0
}
run_ds() { ( cd "$CASE_T" && bash "$DS" "$@" ) 2>/dev/null; }

# 1. proceeding ticket, default model
setup_case
out="$(run_ds 7)"; rc=$?
assert_eq "$rc" "0" "1. dispatch exits 0"
assert_contains "$out" "cap it at three." "1. the Proposed solution is printed"
assert_contains "$out" "Edit retry.conf only." "1. a multi-line Proposed solution is printed whole"
assert_not_contains "$out" "Precision:" "1. the Proposed solution block stops at the next field"
assert_contains "$out" "the ladder stops at three, and a test pins it." "1. the Done when block is printed"
assert_contains "$out" 'subagent_type: "worker"' "1. the Agent call names the worker type"
assert_contains "$out" 'name: "worker-7"' "1. the Agent call names worker-<N>"
assert_contains "$out" "Resolve #7. Read your packet at $CASE_T/wt/t7/.dispatch-packet.md first and follow it." "1. the prompt is the packet line"
assert_not_contains "$out" "model:" "1. sonnet is the default: no model param in the call"
assert_contains "$(cat "$CASE_T/wt/t7/.dispatch-packet.md")" "Model: sonnet" "1. the packet records Model: sonnet"
rm -rf "$CASE_T"

# 2. --model opus
setup_case
out="$(run_ds 7 --model opus)"; rc=$?
assert_eq "$rc" "0" "2. dispatch --model opus exits 0"
assert_contains "$out" 'model: "opus",' "2. the printed call carries the opus model param"
assert_contains "$(cat "$CASE_T/wt/t7/.dispatch-packet.md")" "Model: opus" "2. the packet records Model: opus"
rm -rf "$CASE_T"

# 3. skip passes through, no packet written
setup_case
out="$(run_ds 9)"; rc=$?
assert_eq "$rc" "0" "3. a skip verdict is not an error"
assert_contains "$out" "skip: body marked" "3. the pre-dispatch skip line is passed through"
assert_not_contains "$out" 'subagent_type' "3. no Agent call is printed for a skipped ticket"
assert_eq "$([ -e "$CASE_T/wt/t9" ] && echo y || echo n)" "n" "3. no worktree or packet is created for a skipped ticket"
rm -rf "$CASE_T"

# 4. bad alias
setup_case
out="$(run_ds 7 --model gpt 2>&1)"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo y || echo n)" "y" "4. an unknown --model alias is refused"
rm -rf "$CASE_T"

# 5. group
setup_case
out="$(run_ds 7,8)"; rc=$?
assert_eq "$rc" "0" "5. a group dispatch exits 0"
assert_contains "$out" "cap it at three." "5. the first member's proposal is printed"
assert_contains "$out" "add one log line per retry." "5. the second member's proposal is printed"
assert_contains "$out" "a log line appears per retry." "5. a plain-text Done when line is printed too"
assert_contains "$out" 'name: "worker-7"' "5. the call is named for the primary"
assert_contains "$out" "Resolve #7, #8." "5. the prompt names both tickets"
rm -rf "$CASE_T"

assert_done
