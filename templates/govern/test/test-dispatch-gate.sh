#!/usr/bin/env bash
# The dispatch-packet gate in router-posture-guard.sh: an Agent(subagent_type: "worker") call must
# name a packet file that exists, lists every ticket the call is about, is fresher than
# GOVERN_DISPATCH_FRESH_HOURS, and carries a `Model:` line equal to the call's `model` param (no
# param means sonnet). Every deny prints the exact govern:dispatch command.
#
# Each denial case has a paired allow case differing in exactly the one property under test, so a
# gate that denied everything (or nothing) cannot pass.
#
# The hook is copied into a fake scaffolded root so its own root resolution lands there, the same
# technique test-proposal-gate-dispatch.sh uses.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HOOK="${GOVERN_HOOKS_DIR:-}/router-posture-guard.sh"
[[ -f "$HOOK" ]] || { echo "SKIP: router-posture-guard.sh not found"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset GOVERN_RUN GOVERN_TICKET_ROUTE_GUARD GOVERN_DISPATCH_FRESH_HOURS 2>/dev/null || true
export GOVERN_DISPATCH_GATE=1   # assert.sh pins it off suite-wide; this is the test that opts in
export GOVERN_PROPOSAL_GATE=0   # the proposal gate has its own test; no queue needed here

FAKE="$T/fakews"
mkdir -p "$FAKE/scripts/lib" "$FAKE/queue" "$T/wt"
cat > "$FAKE/scripts/lib/workspace.sh" <<'WS'
META_ROOT="${META_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export META_ROOT
ROOT_PM=npm
WS
cp "$HOOK" "$FAKE/scripts/router-posture-guard.sh"

mk_packet() { # <file> <heading-refs> <model-line|""> <created-epoch>
  {
    printf '<!-- GOVERN:PACKET-CREATED %s -->\n' "$4"
    printf '# Dispatch packet for %s\n\n' "$2"
    printf 'Worktree: %s\n' "$(dirname "$1")"
    [[ -n "$3" ]] && printf 'Model: %s\n' "$3"
    printf '\n## Ticket\n'
  } > "$1"
}
NOW="$(date +%s)"
mk_packet "$T/wt/fresh.md.dispatch-packet.md" "#7" "sonnet" "$NOW"
mk_packet "$T/wt/group.dispatch-packet.md" "#7, #8" "sonnet" "$NOW"
mk_packet "$T/wt/stale.dispatch-packet.md" "#7" "sonnet" "$(( NOW - 7 * 3600 ))"
mk_packet "$T/wt/opus.dispatch-packet.md" "#7" "opus" "$NOW"
mk_packet "$T/wt/nomodel.dispatch-packet.md" "#7" "" "$NOW"
FRESH="$T/wt/fresh.md.dispatch-packet.md"; GROUP="$T/wt/group.dispatch-packet.md"
STALE="$T/wt/stale.dispatch-packet.md"; OPUS="$T/wt/opus.dispatch-packet.md"; NOMODEL="$T/wt/nomodel.dispatch-packet.md"

spawn() { # <prompt> [model]  -> whatever the hook printed (empty = allow)
  python3 -c '
import json, sys
ti = {"subagent_type": "worker", "description": "dispatch", "prompt": sys.argv[1]}
if len(sys.argv) > 2 and sys.argv[2]:
    ti["model"] = sys.argv[2]
print(json.dumps({"tool_name": "Agent", "session_id": "gate-test", "transcript_path": "/tmp/driver.jsonl", "tool_input": ti}))
' "$1" "${2:-}" | bash "$FAKE/scripts/router-posture-guard.sh" 2>/dev/null
}
is_deny() { case "$1" in *'"deny"'*DISPATCH\ GATE*|*DISPATCH\ GATE*'"deny"'*) return 0 ;; esac; return 1; }
prompt_for() { printf 'Resolve %s. Read your packet at %s first and follow it.' "$1" "$2"; }

out="$(spawn "$(prompt_for '#7' "$FRESH")")"
is_deny "$out" && assert_eq denied allowed "fresh packet listing #7, no model param: allowed" \
  || assert_eq allowed allowed "fresh packet listing #7, no model param: allowed"

out="$(spawn "Resolve #7. Do the work in t7 now.")"
if is_deny "$out"; then assert_eq denied denied "no packet named: denied"; else assert_eq allowed denied "no packet named: denied"; fi
assert_contains "$out" "npm run govern:dispatch -- 7" "the no-packet deny prints the exact govern:dispatch command"

out="$(spawn "$(prompt_for '#7' "$T/wt/missing.dispatch-packet.md")")"
if is_deny "$out"; then assert_eq denied denied "named packet does not exist: denied"; else assert_eq allowed denied "named packet does not exist: denied"; fi

out="$(spawn "$(prompt_for '#7' "$STALE")")"
if is_deny "$out"; then assert_eq denied denied "stale packet (7h, limit 6h): denied"; else assert_eq allowed denied "stale packet (7h, limit 6h): denied"; fi
assert_contains "$out" "older than 6h" "the stale deny names the freshness limit"
out="$(GOVERN_DISPATCH_FRESH_HOURS=8 spawn "$(prompt_for '#7' "$STALE")")"
is_deny "$out" && assert_eq denied allowed "same packet under GOVERN_DISPATCH_FRESH_HOURS=8: allowed" \
  || assert_eq allowed allowed "same packet under GOVERN_DISPATCH_FRESH_HOURS=8: allowed"

out="$(spawn "$(prompt_for '#7, #8' "$FRESH")")"
if is_deny "$out"; then assert_eq denied denied "packet lists #7 only, call names #7 and #8: denied"; else assert_eq allowed denied "packet lists #7 only, call names #7 and #8: denied"; fi
assert_contains "$out" "does not list #8" "the missing-ticket deny names the ticket"
assert_contains "$out" "govern:dispatch -- 7,8" "the missing-ticket deny prints the group command"
out="$(spawn "$(prompt_for '#7, #8' "$GROUP")")"
is_deny "$out" && assert_eq denied allowed "packet lists #7 and #8: allowed" \
  || assert_eq allowed allowed "packet lists #7 and #8: allowed"

out="$(spawn "$(prompt_for '#7' "$FRESH")" opus)"
if is_deny "$out"; then assert_eq denied denied "call model opus, packet Model sonnet: denied"; else assert_eq allowed denied "call model opus, packet Model sonnet: denied"; fi
assert_contains "$out" "omit the" "the model-mismatch deny says how to fix the call"
out="$(spawn "$(prompt_for '#7' "$OPUS")")"
if is_deny "$out"; then assert_eq denied denied "no model param, packet Model opus: denied"; else assert_eq allowed denied "no model param, packet Model opus: denied"; fi
assert_contains "$out" 'model: \"opus\"' "the deny prints the model param to pass"
out="$(spawn "$(prompt_for '#7' "$OPUS")" opus)"
is_deny "$out" && assert_eq denied allowed "call model opus, packet Model opus: allowed" \
  || assert_eq allowed allowed "call model opus, packet Model opus: allowed"
out="$(spawn "$(prompt_for '#7' "$OPUS")" claude-opus-5-5)"
is_deny "$out" && assert_eq denied allowed "a full model id resolves to its alias: allowed" \
  || assert_eq allowed allowed "a full model id resolves to its alias: allowed"
out="$(spawn "$(prompt_for '#7' "$NOMODEL")" sonnet)"
is_deny "$out" && assert_eq denied allowed "packet with no Model line reads as sonnet: allowed" \
  || assert_eq allowed allowed "packet with no Model line reads as sonnet: allowed"

out="$(GOVERN_DISPATCH_GATE=0 spawn "Resolve #7. Do the work in t7 now.")"
is_deny "$out" && assert_eq denied allowed "GOVERN_DISPATCH_GATE=0: a packetless spawn is allowed" \
  || assert_eq allowed allowed "GOVERN_DISPATCH_GATE=0: a packetless spawn is allowed"

assert_done
