#!/usr/bin/env bash
# dispatch-packet.sh: everything a worker needs to start, written to disk instead of re-typed
# into a prompt or re-derived by the worker.
#
#   1. single ticket: worktree created (named t<N>), packet written with the ticket block verbatim,
#      the Advisor-consult budget line, the Worktree line; stdout is exactly the packet path then
#      the one-line dispatch prompt.
#   2. --adopt reuse: a second call for the SAME tickets does not error on "path already exists"
#      and reuses the same packet path.
#   3. a named GROUP: the worktree is keyed on the PRIMARY (first-named) ticket, both ticket blocks
#      are in the packet, and the GOVERN_BATCH_MEMBER_TURNS line appears (single-ticket does not).
#   4. recorded gotchas: a **Paths:**-tagged CLAUDE.md entry matching a ticket's own path shows up
#      in the packet's "Recorded gotchas" section.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

DP="$DIR/../dispatch-packet.sh"
[[ -f "$DP" ]] || { echo "SKIP: dispatch-packet.sh not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }

TICKETS_BODY='# Tickets

## #7 — tighten the alpha retry ladder

**Severity:** Low

**Where:** `alpha/retry.conf`

**Proposed solution:** cap it at three.

**Precision:** stated

Done when: the ladder stops at three.

---

## #8 — alpha: log every retry attempt

**Severity:** Low

**Proposed solution:** add one log line per retry.

**Precision:** open

Done when: a log line appears per retry.
'

setup_case() { # -> sets CASE_T; a real meta root + a real "alpha" sub-repo, worktree:new copied in
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mkdir -p "$t/scripts/worktree/lib" "$t/scripts/lib" "$t/alpha" "$t/queue" "$t/governor"
  cp "$DIR/../../worktree/new.sh" "$t/scripts/worktree/new.sh"
  cp "$DIR/../../worktree/lib/registry.sh" "$t/scripts/worktree/lib/registry.sh"
  cp "$DIR/../../worktree/lib/base-ref.sh" "$t/scripts/worktree/lib/base-ref.sh"
  cat > "$t/scripts/lib/workspace.sh" <<EOF
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
EOF

  printf '%s' "$TICKETS_BODY" > "$t/queue/tickets.md"

  git -C "$t" init -q -b main
  git -C "$t" config user.email t@t; git -C "$t" config user.name t
  echo root > "$t/root.txt"; git -C "$t" add -A; git -C "$t" commit -qm init >/dev/null

  git -C "$t/alpha" init -q -b main
  git -C "$t/alpha" config user.email t@t; git -C "$t/alpha" config user.name t
  echo "retry = 5" > "$t/alpha/retry.conf"; git -C "$t/alpha" add -A; git -C "$t/alpha" commit -qm init >/dev/null

  export GOVERN_WS_ROOT="$t"
  export GOVERN_QUEUE_DIR="$t/queue"
  export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10
}
run_dp() { local errfile; errfile="$(mktemp)"; ( cd "$CASE_T" && bash "$DP" "$@" ) 2>"$errfile"; local rc=$?; rm -f "$errfile"; return $rc; }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 1. single ticket
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
out1="$(run_dp 7)"; rc1=$?
assert_eq "$rc1" "0" "1. dispatch-packet exits 0 for a single ticket"
packet1="$(printf '%s\n' "$out1" | sed -n '1p')"
prompt1="$(printf '%s\n' "$out1" | sed -n '2p')"
assert_eq "$packet1" "$CASE_T/wt/t7/.dispatch-packet.md" "1. line 1 is the packet path, named t<N>"
assert_eq "$prompt1" "Resolve #7. Read your packet at $packet1 first and follow it." "1. line 2 is the exact one-line dispatch prompt"
assert_eq "$(printf '%s\n' "$out1" | wc -l | tr -d ' ')" "2" "1. stdout is EXACTLY two lines"
assert_eq "$([ -f "$packet1" ] && echo y || echo n)" "y" "1. the packet file exists"
pcontent1="$(cat "$packet1")"
assert_contains "$pcontent1" "## Ticket #7" "1. the packet names ticket #7"
assert_contains "$pcontent1" "tighten the alpha retry ladder" "1. the ticket's own heading is in the packet"
assert_contains "$pcontent1" "cap it at three" "1. the Proposed solution is in the packet verbatim"
assert_contains "$pcontent1" "Advisor-consult budget for #7: 1" "1. the stated-grade budget (1) is precomputed for the worker"
assert_contains "$pcontent1" "Worktree: $CASE_T/wt/t7" "1. the worktree path is in the packet"
assert_not_contains "$pcontent1" "GOVERN_BATCH_MEMBER_TURNS" "1. a single-ticket packet carries no batch-turns line"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 2. --adopt reuse: a second call for the same ticket does not error, same packet path
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
out2a="$(run_dp 7)"
out2b="$(run_dp 7)"; rc2b=$?
assert_eq "$rc2b" "0" "2. a second dispatch for the same ticket does not error (adopts, not re-creates)"
assert_eq "$(printf '%s\n' "$out2a" | sed -n '1p')" "$(printf '%s\n' "$out2b" | sed -n '1p')" "2. the packet path is identical across both calls"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 3. a named group: worktree keyed on the PRIMARY, both blocks present, batch-turns line present
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
out3="$(run_dp 7,8)"; rc3=$?
assert_eq "$rc3" "0" "3. a group dispatch exits 0"
packet3="$(printf '%s\n' "$out3" | sed -n '1p')"
prompt3="$(printf '%s\n' "$out3" | sed -n '2p')"
assert_eq "$packet3" "$CASE_T/wt/t7/.dispatch-packet.md" "3. the worktree is keyed on the PRIMARY (first-named) ticket, #7"
assert_eq "$prompt3" "Resolve #7, #8. Read your packet at $packet3 first and follow it." "3. the prompt names both tickets, primary first"
pcontent3="$(cat "$packet3")"
assert_contains "$pcontent3" "## Ticket #7" "3. ticket #7's block is in the packet"
assert_contains "$pcontent3" "## Ticket #8" "3. ticket #8's block is in the packet too"
assert_contains "$pcontent3" "log every retry attempt" "3. #8's own heading is present"
assert_contains "$pcontent3" "Advisor-consult budget for #8: 3" "3. #8's open-grade budget (3) is precomputed"
assert_contains "$pcontent3" "GOVERN_BATCH_MEMBER_TURNS: 60" "3. a multi-ticket packet carries the batch-turns default"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 4. recorded gotchas: a **Paths:**-tagged CLAUDE.md entry matching the ticket's own path
# ══════════════════════════════════════════════════════════════════════════════════════════════
export GOVERN_GOTCHA_INJECT=1   # assert.sh forces this off suite-wide; this is the test that opts back in
setup_case
cat > "$CASE_T/CLAUDE.md" <<'EOF'
## Recorded gotchas
### alpha's retry.conf silently caps at 10 upstream
**Paths:** alpha/retry.conf
Raising it past 10 needs a matching change in the alpha daemon's own config.
EOF
git -C "$CASE_T" add -A && git -C "$CASE_T" commit -qm "add gotcha" >/dev/null
out4="$(run_dp 7)"; rc4=$?
assert_eq "$rc4" "0" "4. dispatch-packet still exits 0 with a gotcha present"
packet4="$(printf '%s\n' "$out4" | sed -n '1p')"
assert_contains "$(cat "$packet4")" "silently caps at 10 upstream" "4. the recorded gotcha for the ticket's own path is folded into the packet"
rm -rf "$CASE_T"

assert_done
