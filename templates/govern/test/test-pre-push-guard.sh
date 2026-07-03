#!/usr/bin/env bash
# Regression for #301: the harness .githooks/pre-push guard must reject a feature branch whose name
# isn't exactly `ticket-<N>` when GOVERN_RUN=1. A govern worker's branch MUST be ticket-<N> (#55) so
# the governor can find + merge the PR; a wrong name silently orphans the PR and re-fails the ticket.
# The hook turns that into a loud pre-push error.
#
# Contract exercised (hook reads push refs on stdin: "<localref> <localsha> <remoteref> <remotesha>"):
#   GOVERN_RUN=1  + refs/heads/ticket-301          -> allowed (exit 0)
#   GOVERN_RUN=1  + refs/heads/main                -> allowed (exit 0)
#   GOVERN_RUN=1  + refs/heads/fix/foo             -> BLOCKED (exit 1, clear message)
#   GOVERN_RUN=1  + refs/heads/ticket-301-extra    -> BLOCKED (strict: no suffix)
#   GOVERN_RUN=1  + refs/heads/ticketfoo           -> BLOCKED (must be ticket-<digits>)
#   (unset)       + refs/heads/ticket-301          -> BLOCKED (normal session never PRs the harness)
#   (unset)       + refs/heads/main                -> allowed (direct main push is the normal path)
# No network, no real remote.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e   # assert.sh sets -e; we drive the hook and inspect exit codes ourselves

# Resolve the hook in both layouts: scaffolded workspace (<root>/.githooks/) and the template repo
# (templates/githooks/, i.e. two levels up from this test dir).
HOOK="$DIR/../../../.githooks/pre-push"
[ -x "$HOOK" ] || HOOK="$DIR/../../githooks/pre-push"
[ -x "$HOOK" ] || { echo "SKIP: pre-push hook not found/executable"; exit 0; }

# run_hook GOVERN_RUN_VALUE REMOTEREF  -> sets $rc and $err (stderr)
run_hook() {
  local gr="$1" remoteref="$2" line
  line="refs/heads/local abc123 $remoteref def456"
  if [ "$gr" = "-" ]; then
    err="$(printf '%s\n' "$line" | env -u GOVERN_RUN bash "$HOOK" 2>&1 >/dev/null)"; rc=$?
  else
    err="$(printf '%s\n' "$line" | GOVERN_RUN="$gr" bash "$HOOK" 2>&1 >/dev/null)"; rc=$?
  fi
}

# ── GOVERN_RUN=1 ──────────────────────────────────────────────────────────────
run_hook 1 refs/heads/ticket-301
assert_eq "$rc" "0" "GOVERN_RUN=1 + ticket-301 (canonical worker branch) is allowed"

run_hook 1 refs/heads/main
assert_eq "$rc" "0" "GOVERN_RUN=1 + main is allowed"

run_hook 1 refs/heads/fix/foo
assert_eq "$rc" "1" "GOVERN_RUN=1 + fix/foo (wrong-name feature branch) is BLOCKED"
assert_contains "$err" "not a 'ticket-<N>' branch" "blocked message names the ticket-<N> rule"
assert_contains "$err" "#55" "blocked message cites the orphaned-PR failure (#55)"

run_hook 1 refs/heads/ticket-301-extra
assert_eq "$rc" "1" "GOVERN_RUN=1 + ticket-301-extra (suffix) is BLOCKED — name must be exact"

run_hook 1 refs/heads/ticketfoo
assert_eq "$rc" "1" "GOVERN_RUN=1 + ticketfoo (non-numeric) is BLOCKED"

# ── normal interactive session (GOVERN_RUN unset) ────────────────────────────
run_hook - refs/heads/ticket-301
assert_eq "$rc" "1" "no GOVERN_RUN + any feature branch is BLOCKED (harness PRs are governor-only)"
assert_contains "$err" "commit directly to 'main'" "normal-session message points to the main path"

run_hook - refs/heads/main
assert_eq "$rc" "0" "no GOVERN_RUN + main is allowed (direct main push is the normal path)"

assert_done
