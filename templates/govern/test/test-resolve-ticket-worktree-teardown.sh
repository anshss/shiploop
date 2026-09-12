#!/usr/bin/env bash
# resolve-ticket.sh's worktree-teardown step must never ASSUME the worktree is named
# `ticket-$N` (the interactive lane is self-service, worker.md's own convention is
# `t<N>`, and a non-ticket session can name it anything). This is a REGRESSION test for the fix:
# derive the name from the recorded `ticket-$N` convention FIRST (verified via worktree/rm.sh's
# own registry check, never assumed), and fall back to the merged PR's headRefName when that
# convention doesn't match, rather than silently failing teardown outright.
#
# Stubs `$WS_ROOT/scripts/worktree/rm.sh` with the SAME observable contract the real script has
# (wt_registry_path_for is its only early-exit-1, checked BEFORE any side effect — everything
# after is best-effort): unknown name -> exit 1, no side effect; known name -> "removed", exit 0.
#
#   A. headless-style: worktree registered as ticket-$N            -> torn down directly,
#      the PR-head-branch fallback (gh) is NEVER consulted.
#   B. interactive-style: worktree registered as t<N> (not ticket-$N) -> the ticket-$N attempt
#      is refused cleanly, THEN the PR's headRefName recovers t<N> and tears it down.
#   C. neither name is registered (teardown genuinely can't find it) -> resolve-ticket still
#      lands the ticket (teardown is best-effort, never a landing blocker) and says so on stderr.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue" "$T/governor" "$T/scripts/worktree"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cp "$RT" "$T/bin/resolve-ticket.sh"
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
printf 'green\n'
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin"/*.sh

# The REAL rm.sh's only early-exit is an unregistered name (checked before any side effect); every
# call recorded so the ORDER + ARGUMENTS a real run would use are provable, not just the outcome.
cat > "$T/scripts/worktree/rm.sh" <<'STUB'
#!/usr/bin/env bash
name="$1"
echo "rm.sh called with: $name" >> "$RM_CALLS_LOG"
if grep -qxF "$name" "$KNOWN_WORKTREES" 2>/dev/null; then
  echo "removed $name" >> "$RM_CALLS_LOG"
  exit 0
fi
echo "unknown worktree: $name" >&2
exit 1
STUB
chmod +x "$T/scripts/worktree/rm.sh"

# gh stub: headRefName -> $STUB_HEAD_REF; everything else (PR-hygiene backstop's own gh calls)
# fails harmlessly, same as the real gh would against a repo that doesn't exist.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh called: $*" >> "$GH_CALLS_LOG"
case "$*" in
  *headRefName*) printf '%s\n' "${STUB_HEAD_REF:-}"; [[ -n "${STUB_HEAD_REF:-}" ]] ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export LANDED_LOG="$LANDED"

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #41 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.
TIX
( cd "$T" && git add -A && git commit -qm init )

report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"prs":[]}'
run_rt() { # -> sets rc; combined stderr+stdout on stdout
  ( cd "$T" && printf '%s' "$report" | bash "$T/bin/resolve-ticket.sh" 41 2>&1 )
}

# ── A. headless-style: ticket-41 IS the registered worktree name ───────────────────────────────
: > "$LANDED"; : > "$T/rm-calls.log"; : > "$T/gh-calls.log"
printf 'ticket-41\n' > "$T/known-worktrees.txt"
export RM_CALLS_LOG="$T/rm-calls.log" GH_CALLS_LOG="$T/gh-calls.log" KNOWN_WORKTREES="$T/known-worktrees.txt"
out="$(run_rt)"
assert_eq "$(tr -cd '\n' < "$LANDED" | wc -c | tr -d ' ')" "1" "A: ticket still lands"
assert_contains "$(cat "$T/rm-calls.log")" "removed ticket-41" "A: worktree ticket-41 was torn down directly"
# The PR-hygiene backstop's OWN `gh pr list --json ...,headRefName` runs regardless (unrelated to
# teardown), so this checks for teardown's specific `gh pr view <N> ... headRefName` call, not the
# substring alone.
assert_not_contains "$(cat "$T/gh-calls.log")" "gh called: pr view" "A: the PR-head-branch fallback is NEVER consulted when ticket-\$N matches"

# ── B. interactive-style: t41 is registered, ticket-41 is NOT — recovered via the PR's headRefName ──
: > "$LANDED"; : > "$T/rm-calls.log"; : > "$T/gh-calls.log"
printf 't41\n' > "$T/known-worktrees.txt"
export STUB_HEAD_REF="t41"
out="$(run_rt)"
assert_eq "$(tr -cd '\n' < "$LANDED" | wc -c | tr -d ' ')" "1" "B: ticket still lands"
rmlog="$(cat "$T/rm-calls.log")"
assert_contains "$rmlog" "rm.sh called with: ticket-41" "B: the headless convention is tried FIRST"
assert_not_contains "$rmlog" "removed ticket-41" "B: ticket-41 is refused (never removed) — it isn't the real name"
assert_contains "$rmlog" "removed t41" "B: the PR's headRefName (t41) recovers the REAL worktree and it IS torn down"
assert_contains "$(cat "$T/gh-calls.log")" "gh called: pr view" "B: the PR-head-branch fallback WAS consulted"

# ── C. neither ticket-41 nor the PR's headRefName is a registered worktree ──────────────────────
: > "$LANDED"; : > "$T/rm-calls.log"; : > "$T/gh-calls.log"
printf 'something-else\n' > "$T/known-worktrees.txt"
export STUB_HEAD_REF="also-unregistered"
out="$(run_rt)"
assert_eq "$(tr -cd '\n' < "$LANDED" | wc -c | tr -d ' ')" "1" "C: teardown failure never blocks landing the ticket"
assert_contains "$out" "clean up manually" "C: an unrecoverable teardown says so on stderr rather than going silent"

assert_done
