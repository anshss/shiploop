#!/usr/bin/env bash
# The dispatch preparer in router-posture-guard.sh: an Agent(subagent_type: "worker") call with no
# fresh packet gets one cut by the hook (pre-dispatch gates, then dispatch-packet.sh) and is allowed;
# a skip/refuse verdict is the only deny and carries the verdict line; every allowed spawn returns
# the tickets' Proposed solution and Done when blocks plus the packet path as additionalContext; the
# model the call passed is recorded in the packet's Model line, never denied.
#
# The hook, the real dispatch.sh (for --print-blocks) and the real common.sh run in a fake scaffolded
# root; pre-dispatch-check.sh and dispatch-packet.sh are stubs so the test controls the verdict and
# can see exactly when a packet was cut.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HOOK="${GOVERN_HOOKS_DIR:-}/router-posture-guard.sh"
[[ -f "$HOOK" && -f "$DIR/../dispatch.sh" ]] || { echo "SKIP: router-posture-guard.sh or dispatch.sh not found"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset GOVERN_RUN GOVERN_TICKET_ROUTE_GUARD GOVERN_DISPATCH_FRESH_HOURS 2>/dev/null || true
export GOVERN_DISPATCH_GATE=1   # assert.sh pins it off suite-wide; this is the test that opts in
export GOVERN_PROPOSAL_GATE=0   # the proposal gate has its own test
export GOVERN_WORKER_FANOUT_NUDGE=0   # the fan-out advisory shares the output object; not under test here

FAKE="$T/fakews"
mk_ws_stub "$FAKE"
mkdir -p "$FAKE/scripts/govern/lib" "$FAKE/queue" "$T/wt"
cp "$HOOK" "$FAKE/scripts/router-posture-guard.sh"
cp "$DIR/../lib/common.sh" "$FAKE/scripts/govern/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$FAKE/scripts/govern/lib/"
cp "$DIR/../dispatch.sh" "$FAKE/scripts/govern/dispatch.sh"
cat > "$FAKE/queue/tickets.md" <<'TIX'
# Tickets

## #7 tighten the retry ladder

**Done when:** the ladder stops at three.

**Proposed solution:** cap it at three.

**Precision:** stated

---

## #8 log every retry

**Done when:** a log line appears per retry.

**Proposed solution:** add one log line per retry.

**Precision:** stated
TIX
cat > "$FAKE/scripts/govern/pre-dispatch-check.sh" <<EOF2
#!/usr/bin/env bash
if [ -f "$FAKE/verdict" ]; then cat "$FAKE/verdict"; exit 0; fi
case "\$1" in *,*) printf '#7: proceed\n#8: proceed\nplan: %s\n' "\$1" ;; *) echo proceed ;; esac
EOF2
cat > "$FAKE/scripts/govern/dispatch-packet.sh" <<EOF2
#!/usr/bin/env bash
csv="\$1"; model="\$3"; primary="\${csv%%,*}"
mkdir -p "$T/wt/t\$primary"
p="$T/wt/t\$primary/.dispatch-packet.md"
refs="\$(printf '%s' "\$csv" | sed 's/\([0-9][0-9]*\)/#\1/g; s/,/, /g')"
{ printf '<!-- GOVERN:PACKET-CREATED %s -->\n# Dispatch packet for %s\n\nWorktree: x\nModel: %s\n' "\$(date +%s)" "\$refs" "\$model"; } > "\$p"
echo "\$csv \$model" >> "$FAKE/cuts.log"
echo "\$p"; echo "Resolve \$refs. Read your packet at \$p first and follow it."
EOF2

mk_packet() { # <file> <heading-refs> <model-line> <created-epoch>
  mkdir -p "$(dirname "$1")"
  printf '<!-- GOVERN:PACKET-CREATED %s -->\n# Dispatch packet for %s\n\nWorktree: x\nModel: %s\n' "$4" "$2" "$3" > "$1"
}
NOW="$(date +%s)"
cuts() { [[ -f "$FAKE/cuts.log" ]] && wc -l < "$FAKE/cuts.log" | tr -d ' ' || echo 0; }

spawn() { # <prompt> [model] -> whatever the hook printed (empty = plain allow)
  python3 -c '
import json, sys
ti = {"subagent_type": "worker", "description": "dispatch", "prompt": sys.argv[1]}
if len(sys.argv) > 2 and sys.argv[2]:
    ti["model"] = sys.argv[2]
print(json.dumps({"tool_name": "Agent", "session_id": "gate-test", "transcript_path": "/tmp/driver.jsonl", "tool_input": ti}))
' "$1" "${2:-}" | bash "$FAKE/scripts/router-posture-guard.sh" 2>/dev/null
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$1" 2>/dev/null || echo "?"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$1" 2>/dev/null; }
PK7="$T/wt/t7/.dispatch-packet.md"

# 1. no packet named: one is cut, the spawn is allowed, additionalContext carries both blocks + path
out="$(spawn "Resolve #7. Do the work in t7 now.")"
assert_eq "$(decision "$out")" "allow" "1. a spawn with no packet is allowed"
assert_eq "$(cuts)" "1" "1. the hook cut one packet"
assert_contains "$(ctx "$out")" "cap it at three." "1. additionalContext carries the Proposed solution"
assert_contains "$(ctx "$out")" "the ladder stops at three." "1. additionalContext carries the Done when block"
assert_contains "$(ctx "$out")" "$PK7" "1. additionalContext names the packet path"
assert_contains "$(cat "$PK7")" "Model: sonnet" "1. no model param is recorded as sonnet"

# 2. a fresh packet naming N is reused, not re-cut; its Model line follows the call
mk_packet "$PK7" "#7" "sonnet" "$NOW"
before="$(cuts)"
out="$(spawn "Resolve #7. Read your packet at $PK7 first and follow it." opus)"
assert_eq "$(decision "$out")" "allow" "2. a fresh packet with a different model is allowed, never denied on model"
assert_eq "$(cuts)" "$before" "2. a fresh packet is not re-cut (negative control for 3)"
assert_contains "$(cat "$PK7")" "Model: opus" "2. the model the call passed is recorded in the packet"
assert_contains "$(ctx "$out")" "cap it at three." "2. a reused packet still returns the blocks"

# 3. a stale packet is re-cut
mk_packet "$PK7" "#7" "sonnet" "$(( NOW - 7 * 3600 ))"
before="$(cuts)"
out="$(spawn "Resolve #7. Read your packet at $PK7 first and follow it.")"
assert_eq "$(decision "$out")" "allow" "3. a stale packet does not deny"
assert_eq "$(cuts)" "$((before + 1))" "3. a stale packet (7h, limit 6h) is re-cut"
before="$(cuts)"
mk_packet "$PK7" "#7" "sonnet" "$(( NOW - 7 * 3600 ))"
spawn "Resolve #7. Read your packet at $PK7 first and follow it." >/dev/null
GOVERN_DISPATCH_FRESH_HOURS=8 spawn "Resolve #7. Read your packet at $PK7 first and follow it." >/dev/null
assert_eq "$(cuts)" "$((before + 1))" "3. under GOVERN_DISPATCH_FRESH_HOURS=8 the same packet is reused"

# 4. a packet that does not list every ticket is re-cut as a group
mk_packet "$PK7" "#7" "sonnet" "$NOW"
before="$(cuts)"
out="$(spawn "Resolve #7, #8. Read your packet at $PK7 first and follow it.")"
assert_eq "$(cuts)" "$((before + 1))" "4. a packet missing #8 is re-cut"
assert_contains "$(ctx "$out")" "add one log line per retry." "4. the group's second ticket block is returned"

# 5. a model passed with no packet is recorded in the cut packet
rm -f "$PK7"
spawn "Resolve #7. Do the work." opus >/dev/null
assert_contains "$(cat "$PK7")" "Model: opus" "5. the cut packet records the call's model"
rm -f "$PK7"
spawn "Resolve #7. Do the work." claude-haiku-5-5 >/dev/null
assert_contains "$(cat "$PK7")" "Model: haiku" "5. a full model id is recorded as its alias"

# 6. a gate refusal is the one deny, and carries the verdict line; nothing is cut
printf 'skip: depends on unresolved #3 (still in tickets.md): no worker burned\n' > "$FAKE/verdict"
rm -f "$PK7"; before="$(cuts)"
out="$(spawn "Resolve #7. Do the work.")"
assert_eq "$(decision "$out")" "deny" "6. a skip verdict denies the spawn"
assert_contains "$out" "depends on unresolved #3" "6. the deny carries the verdict line"
assert_eq "$(cuts)" "$before" "6. no packet is cut after a refusal"
rm -f "$FAKE/verdict"
out="$(spawn "Resolve #7. Do the work.")"
assert_eq "$(decision "$out")" "allow" "6. the same spawn is allowed once the gates pass (negative control)"

# 7. kill switch: no packet cut, no context
rm -f "$PK7"; before="$(cuts)"
out="$(GOVERN_DISPATCH_GATE=0 spawn "Resolve #7. Do the work.")"
assert_eq "$out" "" "7. GOVERN_DISPATCH_GATE=0 is a no-op: plain allow"
assert_eq "$(cuts)" "$before" "7. nothing is cut with the switch off"

assert_done
