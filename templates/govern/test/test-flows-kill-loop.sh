#!/usr/bin/env bash
# Kill loop end-to-end (validations Phase 5): a measured-INEFFECTIVE flow the operator dispositions
# `kill` becomes a removal ticket that TOMBSTONES the flow on its PR. Covers: norm_disposition learns
# `kill`; file-ticket --flow-op remove emits the Flow-op field; ticket_flow_op parses it; flows_tombstone
# (Status→TOMBSTONED, history preserved); flows_mark_kill_pending + the Phase-3 sweep auto-withdrawal on
# a freshly-STALE flow; govern-bookkeep tombstones a Flow-op:remove ticket on resolve; and
# escalations-apply-answers acts on `kill` (marks kill-pending + files the removal ticket + closes the
# validation ticket).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"

# ── norm_disposition learns `kill` (matched via the leading-token anchor too). ───────────────────────
assert_eq "$(govern::norm_disposition 'kill')"                 "kill" "norm_disposition: bare kill → kill"
assert_eq "$(govern::norm_disposition 'kill it, delete the feature')" "kill" "norm_disposition: kill phrase → kill"
assert_eq "$(govern::norm_disposition "$(govern::disposition_lead_token 'kill _(delete it)_')")" "kill" "norm_disposition: leading-token kill → kill"
assert_eq "$(govern::norm_disposition 'accept current state')" "mitigated" "norm_disposition: kill token doesn't cannibalize mitigated"

# ── file-ticket --flow-op remove emits the Flow-op field (git-less path). ────────────────────────────
export GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq"
: > "$GOVERN_TICKETS_FILE"
rn="$(printf 'Where: remove feature\nDone when: gone\n' | "$DIR/../file-ticket.sh" --flow "opt.dead" --flow-op remove "KILL: remove opt.dead" Medium)"
rblk="$(govern::ticket_block "$rn" "$T/tickets.md")"
assert_contains "$rblk" "**Flow:** opt.dead"   "file-ticket --flow-op: Flow field emitted"
assert_contains "$rblk" "**Flow-op:** remove"  "file-ticket --flow-op remove: Flow-op field emitted"
# The default (validate) emits NO Flow-op field.
vn="$(printf 'body\n' | "$DIR/../file-ticket.sh" --flow "opt.live" "Validate opt.live" Low)"
vblk="$(govern::ticket_block "$vn" "$T/tickets.md")"
assert_eq "$(printf '%s' "$vblk" | grep -c 'Flow-op' || true)" "0" "file-ticket: default (validate) emits no Flow-op field"

# ── ticket_flow_op parses the leading-block field (remove vs default validate). ──────────────────────
assert_eq "$(govern::ticket_flow_op "$rn" "$T/tickets.md")" "remove"   "ticket_flow_op: remove ticket → remove"
assert_eq "$(govern::ticket_flow_op "$vn" "$T/tickets.md")" "validate" "ticket_flow_op: normal flow ticket → validate"

# ── flows_tombstone: Status→TOMBSTONED, history (Validated/Evidence) preserved, SupersededBy unset. ──
M="$T/m"; mkdir -p "$M/queue" "$M/.claude/shiploop/validation" "$M/backend"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
git init -q "$M/backend"; git -C "$M/backend" config user.email ci@test; git -C "$M/backend" config user.name ci
printf 'v1\n' > "$M/backend/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c1
SHA1="$(git -C "$M/backend" rev-parse HEAD)"
FL="$M/.claude/shiploop/validation/flows.md"
cat > "$FL" <<EOF
## opt.dead
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** optimizer A/B
- **Paths:** backend/**
- **Status:** INEFFECTIVE
- **Validated:** 2026-07-01 · backend@${SHA1:0:7} · PR https://x/8 (measured: +2.1%, n=140)
- **Env:** prod
- **Evidence:** .claude/shiploop/validation/evidence/opt.dead.md
EOF
git -C "$M" add -A; git -C "$M" commit -q -m seed

govern::flows_tombstone "opt.dead" "$M"
assert_eq "$(govern::flow_field opt.dead Status "$FL")" "TOMBSTONED" "flows_tombstone: Status → TOMBSTONED"
assert_contains "$(govern::flow_field opt.dead Validated "$FL")" "measured: +2.1%, n=140" "flows_tombstone: validated history preserved"
assert_contains "$(govern::flow_field opt.dead Evidence "$FL")" ".claude/shiploop/validation/evidence/opt.dead.md" "flows_tombstone: Evidence pointer preserved"
assert_eq "$(printf '%s' "$(govern::flow_field opt.dead SupersededBy "$FL")")" "" "flows_tombstone: SupersededBy NOT set (plain kill ≠ supersession)"

# ── flows_mark_kill_pending + sweep auto-withdrawal on a freshly-STALE flow. ─────────────────────────
cat > "$FL" <<EOF
## opt.dead
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** optimizer A/B
- **Paths:** backend/**
- **Status:** INEFFECTIVE
- **Validated:** 2026-07-01 · backend@${SHA1:0:7} · PR https://x/8
- **Env:** prod
EOF
git -C "$M" add -A; git -C "$M" commit -q -m reseed
govern::flows_mark_kill_pending "opt.dead" "$M"
assert_contains "$(govern::flow_field opt.dead Disposition "$FL")" "kill" "mark_kill_pending: sets a kill Disposition (list/health show it in flight)"
# A new commit moves backend past the validated SHA → the sweep degrades opt.dead to STALE and withdraws
# the pending kill (a stale negative must not be acted on).
printf 'v2\n' >> "$M/backend/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c2
GOVERN_FLOWS_SWEEP_META="$M" govern::flows_sweep_file "$FL"
assert_eq "$(govern::flow_field opt.dead Status "$FL")" "STALE" "sweep: freshly-changed path degrades the kill-pending flow to STALE"
assert_contains "$(govern::flow_field opt.dead Disposition "$FL")" "withdrawn" "sweep: pending kill auto-withdrawn on a stale negative"

# ── govern-bookkeep: a Flow-op:remove ticket TOMBSTONES its flow on resolve (not a fresh verdict). ──
cat > "$FL" <<EOF
## opt.dead
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** optimizer A/B
- **Paths:** backend/**
- **Status:** INEFFECTIVE
- **Validated:** 2026-07-01 · backend@${SHA1:0:7} · PR https://x/8
- **Env:** prod
- **Evidence:** .claude/shiploop/validation/evidence/opt.dead.md
EOF
cat > "$M/queue/tickets.md" <<'EOF'
## #12 — KILL: remove opt.dead (measured INEFFECTIVE)
**Severity:** Medium
**Flow:** opt.dead
**Flow-op:** remove

Remove the feature end-to-end and open a PR.
---
EOF
git -C "$M" add -A; git -C "$M" commit -q -m "seed removal ticket"
rep="$(jq -nc '{status:"resolved",pr:{repo:"backend",number:20,url:"https://github.com/acme/backend/pull/20"},newTickets:[],validation:{}}')"
printf '%s' "$rep" | GOVERN_TICKETS_FILE="$M/queue/tickets.md" GOVERN_GOVERNOR_DIR="$M/governor" \
  GOVERNOR_DIR="$M/governor" "$DIR/../govern-bookkeep.sh" 12 >/dev/null 2>&1
assert_eq "$(govern::flow_field opt.dead Status "$FL")" "TOMBSTONED" "bookkeep: Flow-op:remove ticket → flow TOMBSTONED on resolve"
assert_contains "$(govern::flow_field opt.dead Validated "$FL")" "PR https://x/8" "bookkeep tombstone: did NOT overwrite the verdict history with a fresh stamp"
assert_eq "$(grep -c '^## #12' "$M/queue/tickets.md" || true)" "0" "bookkeep: removal ticket block deleted on resolve"

# ── escalations-apply-answers: `kill` marks kill-pending + files a removal ticket + closes the ticket.
A="$T/apply"; mkdir -p "$A/queue" "$A/.claude/shiploop/validation" "$A/governor"
git init -q "$A"; git -C "$A" config user.email ci@test; git -C "$A" config user.name ci
AFL="$A/.claude/shiploop/validation/flows.md"
cat > "$AFL" <<'EOF'
## opt.dead
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** optimizer A/B
- **Paths:** backend/**
- **Status:** INEFFECTIVE
- **Validated:** 2026-07-01 · backend@abc1234 · PR https://x/8
- **Env:** prod
EOF
cat > "$A/queue/tickets.md" <<'EOF'
## #30 — VALIDATION: opt.dead effectiveness (gate failed)
**Severity:** Medium
**Flow:** opt.dead

Measured negative; operator to disposition.
---
EOF
cat > "$A/escalations.md" <<'EOF'
# Escalations

## Open

### #30 — validation gate FAILED — decide kill/ship-off/shelve/rework
- **Reason:** A/B measured a negative
- **Question:** kill / ship-off / shelve / rework?
- **Options:** kill / shelve / ship-default-off / rework
- **Answer:** it's worthless, delete it
- **Disposition:** kill
- **Make this a rule?:** _(operator)_

## Resolved
EOF
printf '# prefs\n' > "$A/governor/preferences.md"
git -C "$A" add -A; git -C "$A" commit -q -m seed

env GOVERN_TICKETS_FILE="$A/queue/tickets.md" GOVERN_TICKETS_PARKED_FILE="$A/queue/tickets-parked.md" \
    GOVERN_ESCALATIONS_FILE="$A/escalations.md" GOVERN_PREFERENCES_FILE="$A/governor/preferences.md" \
    GOVERN_PENDING_FILE="$A/pending.json" GOVERN_BOOKKEEP_LOCK="$A/bk.lock" \
    GOVERN_TICKET_SEQ_FILE="$A/governor/.ticket-seq" GOVERN_NO_PUSH=1 \
    bash "$DIR/../escalations-apply-answers.sh" >"$A/apply.out" 2>/dev/null || true

assert_contains "$(cat "$A/apply.out")" "killed 1" "apply-answers: summary reports 1 kill"
assert_contains "$(govern::flow_field opt.dead Disposition "$AFL")" "kill" "apply-answers: flow marked kill-pending"
# A removal ticket was filed (Flow-op: remove, Flow: opt.dead) and the original validation ticket closed.
assert_contains "$(cat "$A/queue/tickets.md")" "**Flow-op:** remove" "apply-answers: filed a removal ticket (Flow-op: remove)"
assert_contains "$(cat "$A/queue/tickets.md")" "**Flow:** opt.dead"  "apply-answers: removal ticket carries the flow id"
assert_eq "$(grep -c '^## #30' "$A/queue/tickets.md" || true)" "0" "apply-answers: original validation ticket closed"
assert_contains "$(awk '/^## Resolved/{f=1} f' "$A/escalations.md")" "#30" "apply-answers: escalation moved to Resolved"

assert_done
