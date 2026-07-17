#!/usr/bin/env bash
# Durable validation runner (spec §4) — pending-result APPLY. Proves: (1) PASS applies an
# evidence-stamp to the flow registry (via the SAME govern::flows_stamp_from_report primitive
# bookkeep uses for a ticket resolve); (2) FAIL files an escalation; (3) applying an already-consumed
# entry is a no-op; (4) the load-bearing case — TWO readers racing to apply the SAME terminal job
# under the bookkeep mutex apply it EXACTLY ONCE (one stamp, one escalation — never double).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

command -v jq >/dev/null 2>&1 || { echo "jq absent — skip"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "git absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/queue" "$T/.claude/shiploop/validation"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# Seed the flow registry with the flow this fixture job validates.
cat > "$T/.claude/shiploop/validation/flows.md" <<'EOF'
# Flow registry

## deploy.example
- **Kind:** correctness
- **Surface:** api
- **Paths:** alpha/src/**
- **Status:** UNTESTED
EOF

# Seed escalations.md with an Open section (govern::file_open_escalation appends under it).
cat > "$T/governor/escalations.md" <<'EOF'
# Escalations

## Open
EOF
printf '# Tickets\n' > "$T/queue/tickets.md"

export GOVERN_TICKETS_FILE="$T/queue/tickets.md" \
       GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
       GOVERN_FLOWS_FILE="$T/.claude/shiploop/validation/flows.md" \
       GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
       GOVERN_TICKET_SEQ_FILE="$T/governor/.ticket-seq" \
       GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"
source "$DIR/../lib/valpending.sh"

VDIR="$T/logs/govern/validations"

# ── (1) PASS: apply stamps the registry ──
mkdir -p "$VDIR/val-deploy.example-1000"
cat > "$VDIR/val-deploy.example-1000/status.jsonl" <<'EOF'
{"ts":1050,"phase":"terminal","deploys":["dep-1"],"verdict":"PASS","evidence":".claude/shiploop/validation/evidence/deploy.example.md"}
EOF
govern::valpending_emit "$VDIR/val-deploy.example-1000"
govern::valpending_apply_one "$VDIR/val-deploy.example-1000" reader-a && applied1=yes || applied1=no
assert_eq "$applied1" "yes" "apply_one applies a fresh PASS pending entry"
assert_eq "$(govern::flow_field deploy.example Status "$T/.claude/shiploop/validation/flows.md")" "PASS" "PASS apply stamps the flow registry Status field"
assert_eq "$(jq -r '.consumed' "$VDIR/val-deploy.example-1000/pending-result.json")" "true" "PASS apply marks the entry consumed"
assert_eq "$(jq -r '.consumedBy' "$VDIR/val-deploy.example-1000/pending-result.json")" "reader-a" "consumedBy records which reader applied it"

# Re-applying an already-consumed entry is a no-op.
govern::valpending_apply_one "$VDIR/val-deploy.example-1000" reader-b && applied1b=yes || applied1b=no
assert_eq "$applied1b" "no" "apply_one on an already-consumed entry is a no-op (rc 1)"

# ── (2) FAIL: apply files an escalation, never touches the registry ──
mkdir -p "$VDIR/val-deploy.example-2000"
cat > "$VDIR/val-deploy.example-2000/status.jsonl" <<'EOF'
{"ts":2050,"phase":"terminal","deploys":["dep-2"],"verdict":"FAIL","evidence":".claude/shiploop/validation/evidence/deploy.example-run2.md"}
EOF
govern::valpending_emit "$VDIR/val-deploy.example-2000"
govern::valpending_apply_one "$VDIR/val-deploy.example-2000" reader-a && applied2=yes || applied2=no
assert_eq "$applied2" "yes" "apply_one applies a fresh FAIL pending entry"
assert_contains "$(cat "$T/governor/escalations.md")" "val-deploy.example-2000" "FAIL apply files an escalation naming the job"
assert_contains "$(cat "$T/governor/escalations.md")" "Kind:** validation-job" "FAIL escalation is tagged Kind: validation-job"
assert_eq "$(jq -r '.consumed' "$VDIR/val-deploy.example-2000/pending-result.json")" "true" "FAIL apply marks the entry consumed"

# ── (3) the load-bearing race: TWO readers apply the SAME terminal job concurrently ──
mkdir -p "$VDIR/val-deploy.example-3000"
cat > "$VDIR/val-deploy.example-3000/status.jsonl" <<'EOF'
{"ts":3050,"phase":"terminal","deploys":["dep-3"],"verdict":"FAIL","evidence":".claude/shiploop/validation/evidence/deploy.example-run3.md"}
EOF
govern::valpending_emit "$VDIR/val-deploy.example-3000"
esc_before="$(grep -c '^### #' "$T/governor/escalations.md" || true)"

# Fire two independent apply passes at (as near as bash allows) the same time. Each is a FRESH
# subshell that re-sources common.sh/valpending.sh — mirroring two real readers (e.g. the
# supervisor's pass and a SessionStart hook) racing one terminal job, not two calls sharing one
# in-process lock state.
race_one() {
  local rc=0
  ( export GOVERN_TICKETS_FILE="$T/queue/tickets.md" \
           GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
           GOVERN_FLOWS_FILE="$T/.claude/shiploop/validation/flows.md" \
           GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
           GOVERN_TICKET_SEQ_FILE="$T/governor/.ticket-seq" \
           GOVERN_NO_PUSH=1 GOVERN_WS_ROOT="$T"
    source "$DIR/../lib/common.sh"
    source "$DIR/../lib/valpending.sh"
    govern::valpending_apply_one "$VDIR/val-deploy.example-3000" "$1"
  ) > "$T/race-$1.out" 2>&1 || rc=$?
  echo "$rc" > "$T/race-$1.rc"
}
race_one racer-x & pid_x=$!
race_one racer-y & pid_y=$!
wait "$pid_x" "$pid_y"

rc_x="$(cat "$T/race-racer-x.rc")"; rc_y="$(cat "$T/race-racer-y.rc")"
# Exactly one of the two racers applied it (rc 0); the other found it already consumed (rc 1).
one_zero_one_one="no"
if { [[ "$rc_x" == "0" && "$rc_y" == "1" ]] || [[ "$rc_x" == "1" && "$rc_y" == "0" ]]; }; then one_zero_one_one="yes"; fi
assert_eq "$one_zero_one_one" "yes" "exactly one racer applies the job; the other is a no-op (rc_x=$rc_x rc_y=$rc_y)"

consumed_by="$(jq -r '.consumedBy' "$VDIR/val-deploy.example-3000/pending-result.json")"
case "$consumed_by" in
  racer-x|racer-y) got=ok ;;
  *) got="unexpected:$consumed_by" ;;
esac
assert_eq "$got" "ok" "consumedBy records exactly one winning racer ($consumed_by)"

esc_after="$(grep -c '^### #' "$T/governor/escalations.md" || true)"
assert_eq "$((esc_after - esc_before))" "1" "the race files EXACTLY ONE new escalation (no double-file)"

assert_done
