#!/usr/bin/env bash
# Guard for templates/hooks/advisor-steer-guard.sh: the per-session cap on messages the advisor
# sends DOWN to workers it dispatched. Drives the real hook with real PreToolUse payloads, one
# process per tool call, exactly as the runtime does -- the state it counts with lives in TMPDIR, so
# a scratch TMPDIR plus a fresh session id per case is a clean slate with no mocking anywhere.
#
# What is asserted: a dispatch registers the worker's address; messages to it are counted; the first
# message PAST the cap is denied and the denial names its kill switch; messages to `main` (a worker
# reporting up, or the advisor answering its own parent) are never counted; a subagent's own calls
# are never counted; and GOVERN_STEER_CAP=0 disables the gate entirely.
#
# Self-contained: no assert.sh. Exit 77 = SKIP (missing python3, or the hook not found beside this
# test) -- real preconditions, not doctrine.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/advisor-steer-guard.sh"
[ -f "$HOOK" ] || { echo "SKIP: advisor-steer-guard.sh not found beside this test"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset GOVERN_RUN 2>/dev/null || true

CAP=3
export GOVERN_STEER_CAP="$CAP"

# dispatch <session_id> <worker-name> -> hook output (always empty; a dispatch is never denied here)
dispatch() {
  python3 -c '
import json, sys
print(json.dumps({
  "tool_name": "Agent",
  "session_id": sys.argv[1],
  "transcript_path": "/tmp/driver-transcript.jsonl",
  "tool_input": {"subagent_type": "worker", "name": sys.argv[2], "prompt": "resolve it", "description": "dispatch"},
}))
' "$1" "$2" | bash "$HOOK" 2>/dev/null
}

# steer <session_id> <to> [agent_id] -> hook output (empty = allowed)
steer() {
  python3 -c '
import json, sys
d = {
  "tool_name": "SendMessage",
  "session_id": sys.argv[1],
  "transcript_path": "/tmp/driver-transcript.jsonl",
  "tool_input": {"to": sys.argv[2], "message": "try the other branch"},
}
if len(sys.argv) > 3 and sys.argv[3]:
    d["agent_id"] = sys.argv[3]
print(json.dumps(d))
' "$1" "$2" "${3:-}" | bash "$HOOK" 2>/dev/null
}

denied() { case "$1" in *'"deny"'*) return 0 ;; esac; return 1; }

echo "cap enforcement (GOVERN_STEER_CAP=$CAP)"

dispatch s1 fixer >/dev/null
allowed_all=1
for i in $(seq 1 "$CAP"); do
  out="$(steer s1 fixer)"
  if denied "$out"; then allowed_all=0; bad "1. steer #$i of $CAP was denied early: ${out:0:120}"; fi
done
[ "$allowed_all" = 1 ] && ok "1. the first $CAP steers to a dispatched worker are all allowed"

out="$(steer s1 fixer)"
if denied "$out"; then ok "2. steer $((CAP + 1)) is denied"
else bad "2. expected a deny on steer $((CAP + 1)), got: ${out:0:160}"; fi
case "$out" in *GOVERN_STEER_CAP*) ok "3. the denial names GOVERN_STEER_CAP so the operator can raise or disable it" ;;
  *) bad "3. denial text must name GOVERN_STEER_CAP, got: ${out:0:200}" ;; esac

echo "what is NOT a steer"

dispatch s2 fixer >/dev/null
noise=0
for i in 1 2 3 4 5 6; do
  out="$(steer s2 main)"
  denied "$out" && noise=1
done
[ "$noise" = 0 ] && ok "4. messages to \`main\` are never denied" || bad "4. a message to main was denied"
still_free=1
for i in $(seq 1 "$CAP"); do
  out="$(steer s2 fixer)"
  denied "$out" && still_free=0
done
[ "$still_free" = 1 ] && ok "5. messages to \`main\` did not consume the steer budget" \
  || bad "5. the main messages were counted against the cap"
out="$(steer s2 fixer)"
denied "$out" && ok "6. the cap still fires once the real steers exceed it" \
  || bad "6. expected a deny after $CAP real steers in session s2"

dispatch s3 fixer >/dev/null
child_denied=0
for i in 1 2 3 4 5 6; do
  out="$(steer s3 fixer "a1b2c3d4")"
  denied "$out" && child_denied=1
done
[ "$child_denied" = 0 ] && ok "7. a subagent's own messages (agent_id present) are never counted: a worker asking up is a consult, not a steer" \
  || bad "7. a call carrying agent_id was counted as a steer"

out="$(steer s4 fixer)"
if denied "$out"; then bad "8. a session that never dispatched a worker must not be gated"
else ok "8. no dispatch recorded for the session -> nothing is a steer"; fi

echo "kill switch"

GOVERN_STEER_CAP=0 dispatch s5 fixer >/dev/null
off_denied=0
for i in 1 2 3 4 5 6 7 8; do
  out="$(GOVERN_STEER_CAP=0 steer s5 fixer)"
  denied "$out" && off_denied=1
done
[ "$off_denied" = 0 ] && ok "9. GOVERN_STEER_CAP=0 disables the gate entirely" \
  || bad "9. GOVERN_STEER_CAP=0 still denied a steer"

echo "exit code contract: the hook itself always exits 0"
steer s1 fixer >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "10. exits 0 on the deny path too (the decision travels in the JSON)" \
  || bad "10. exited $rc, must never be nonzero"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
