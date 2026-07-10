#!/usr/bin/env bash
# /shiploop:flows command mechanics (validations Phase 4): flows-extract-merge.sh (staged vet gate,
# ADD/REFRESH/FLAG classification, Kind-change never auto-applied, verdict state never touched),
# flows-list.sh (grouping + BLOCKED blocker + MEASURING window), flows-file.sh (--all-* precondition
# refusal, resource-group batching into one ticket, in-flight guard, BLOCKED exclusion, dry-by-default
# vs --yes, --max-deploys truncation). Each gate is spot-checked to flip when its precondition flips.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_NO_PUSH=1

# Meta repo with a git tree so meta_root resolves; queue + validation live under it.
M="$T/meta"; mkdir -p "$M/queue" "$M/validation" "$M/backend"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
# GOVERN_WS_ROOT stays $T (mk_ws_stub's workspace.sh lives there); meta_root resolves to $M via the
# tickets path's git toplevel, and the scripts take the registry/tickets locations from the overrides.
export GOVERN_TICKETS_FILE="$M/queue/tickets.md"
export GOVERN_FLOWS_FILE="$M/validation/flows.md"
export GOVERN_TICKET_SEQ_FILE="$M/governor/.ticket-seq"
mkdir -p "$M/governor"
: > "$GOVERN_TICKETS_FILE"
source "$DIR/../lib/common.sh"
fld() { govern::flow_field "$1" "$2" "$GOVERN_FLOWS_FILE"; }

# ── registry seed: a PASS flow (deploy.a), a validated effectiveness flow (opt.b).
cat > "$GOVERN_FLOWS_FILE" <<'EOF'
## deploy.a
- **Kind:** correctness
- **Surface:** UI → backend
- **Paths:** backend/src/a/**
- **Status:** PASS
- **Validated:** 2026-07-01 · backend@abc1234 · PR https://x/1
- **Env:** prod
- **Evidence:** validation/evidence/deploy.a.md

## opt.b
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** optimizer A/B
- **Paths:** backend/src/b/**
- **Status:** PASS
- **Validated:** 2026-07-01 · backend@abc1234 · PR https://x/2
- **Env:** prod
- **Evidence:** validation/evidence/opt.b.md
EOF

# ── EXTRACT-MERGE ───────────────────────────────────────────────────────────
# Staged fragment: a NEW flow (deploy.c), a Paths REFRESH on deploy.a, and a Kind CHANGE on opt.b (flag).
cat > "$T/staged.md" <<'EOF'
## deploy.c
- **Kind:** correctness
- **Surface:** UI → backend new path
- **Paths:** backend/src/c/**
- **Status:** UNTESTED

## deploy.a
- **Kind:** correctness
- **Surface:** UI → backend (rewired)
- **Paths:** backend/src/a/** backend/src/a2/**

## opt.b
- **Kind:** correctness
- **Paths:** backend/src/b/**
EOF

# Dry run: prints classification, writes nothing.
before="$(cat "$GOVERN_FLOWS_FILE")"
out="$("$DIR/../flows-extract-merge.sh" "$T/staged.md" 2>&1)"
assert_contains "$out" "+ deploy.c" "extract dry: NEW flow shown as ADD"
assert_contains "$out" "~ deploy.a" "extract dry: existing flow shown as REFRESH"
assert_contains "$out" "! opt.b" "extract dry: Kind change shown as FLAGGED"
assert_contains "$out" "DRY RUN" "extract dry: announces nothing written"
assert_eq "$(cat "$GOVERN_FLOWS_FILE")" "$before" "extract dry: registry unchanged"

# Approve: ADD + REFRESH applied; FLAG (opt.b Kind) NOT applied; verdict state untouched.
"$DIR/../flows-extract-merge.sh" "$T/staged.md" --approve >/dev/null 2>&1
assert_eq "$(govern::flow_exists deploy.c "$GOVERN_FLOWS_FILE" && echo yes || echo no)" "yes" "extract approve: new flow appended"
assert_contains "$(fld deploy.a Paths)" "backend/src/a2/**" "extract approve: Paths refreshed on existing flow"
assert_contains "$(fld deploy.a Surface)" "rewired" "extract approve: Surface refreshed"
assert_eq "$(fld deploy.a Status)" "PASS" "extract approve: Status NEVER touched by re-extraction"
assert_contains "$(fld deploy.a Validated)" "abc1234" "extract approve: Validated NEVER touched"
assert_eq "$(fld opt.b Kind)" "effectiveness" "extract approve: FLAGGED Kind change NOT auto-applied"

# ── LIST ────────────────────────────────────────────────────────────────────
# Add a BLOCKED + a MEASURING flow so grouping shows blocker + window.
cat >> "$GOVERN_FLOWS_FILE" <<'EOF'

## api.blocked
- **Kind:** correctness
- **Surface:** UI → thirdparty
- **Paths:** backend/src/x/**
- **Status:** BLOCKED
- **Blocker:** no test credential for the third-party API

## opt.measuring
- **Kind:** effectiveness
- **Gate:** reduction >= 10%, N >= 100 sessions · source: analytics:e/2
- **Surface:** optimizer A/B v2
- **Paths:** backend/src/m/**
- **Status:** MEASURING
- **Validated:** 2026-07-02 · backend@abc1234 · PR https://x/9
- **Env:** prod
- **Evidence:** validation/evidence/opt.measuring.md
EOF
list_out="$("$DIR/../flows-list.sh" 2>&1)"
assert_contains "$list_out" "BLOCKED (1)" "list: groups by status"
assert_contains "$list_out" "blocker: no test credential" "list: BLOCKED shows its named blocker"
assert_contains "$list_out" "window:  reduction >= 10%, N >= 100" "list: MEASURING shows its gate/window"

# ── FILE ────────────────────────────────────────────────────────────────────
# Precondition: --all-untested refuses without GOVERN_DEPLOY_SWEEP_CMD.
if ( unset GOVERN_DEPLOY_SWEEP_CMD; "$DIR/../flows-file.sh" --all-untested >/dev/null 2>&1 ); then rc=0; else rc=$?; fi
assert_eq "$rc" "2" "file: --all-* refuses (exit 2) without GOVERN_DEPLOY_SWEEP_CMD"
# Spot-check the gate flips: with the sweep cmd wired, --all-untested proceeds (dry).
out="$(GOVERN_DEPLOY_SWEEP_CMD='echo sweep' "$DIR/../flows-file.sh" --all-untested 2>&1)"
assert_contains "$out" "DRY RUN" "file: --all-* proceeds once GOVERN_DEPLOY_SWEEP_CMD is wired"
assert_contains "$out" "deploy.c" "file: --all-untested selects the UNTESTED flow"

# BLOCKED excluded from an explicit selection.
out="$("$DIR/../flows-file.sh" api.blocked deploy.c 2>&1)"
assert_contains "$out" "excluded (BLOCKED" "file: BLOCKED flow excluded"
assert_contains "$out" "deploy.c" "file: non-blocked flow still planned"

# Resource-group batching: two flows sharing a group → ONE ticket (comma-list Flow:).
cat >> "$GOVERN_FLOWS_FILE" <<'EOF'

## deploy.vastai
- **Kind:** correctness
- **Surface:** UI → mjolnir → vastai
- **Paths:** backend/src/vastai/**
- **Status:** UNTESTED
- **Resource-group:** vastai-box

## comfyui.vastai
- **Kind:** correctness
- **Surface:** UI → mjolnir → vastai comfyui
- **Paths:** backend/src/vastai/comfyui/**
- **Status:** UNTESTED
- **Resource-group:** vastai-box
EOF
out="$("$DIR/../flows-file.sh" deploy.vastai comfyui.vastai 2>&1)"
assert_contains "$out" "1 validation ticket(s)" "file: resource-group batches 2 flows into 1 ticket"
assert_contains "$out" "vastai-box" "file: group labelled by its Resource-group key"
assert_contains "$out" "2 flow(s): deploy.vastai comfyui.vastai" "file: both grouped flows in one plan row"

# --yes actually files ONE grouped ticket carrying both ids as a comma-list Flow: field.
"$DIR/../flows-file.sh" deploy.vastai comfyui.vastai --yes >/dev/null 2>&1
assert_contains "$(cat "$GOVERN_TICKETS_FILE")" "**Flow:** deploy.vastai,comfyui.vastai" "file --yes: grouped ticket carries the comma-list Flow field"
nfiled="$(grep -c '^## #' "$GOVERN_TICKETS_FILE" || true)"
assert_eq "$nfiled" "1" "file --yes: exactly ONE ticket filed for the 2-flow group"

# In-flight guard: re-filing the now-in-flight flows is skipped.
out="$("$DIR/../flows-file.sh" deploy.vastai 2>&1)"
assert_contains "$out" "already an open Flow: ticket" "file: in-flight guard skips a flow with an open Flow: ticket"

# --max-deploys truncation: 2 solo groups, cap at 1 → one deferred.
cat >> "$GOVERN_FLOWS_FILE" <<'EOF'

## solo.one
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/one/**
- **Status:** UNTESTED

## solo.two
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/two/**
- **Status:** UNTESTED
EOF
out="$("$DIR/../flows-file.sh" solo.one solo.two --max-deploys 1 2>&1)"
assert_contains "$out" "max-deploys 1 reached" "file: --max-deploys truncates the plan"

assert_done
