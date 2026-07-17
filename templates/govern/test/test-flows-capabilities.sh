#!/usr/bin/env bash
# Capability adapters (validations Phase 5): a flow declaring `Requires:` a workspace capability whose
# knob is UNSET can't be validated headlessly — the generic layer maps capability KEYS to env KNOB names
# (values only ever in workspace.sh) and `flows-file.sh` degrades such a flow to BLOCKED with a NAMED
# blocker (anti-pattern #15) instead of queuing a runnable-then-billable ticket. Unknown keys are ignored
# (never blocks a flow on a capability the mechanism can't reason about).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_NO_PUSH=1

M="$T/meta"; mkdir -p "$M/queue" "$M/.claude/shiploop/validation" "$M/governor" "$M/backend"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
export GOVERN_TICKETS_FILE="$M/queue/tickets.md"
export GOVERN_FLOWS_FILE="$M/.claude/shiploop/validation/flows.md"
export GOVERN_TICKET_SEQ_FILE="$M/governor/.ticket-seq"
: > "$GOVERN_TICKETS_FILE"
source "$DIR/../lib/common.sh"
FLOWS="$GOVERN_FLOWS_FILE"
fld() { govern::flow_field "$1" "$2" "$FLOWS"; }

# ── flow_cap_knob: the generic KEY → KNOB map (names only; values live in workspace.sh). ─────────────
assert_eq "$(govern::flow_cap_knob browser)"      "WSP_BROWSER_CMD"         "cap knob: browser → WSP_BROWSER_CMD"
assert_eq "$(govern::flow_cap_knob analytics)"    "WSP_ANALYTICS_QUERY_CMD" "cap knob: analytics → WSP_ANALYTICS_QUERY_CMD"
assert_eq "$(govern::flow_cap_knob test-account)" "TEST_USER_EMAIL"         "cap knob: test-account → TEST_USER_EMAIL"
assert_eq "$(govern::flow_cap_knob deploy)"       "GOVERN_DEPLOY_SWEEP_CMD" "cap knob: deploy → GOVERN_DEPLOY_SWEEP_CMD"
assert_eq "$(govern::flow_cap_knob nonsense)"     ""                        "cap knob: unknown key → empty (unmanaged)"

# ── Registry seed: one flow requiring browser+analytics, one requiring nothing, one with an unknown key.
cat > "$FLOWS" <<'EOF'
## ui.deploy
- **Kind:** correctness
- **Surface:** console UI → backend
- **Paths:** backend/src/deploy/**
- **Status:** UNTESTED
- **Requires:** browser, analytics

## api.close
- **Kind:** correctness
- **Surface:** API
- **Paths:** backend/src/close/**
- **Status:** UNTESTED

## weird.one
- **Kind:** correctness
- **Surface:** X
- **Paths:** backend/src/weird/**
- **Status:** UNTESTED
- **Requires:** telepathy browser
EOF

# ── flow_missing_caps: unset knobs are reported; unknown keys ignored; wired knobs drop out. ─────────
missing="$( unset WSP_BROWSER_CMD WSP_ANALYTICS_QUERY_CMD; govern::flow_missing_caps ui.deploy "$FLOWS" | sort | tr '\n' ' ' )"
assert_eq "$missing" "analytics browser " "missing caps: both unset knobs reported"

missing2="$( WSP_BROWSER_CMD='gstack' WSP_ANALYTICS_QUERY_CMD='ph-query' govern::flow_missing_caps ui.deploy "$FLOWS" | tr '\n' ' ' )"
assert_eq "$missing2" "" "missing caps: none when both knobs are wired"

none_req="$( govern::flow_missing_caps api.close "$FLOWS" | tr '\n' ' ' )"
assert_eq "$none_req" "" "missing caps: a flow with no Requires: reports nothing"

weird="$( unset WSP_BROWSER_CMD; govern::flow_missing_caps weird.one "$FLOWS" | tr '\n' ' ' )"
assert_eq "$weird" "browser " "missing caps: unknown key (telepathy) IGNORED, only the managed one reported"

# ── flow_missing_cap_blocker: a human-readable named blocker string (empty when nothing missing). ────
blk="$( unset WSP_BROWSER_CMD WSP_ANALYTICS_QUERY_CMD; govern::flow_missing_cap_blocker ui.deploy "$FLOWS" )"
assert_contains "$blk" "WSP_BROWSER_CMD unset"         "blocker string: names the missing browser knob"
assert_contains "$blk" "WSP_ANALYTICS_QUERY_CMD unset" "blocker string: names the missing analytics knob"
blk_none="$( WSP_BROWSER_CMD=x WSP_ANALYTICS_QUERY_CMD=y govern::flow_missing_cap_blocker ui.deploy "$FLOWS" )"
assert_eq "$blk_none" "" "blocker string: empty when every required knob is wired"

# ── flows-file.sh capability gate: a flow requiring an UNSET knob is degraded to BLOCKED + excluded. ─
out="$( unset WSP_BROWSER_CMD WSP_ANALYTICS_QUERY_CMD; "$DIR/../flows-file.sh" ui.deploy api.close 2>&1 )"
assert_contains "$out" "marked BLOCKED"    "flows-file: missing-capability flow reported as newly BLOCKED"
assert_contains "$out" "ui.deploy"         "flows-file: names the blocked flow"
assert_eq "$(fld ui.deploy Status)"  "BLOCKED" "flows-file: capability-missing flow degraded to BLOCKED in the registry"
assert_contains "$(fld ui.deploy Blocker)" "WSP_BROWSER_CMD unset" "flows-file: named blocker recorded on the flow"
assert_contains "$out" "api.close"         "flows-file: the no-Requires flow is still planned"

# Spot-check the gate FLIPS: with both knobs wired, ui.deploy is NOT blocked and gets planned. ───────
git -C "$M" checkout -q -- .claude/shiploop/validation/flows.md 2>/dev/null || git -C "$M" checkout -q HEAD -- .claude/shiploop/validation/flows.md 2>/dev/null || true
cat > "$FLOWS" <<'EOF'
## ui.deploy
- **Kind:** correctness
- **Surface:** console UI → backend
- **Paths:** backend/src/deploy/**
- **Status:** UNTESTED
- **Requires:** browser, analytics
EOF
out2="$( WSP_BROWSER_CMD='gstack browse' WSP_ANALYTICS_QUERY_CMD='ph' "$DIR/../flows-file.sh" ui.deploy 2>&1 )"
assert_eq "$(printf '%s' "$out2" | grep -c 'marked BLOCKED' || true)" "0" "flows-file: knobs wired → NOT blocked"
assert_contains "$out2" "ui.deploy" "flows-file: knobs wired → flow is planned"
assert_eq "$(fld ui.deploy Status)" "UNTESTED" "flows-file: knobs wired → Status left UNTESTED (not degraded)"

assert_done
