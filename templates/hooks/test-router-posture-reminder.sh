#!/usr/bin/env bash
# Guard for templates/hooks/router-posture-reminder.sh's conditional clause: the ticket-shaped
# sentence in the once-per-session banner is now CONDITIONAL on a ticket's own
# **Proposed solution:** signal instead of always routing straight to a worker -- a dispatch
# QUALIFIER, not a dispatch ACCELERATOR.
#
# Why a FAKE scaffolded workspace, not GOVERN_WS_ROOT: the helper this hook calls
# (scripts/govern/ticket-proposal.sh -> lib/common.sh) hardcodes its workspace root as
# three directories up from its OWN location, unconditionally sourcing
# <root>/scripts/lib/workspace.sh -- there is no override seam reachable from a hook
# that only ever invokes it as a subprocess. So this test builds the real relative
# LAYOUT the workspace scripts assume (scripts/{lib,govern/{,lib}}/, queue/), copies
# the real ticket-proposal.sh + common.sh into it (never a stand-in for the code under
# test), and copies this hook itself into scripts/ so its own SELF_ROOT resolution
# lands on that fake root -- an integration test of the real lookup path, not a mock.
#
# Self-contained: no assert.sh. Exit 77 = SKIP (missing python3, or the hook itself
# not found beside this test -- both real preconditions, not doctrine).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/router-posture-reminder.sh"
[ -f "$HOOK" ] || { echo "SKIP: router-posture-reminder.sh not found beside this test"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"

# ── build the fake scaffolded workspace ─────────────────────────────────────────
FAKE="$T/fakews"
mkdir -p "$FAKE/scripts/lib" "$FAKE/scripts/govern/lib" "$FAKE/queue"
cat > "$FAKE/scripts/lib/workspace.sh" <<'WS'
META_ROOT="${META_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WS
PROP_SRC="$DIR/../govern/ticket-proposal.sh"
COMMON_SRC="$DIR/../govern/lib/common.sh"
if [ ! -f "$PROP_SRC" ] || [ ! -f "$COMMON_SRC" ]; then
  echo "SKIP: templates/govern/ticket-proposal.sh or lib/common.sh not resolvable (an older workspace layout) -- the hook itself must degrade gracefully here, covered separately below"
  PROP_SRC=""
fi
if [ -n "$PROP_SRC" ]; then
  cp "$PROP_SRC" "$FAKE/scripts/govern/ticket-proposal.sh"
  cp "$COMMON_SRC" "$FAKE/scripts/govern/lib/common.sh"
fi
cp "$HOOK" "$FAKE/scripts/router-posture-reminder.sh"
cat > "$FAKE/queue/tickets.md" <<'TICKETS'
## #501 — no proposal yet
**Where:** somewhere
**Observed:** something
**Fix:** something
**Done when:** something
---
## #502 — already has a proposal
**Proposed solution:** Edit foo.sh so the retry path backs off exponentially.
**Precision:** scoped
**Where:** somewhere
**Done when:** something
---
TICKETS

# run <session_id> <prompt> [workspace-root] -> banner text (or "")
run() {
  local sid="$1" prompt="$2" root="${3:-$FAKE}"
  python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "prompt": sys.argv[2]}))
' "$sid" "$prompt" | bash "$root/scripts/router-posture-reminder.sh" 2>/dev/null
}

DEFAULT_MARK='Ticket-shaped (a `## #N` block'

if [ -n "$PROP_SRC" ]; then
  echo "with a reachable scaffolded workspace + ticket-proposal.sh"

  out="$(run s1 "Please resolve ticket #501 end to end and open a PR.")"
  case "$out" in
    *"#501 has no"*"Proposed solution"*) ok "1. a ticket with NO proposal gets the qualifier clause, naming #501" ;;
    *) bad "1. expected the no-proposal qualifier naming #501, got: ${out:0:120}" ;;
  esac
  case "$out" in *"$DEFAULT_MARK"*) bad "1b. the qualifier clause must REPLACE the default clause, not sit beside it" ;; *) ok "1b. default clause is replaced, not duplicated" ;; esac

  out="$(run s2 "Please resolve ticket #502 end to end and open a PR.")"
  case "$out" in
    *"$DEFAULT_MARK"*) ok "2. a ticket that already carries a proposal routes to a worker as today (default clause)" ;;
    *) bad "2. expected today's default clause for a ticket with a proposal, got: ${out:0:120}" ;;
  esac

  out="$(run s3 "Investigate why the retry classifier misfires and report back.")"
  case "$out" in
    *"$DEFAULT_MARK"*) ok "3. no resolvable ticket number in the prompt -> default clause (can't check a specific ticket)" ;;
    *) bad "3. expected the default clause when no ticket number resolves, got: ${out:0:120}" ;;
  esac

  out="$(run s4 "PR #166 fixed the changelog bug. Now finish the migration end to end.")"
  case "$out" in
    *"$DEFAULT_MARK"*) ok "4. 'PR #166' alone is not a ticket reference -> default clause, not the #166 qualifier" ;;
    *"#166"*) bad "4. 'PR #166' was mistaken for a ticket reference: ${out:0:120}" ;;
    *) bad "4. expected the default clause, got: ${out:0:120}" ;;
  esac

  out="$(run s5 "PR #166 introduced the bug. Please resolve ticket #501 end to end.")"
  case "$out" in
    *"#501 has no"*"Proposed solution"*) ok "5. a real ticket ref alongside a PR ref still resolves to the REAL ticket (#501), not #166" ;;
    *) bad "5. expected the #501 qualifier (never #166), got: ${out:0:120}" ;;
  esac
else
  ok "SKIP-noted: not testable in this layout (see SKIP message above)"
fi

echo "degrades gracefully with no scaffolded workspace reachable at all"
NOWS="$T/no-workspace"
mkdir -p "$NOWS/scripts"
cp "$HOOK" "$NOWS/scripts/router-posture-reminder.sh"
out="$(run s6 "Please resolve ticket #501 end to end and open a PR." "$NOWS")"
case "$out" in
  *"$DEFAULT_MARK"*) ok "6. no scripts/govern/ticket-proposal.sh reachable -> default clause, never a crash" ;;
  *) bad "6. expected graceful degradation to the default clause, got: ${out:0:120}" ;;
esac

echo "once-per-session marker (unaffected by this change)"
out1="$(run s7 "Please resolve ticket #501 end to end.")"
out2="$(run s7 "second prompt in the same session")"
[ -n "$out1" ] && [ -z "$out2" ] && ok "7. fires once per session_id, silent on the second prompt" \
  || bad "7. expected fire-once (first=${#out1}B, second=${#out2}B)"

echo "exit code contract: the hook itself always exits 0"
printf '%s' '{"session_id":"s8","prompt":"hi"}' | bash "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "8. exits 0 even with no stdin JSON fields beyond the minimum" || bad "8. exited $rc, must never be nonzero"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
