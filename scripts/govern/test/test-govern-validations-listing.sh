#!/usr/bin/env bash
# Durable validation runner (spec §4) — the live-jobs surface (`govern-validations.sh` / reader 3/3
# "on demand"). Proves the listing shows phase + heartbeat age for a still-running job, shows the
# verdict (not a stale heartbeat) for a terminal job, and that running the CLI end-to-end also adopts
# (applies + consumes) any pending result on the way, per its default on-demand-apply behavior.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
CLI="$DIR/../govern-validations.sh"

command -v jq >/dev/null 2>&1 || { echo "jq absent — skip"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "git absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/queue" "$T/.claude/shiploop/validation"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/.claude/shiploop/validation/flows.md" <<'EOF'
# Flow registry

## deploy.example
- **Kind:** correctness
- **Surface:** api
- **Paths:** alpha/src/**
- **Status:** UNTESTED
EOF
printf '# Escalations\n\n## Open\n' > "$T/governor/escalations.md"
printf '# Tickets\n' > "$T/queue/tickets.md"

VDIR="$T/logs/govern/validations"

# ── job A: still running — phase + fresh heartbeat, no verdict ──
mkdir -p "$VDIR/val-comfyui.vastai-1000"
cat > "$VDIR/val-comfyui.vastai-1000/status.jsonl" <<'EOF'
{"ts":1000,"phase":"provisioning","deploys":["dep-a1","dep-a2"],"verdict":null,"evidence":null}
{"ts":1030,"phase":"snapshotting","deploys":["dep-a1","dep-a2"],"verdict":null,"evidence":null}
EOF
touch "$VDIR/val-comfyui.vastai-1000/heartbeat"

# ── job B: terminal PASS ──
mkdir -p "$VDIR/val-deploy.example-2000"
cat > "$VDIR/val-deploy.example-2000/status.jsonl" <<'EOF'
{"ts":2000,"phase":"provisioning","deploys":["dep-b1"],"verdict":null,"evidence":null}
{"ts":2050,"phase":"terminal","deploys":["dep-b1"],"verdict":"PASS","evidence":".claude/shiploop/validation/evidence/deploy.example.md"}
EOF

export GOVERN_TICKETS_FILE="$T/queue/tickets.md" \
       GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
       GOVERN_FLOWS_FILE="$T/.claude/shiploop/validation/flows.md" \
       GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
       GOVERN_TICKET_SEQ_FILE="$T/governor/.ticket-seq" \
       GOVERN_WS_ROOT="$T" GOVERN_NO_PUSH=1

out="$(bash "$CLI")"
assert_contains "$out" "val-comfyui.vastai-1000" "listing includes the live job"
assert_contains "$out" "phase=snapshotting" "live job shows its CURRENT phase (last status.jsonl line, not the first)"
assert_contains "$out" "heartbeat=" "live job shows a heartbeat age"
assert_contains "$out" "deploys=dep-a1,dep-a2" "live job lists its deploy-ids"

assert_contains "$out" "val-deploy.example-2000" "listing includes the terminal job"
assert_contains "$out" "TERMINAL=PASS" "terminal job shows its verdict instead of a heartbeat age"

# The default (apply-on-list) pass already adopted job B's PASS this run.
assert_contains "$(cat "$T/.claude/shiploop/validation/flows.md")" "**Status:** PASS" \
  "running the CLI end-to-end also adopted (stamped) the terminal PASS job on the way"
assert_eq "$(jq -r '.consumed' "$VDIR/val-deploy.example-2000/pending-result.json")" "true" "the adopted job's pending entry is marked consumed"

# ── --no-apply: read-only peek never adopts ──
mkdir -p "$VDIR/val-deploy.example-3000"
cat > "$VDIR/val-deploy.example-3000/status.jsonl" <<'EOF'
{"ts":3050,"phase":"terminal","deploys":[],"verdict":"FAIL","evidence":null}
EOF
out2="$(bash "$CLI" --no-apply)"
assert_contains "$out2" "val-deploy.example-3000" "--no-apply still LISTS a fresh terminal job"
assert_eq "$([[ -f "$VDIR/val-deploy.example-3000/pending-result.json" ]] && echo yes || echo no)" "no" "--no-apply never emits/adopts a pending entry"

assert_done
