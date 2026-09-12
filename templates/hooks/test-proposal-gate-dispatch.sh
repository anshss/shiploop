#!/usr/bin/env bash
# Guard for the proposed-solution gate inside templates/hooks/router-posture-guard.sh: an in-session
# worker dispatch on a ticket that carries no `**Proposed solution:**` is DENIED, one that carries a
# proposal is allowed, GOVERN_PROPOSAL_GATE=0 turns the gate off, and anything the hook cannot
# resolve (no ticket number in the call, no helper on this install) degrades to ALLOW.
#
# Why a FAKE scaffolded workspace, not an env override: the helper the hook shells out to
# (scripts/govern/ticket-proposal.sh -> lib/common.sh) resolves its workspace root from its OWN
# location and sources <root>/scripts/lib/workspace.sh unconditionally, and the hook resolves the
# helper relative to its own path. There is no seam to point either at a fixture. So this test
# builds the real relative layout (scripts/{lib,govern/{,lib}}/, queue/), copies the REAL helper and
# common.sh into it, and copies the hook itself into scripts/ so its own root resolution lands
# there. That exercises the actual lookup and the actual proposal parser, not a stand-in.
#
# Self-contained: no assert.sh. Exit 77 = SKIP (missing python3, or the hook not found beside this
# test) -- real preconditions, not doctrine.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/router-posture-guard.sh"
[ -f "$HOOK" ] || { echo "SKIP: router-posture-guard.sh not found beside this test"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }
PROP_SRC="$DIR/../govern/ticket-proposal.sh"
COMMON_SRC="$DIR/../govern/lib/common.sh"
[ -f "$PROP_SRC" ] && [ -f "$COMMON_SRC" ] \
  || { echo "SKIP: templates/govern/ticket-proposal.sh or lib/common.sh not resolvable from this checkout"; exit 77; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset GOVERN_RUN GOVERN_PROPOSAL_GATE GOVERN_TICKET_ROUTE_GUARD 2>/dev/null || true

# ── build the fake scaffolded workspace ──────────────────────────────────────────────────────────
FAKE="$T/fakews"
mkdir -p "$FAKE/scripts/lib" "$FAKE/scripts/govern/lib" "$FAKE/queue"
cat > "$FAKE/scripts/lib/workspace.sh" <<'WS'
META_ROOT="${META_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export META_ROOT
WS
cp "$PROP_SRC" "$FAKE/scripts/govern/ticket-proposal.sh"
cp "$COMMON_SRC" "$FAKE/scripts/govern/lib/common.sh"
cp "$HOOK" "$FAKE/scripts/router-posture-guard.sh"
cat > "$FAKE/queue/tickets.md" <<'TICKETS'
## #501 no proposal yet
**Where:** somewhere
**Observed:** something
**Fix:** something
**Done when:** something
---
## #502 already has a proposal
**Proposed solution:** Edit foo.sh so the retry path backs off exponentially.
**Precision:** scoped
**Where:** somewhere
**Done when:** something
---
TICKETS

# A second root with the same hook but NO govern helper and no queue file: the unresolvable-install
# case, which must allow rather than block a dispatch.
BARE="$T/barews"
mkdir -p "$BARE/scripts"
cp "$HOOK" "$BARE/scripts/router-posture-guard.sh"

# dispatch <session_id> <prompt> [root] -> whatever the hook printed (empty = allow)
dispatch() {
  local sid="$1" prompt="$2" root="${3:-$FAKE}"
  python3 -c '
import json, sys
print(json.dumps({
  "tool_name": "Agent",
  "session_id": sys.argv[1],
  "transcript_path": "/tmp/driver-transcript.jsonl",
  "tool_input": {"subagent_type": "worker", "description": "dispatch", "prompt": sys.argv[2]},
}))
' "$sid" "$prompt" | bash "$root/scripts/router-posture-guard.sh" 2>/dev/null
}

denied() { case "$1" in *'"deny"'*'PROPOSAL GATE'*|*'PROPOSAL GATE'*'"deny"'*) return 0 ;; esac; return 1; }

echo "gate ON (shipped default), real workspace + real ticket-proposal.sh"

out="$(dispatch p1 "Resolve ticket #501 end to end and open a PR.")"
if denied "$out"; then ok "1. a worker dispatch on #501 (no proposed solution) is DENIED"
else bad "1. expected a PROPOSAL GATE deny for #501, got: ${out:0:160}"; fi
case "$out" in *'#501'*) ok "1b. the deny names the ticket it refused" ;;
  *) bad "1b. deny text should name #501, got: ${out:0:160}" ;; esac

out="$(dispatch p2 "Resolve ticket #502 end to end and open a PR.")"
if denied "$out"; then bad "2. #502 carries a proposal and must NOT be denied, got: ${out:0:160}"
else ok "2. a worker dispatch on #502 (has a proposed solution) is allowed"; fi

echo "kill switch"

out="$(GOVERN_PROPOSAL_GATE=0 dispatch p3 "Resolve ticket #501 end to end and open a PR.")"
if denied "$out"; then bad "3. GOVERN_PROPOSAL_GATE=0 must allow #501, got: ${out:0:160}"
else ok "3. GOVERN_PROPOSAL_GATE=0 allows the no-proposal dispatch"; fi

out="$(GOVERN_PROPOSAL_GATE=0 dispatch p4 "Resolve ticket #502 end to end and open a PR.")"
if denied "$out"; then bad "4. GOVERN_PROPOSAL_GATE=0 must allow #502 too, got: ${out:0:160}"
else ok "4. GOVERN_PROPOSAL_GATE=0 allows the with-proposal dispatch as well"; fi

echo "fail-open: the gate refuses only a ticket it can READ"

out="$(dispatch p5 "Sweep the hooks directory and summarise what each one denies.")"
if denied "$out"; then bad "5. a dispatch with no resolvable ticket number must allow, got: ${out:0:160}"
else ok "5. no resolvable ticket number in the call -> allow"; fi

out="$(dispatch p6 "Resolve ticket #501 end to end and open a PR." "$BARE")"
if denied "$out"; then bad "6. no ticket-proposal.sh / queue file reachable must allow, got: ${out:0:160}"
else ok "6. helper and queue file unresolvable -> allow, never a crash"; fi

echo "exit code contract: the hook itself always exits 0"
dispatch p7 "Resolve ticket #501 end to end and open a PR." >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "7. exits 0 on the deny path too (the decision travels in the JSON)" \
  || bad "7. exited $rc, must never be nonzero"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
