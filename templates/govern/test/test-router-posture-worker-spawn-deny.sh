#!/usr/bin/env bash
# router-posture-guard.sh: the worker-spawns-worker deny (header SIXTH behavior).
#
# A worker's own Agent calls are otherwise silent everywhere in this file -- GOVERN_RUN=1
# (autonomous lane) and a transcript under .../subagents/ (interactive lane) both exempt every
# OTHER lever, because a worker's own tool calls are the delegation TARGET, not a driver posture
# violation. This lever is the one exception: a worker spawning ANOTHER worker has no fan-out cap
# and no proposal-gate coverage of its own, so it must be denied even under those two exemptions.
#
# Contract:
#   1. subagent_type "worker" spawned by a caller whose OWN agent_type is "worker" is DENIED,
#      even under GOVERN_RUN=1 (autonomous lane).
#   2. ...and even with the transcript under .../subagents/ (interactive lane).
#   3. subagent_type "lookup"/"investigator" spawned by a worker is NEVER denied by this lever --
#      a worker's own reconnaissance is exactly what it's for.
#   4. subagent_type "worker" spawned by a NON-worker caller (agent_type absent, i.e. the driver)
#      is untouched by this lever (still subject to the ticket-route/proposal-gate levers, not
#      this one).
#   5. GOVERN_TICKET_ROUTE_GUARD=0 silences this lever too (it shares that switch, not a new one).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }
GUARD="$GOVERN_HOOKS_DIR/router-posture-guard.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PL="$T/payload.json"

payload() { # <subagent_type> <caller_agent_type> <transcript_path>
  python3 -c '
import json, sys
subagent_type, caller_agent_type, transcript_path = sys.argv[1:4]
d = {
    "tool_name": "Agent",
    "transcript_path": transcript_path,
    "session_id": "spawn-deny",
    "tool_input": {"prompt": "Resolve #1 end to end.", "description": "delegated task"},
}
if subagent_type:
    d["tool_input"]["subagent_type"] = subagent_type
if caller_agent_type:
    d["agent_type"] = caller_agent_type
print(json.dumps(d))
' "$1" "$2" "$3" > "$PL"
}

# ── 1. a worker caller spawning another worker is DENIED, even under GOVERN_RUN=1 ───────────
payload "worker" "worker" "/tmp/fake-transcript.jsonl"
out="$(GOVERN_RUN=1 bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' \
  "1a. a worker (agent_type=worker) spawning subagent_type worker is DENIED under GOVERN_RUN=1"
assert_contains "$out" "worker" "1b. the deny reason names what it is (a worker itself)"
assert_contains "$out" "lookup" "1c. the deny reason names the allowed alternative (lookup/investigator)"
assert_contains "$out" "GOVERN_TICKET_ROUTE_GUARD=0" "1d. the deny reason names its own kill switch"

# ── 2. same, under the INTERACTIVE lane (.../subagents/ transcript) instead of GOVERN_RUN ───
payload "worker" "worker" "/tmp/.claude/subagents/abc/transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' \
  "2. a worker spawning subagent_type worker is DENIED under the interactive (.../subagents/) lane too"

# ── 3. a worker spawning its own reconnaissance (lookup/investigator) is never touched ───────
for st in lookup investigator; do
  payload "$st" "worker" "/tmp/.claude/subagents/abc/transcript.jsonl"
  out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
  assert_eq "$out" "" "3.$st a worker spawning subagent_type $st is never denied by this lever"
done

# ── 4. subagent_type worker spawned by a NON-worker caller is untouched by THIS lever ────────
# (the driver dispatching a worker is normal, everyday operation -- the ticket-route/proposal-gate
# levers are what govern that call, not this one; this call carries no ticket number so those
# stay silent too, isolating this lever's own contract).
payload "worker" "" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' \
  "4. a driver (no agent_type) dispatching subagent_type worker is never denied by this lever"

# ── 5. kill switch ────────────────────────────────────────────────────────────────────────────
payload "worker" "worker" "/tmp/fake-transcript.jsonl"
out="$(GOVERN_RUN=1 GOVERN_TICKET_ROUTE_GUARD=0 bash "$GUARD" < "$PL" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' \
  "5. GOVERN_TICKET_ROUTE_GUARD=0 silences the worker-spawns-worker deny too"

assert_done
