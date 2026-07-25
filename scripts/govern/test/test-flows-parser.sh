#!/usr/bin/env bash
# Flow-registry parser (validations Phase 1): flow_ids / flow_block / flow_field / flow_set_field /
# flow_validate. Proves the net-new block grammar (anchor `^## <id>`, DISJOINT from the ticket parser's
# `^## #<digits>`), comment-stripping on field reads, unknown-field preservation on rewrite, and
# grammar validation.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
source "$DIR/../lib/common.sh"

F="$T/flows.md"
cat > "$F" <<'EOF'
# Flow registry

Some human preamble under a normal `## Heading` that is NOT a flow id.

## deploy-gpu.vastai
- **Kind:** correctness
- **Surface:** console UI → orchestrator → mjolnir → Vast.ai
- **Paths:** mjolnir/providers/vastai/** console/app/deploy/**
- **Status:** PASS
- **Validated:** 2026-07-06 · mjolnir@a1b2c3d console@9c8d7e6 · PR https://github.com/x/mjolnir/pull/301
- **Env:** prod <!-- last measured on the prod box -->
- **Evidence:** .claude/shiploop/validation/evidence/deploy-gpu.vastai.md
- **X-Custom-Unknown:** keep-me-verbatim

## optimizer.ab-test
- **Kind:** effectiveness
- **Surface:** optimizer A/B harness vs control
- **Gate:** token-cost reduction >=10%, N>=100 · source: analytics:experiment/opt-v2
- **Paths:** src/optimizer/**
- **Status:** UNTESTED
EOF

# ── flow_ids: exactly the two valid ids, in order; the prose `## Heading` is NOT an id.
ids="$(govern::flow_ids "$F")"
assert_eq "$ids" "$(printf 'deploy-gpu.vastai\noptimizer.ab-test')" "flow_ids: only valid dot-kebab ids, in order"

# ── flow_block: bounded by the next `## ` heading; the second flow does not leak in.
blk="$(govern::flow_block deploy-gpu.vastai "$F")"
assert_contains "$blk" "## deploy-gpu.vastai" "flow_block: heading present"
assert_contains "$blk" "X-Custom-Unknown" "flow_block: whole block returned"
if grep -q "optimizer.ab-test" <<<"$blk"; then leak=1; else leak=0; fi
assert_eq "$leak" "0" "flow_block: bounded — next flow does not leak in"

# ── flow_field: value extraction + inline HTML-comment stripping.
assert_eq "$(govern::flow_field deploy-gpu.vastai Kind "$F")" "correctness" "flow_field: Kind"
assert_eq "$(govern::flow_field deploy-gpu.vastai Status "$F")" "PASS" "flow_field: Status"
assert_eq "$(govern::flow_field deploy-gpu.vastai Env "$F")" "prod" "flow_field: inline comment stripped from value"
assert_eq "$(govern::flow_field deploy-gpu.vastai Paths "$F")" "mjolnir/providers/vastai/** console/app/deploy/**" "flow_field: multi-glob Paths"
# A field named as a prefix of another (Env vs a hypothetical Env-required) must anchor on the colon.
assert_eq "$(govern::flow_field optimizer.ab-test Gate "$F")" "token-cost reduction >=10%, N>=100 · source: analytics:experiment/opt-v2" "flow_field: Gate with embedded colons"

# ── flow_set_field: REPLACE an existing field; every other line (incl. the unknown field) survives.
govern::flow_set_field deploy-gpu.vastai Status STALE "$F"
assert_eq "$(govern::flow_field deploy-gpu.vastai Status "$F")" "STALE" "flow_set_field: replaced Status"
assert_contains "$(cat "$F")" "X-Custom-Unknown:** keep-me-verbatim" "flow_set_field: unknown field preserved verbatim"
assert_contains "$(cat "$F")" "Kind:** correctness" "flow_set_field: sibling fields untouched"
# The OTHER flow must be entirely untouched.
assert_eq "$(govern::flow_field optimizer.ab-test Status "$F")" "UNTESTED" "flow_set_field: other flow untouched"

# ── flow_set_field: INSERT a new field (Disposition) — appended after the block's last field line.
govern::flow_set_field deploy-gpu.vastai Disposition "kill -> removal PR pending" "$F"
assert_eq "$(govern::flow_field deploy-gpu.vastai Disposition "$F")" "kill -> removal PR pending" "flow_set_field: inserted new field"
# Inserted BEFORE the next `## ` heading (still inside the deploy block, not bleeding into optimizer).
inblock="$(govern::flow_block deploy-gpu.vastai "$F")"
assert_contains "$inblock" "Disposition:** kill" "flow_set_field: insert stays within the target block"

# ── flow_validate: a well-formed validated correctness flow passes; a broken one reports every gap.
if govern::flow_validate optimizer.ab-test "$F" >/dev/null; then vok=0; else vok=1; fi
assert_eq "$vok" "0" "flow_validate: UNTESTED effectiveness flow with a Gate is well-formed"

cat >> "$F" <<'EOF'

## broken.flow
- **Kind:** effectiveness
- **Status:** PASS
EOF
probs="$(govern::flow_validate broken.flow "$F" 2>&1 || true)"
assert_contains "$probs" "missing required field Surface" "flow_validate: flags missing Surface"
assert_contains "$probs" "missing required field Paths" "flow_validate: flags missing Paths"
assert_contains "$probs" "Kind=effectiveness requires a Gate" "flow_validate: flags missing Gate"
assert_contains "$probs" "Status=PASS requires a Validated" "flow_validate: flags missing Validated on a validated status"

# ── The ticket parser and the flow parser do NOT collide: a `## #12` heading is not a flow id.
cat >> "$F" <<'EOF'

## #12
- not a flow
EOF
if govern::flow_ids "$F" | grep -qx "#12"; then coll=1; else coll=0; fi
assert_eq "$coll" "0" "flow_ids: a `## #12` ticket-style heading is never parsed as a flow id"

# ── Regression: a `## <id>` heading sitting inside a multi-line <!-- --> comment block (e.g. a
# scaffolded seed example kept as commented-out documentation) is decoration, not a real flow — the
# block scanner must never see it. A real flow declared AFTER the comment block must still parse fine
# (the comment-strip must not leak state and swallow the rest of the file).
CF="$T/flows-comments.md"
cat > "$CF" <<'EOF'
# Flow registry

<!--
Example (not a real flow, kept for documentation):

## deploy.example
- **Kind:** correctness
- **Surface:** UI → api
- **Paths:** backend/**
- **Status:** UNTESTED
-->

## real.flow
- **Kind:** correctness
- **Surface:** UI → api
- **Paths:** src/real/**
- **Status:** UNTESTED
EOF
cids="$(govern::flow_ids "$CF")"
assert_eq "$cids" "real.flow" "flow_ids: a commented-out `## <id>` heading is skipped; the real flow after it still parses"
if govern::flow_exists deploy.example "$CF"; then existed=1; else existed=0; fi
assert_eq "$existed" "0" "flow_exists: a commented-out example never registers as present"
cblk="$(govern::flow_block deploy.example "$CF")"
assert_eq "$cblk" "" "flow_block: a commented-out heading returns an empty block"

assert_done
