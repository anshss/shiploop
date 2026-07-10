#!/usr/bin/env bash
# Durable validation runner (spec §4) — pending-result EMISSION. Proves: a terminal PASS record and
# a terminal FAIL record each get a pending-result.json emitted atomically (tmp+mv — no partial file
# ever observable, mirrors escalations-emit-pending.sh); emission is idempotent (a second scan of an
# already-emitted job is a no-op, never clobbers consumed:true); a job with no terminal record yet
# emits nothing.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/queue"
source "$DIR/../lib/common.sh"
source "$DIR/../lib/valpending.sh"
command -v jq >/dev/null 2>&1 || { echo "jq absent — skip"; exit 77; }

VDIR="$T/logs/govern/validations"

# ── job A: still running (no terminal verdict yet) ──
mkdir -p "$VDIR/val-deploy-example-1000"
cat > "$VDIR/val-deploy-example-1000/status.jsonl" <<'EOF'
{"ts":1000,"phase":"provisioning","deploys":["dep-1"],"verdict":null,"evidence":null}
{"ts":1010,"phase":"snapshot","deploys":["dep-1"],"verdict":null,"evidence":null}
EOF
govern::valpending_emit "$VDIR/val-deploy-example-1000" && emitted_a=yes || emitted_a=no
assert_eq "$emitted_a" "no" "a job with no terminal record yet emits nothing"
assert_eq "$([[ -f "$VDIR/val-deploy-example-1000/pending-result.json" ]] && echo yes || echo no)" "no" "no pending-result.json for a non-terminal job"

# ── job B: terminal PASS ──
mkdir -p "$VDIR/val-deploy-example-2000"
cat > "$VDIR/val-deploy-example-2000/status.jsonl" <<'EOF'
{"ts":2000,"phase":"provisioning","deploys":["dep-2"],"verdict":null,"evidence":null}
{"ts":2050,"phase":"terminal","deploys":["dep-2"],"verdict":"PASS","evidence":"logs/investigations/deploy-example/REPORT.md"}
EOF
govern::valpending_emit "$VDIR/val-deploy-example-2000" && emitted_b=yes || emitted_b=no
assert_eq "$emitted_b" "yes" "a terminal PASS record gets a pending-result.json emitted"
pending_b="$VDIR/val-deploy-example-2000/pending-result.json"
assert_eq "$([[ -f "$pending_b" ]] && echo yes || echo no)" "yes" "pending-result.json exists on disk for job B"
assert_eq "$(jq -r '.jobId' "$pending_b")" "val-deploy-example-2000" "pending entry carries the job id"
assert_eq "$(jq -r '.flowId' "$pending_b")" "deploy-example" "pending entry's flowId is parsed from the job id (strips val- prefix + trailing -ts)"
assert_eq "$(jq -r '.verdict' "$pending_b")" "PASS" "pending entry carries the terminal verdict"
assert_eq "$(jq -r '.evidence' "$pending_b")" "logs/investigations/deploy-example/REPORT.md" "pending entry carries the evidence pointer"
assert_eq "$(jq -r '.consumed' "$pending_b")" "false" "freshly emitted pending entry is NOT yet consumed"

# ── idempotency: re-scanning job B does not re-emit or clobber a since-consumed entry ──
jq '.consumed=true | .consumedBy="test"' "$pending_b" > "$pending_b.tmp" && mv "$pending_b.tmp" "$pending_b"
govern::valpending_emit "$VDIR/val-deploy-example-2000" && emitted_b2=yes || emitted_b2=no
assert_eq "$emitted_b2" "no" "re-scanning an already-emitted job is a no-op (rc 1)"
assert_eq "$(jq -r '.consumed' "$pending_b")" "true" "a second emit call never clobbers an already-consumed entry"

# ── job C: terminal FAIL ──
mkdir -p "$VDIR/val-comfyui.vastai-3000"
cat > "$VDIR/val-comfyui.vastai-3000/status.jsonl" <<'EOF'
{"ts":3000,"phase":"provisioning","deploys":["dep-3"],"verdict":null,"evidence":null}
{"ts":3070,"phase":"terminal","deploys":["dep-3"],"verdict":"FAIL","evidence":"logs/investigations/comfyui-vastai/REPORT.md"}
EOF
govern::valpending_emit "$VDIR/val-comfyui.vastai-3000" && emitted_c=yes || emitted_c=no
assert_eq "$emitted_c" "yes" "a terminal FAIL record gets a pending-result.json emitted"
pending_c="$VDIR/val-comfyui.vastai-3000/pending-result.json"
assert_eq "$(jq -r '.verdict' "$pending_c")" "FAIL" "FAIL job's pending entry carries verdict FAIL"
assert_eq "$(jq -r '.flowId' "$pending_c")" "comfyui.vastai" "FAIL job's flowId parses correctly (dotted id, numeric ts stripped)"
assert_eq "$(govern::valpending_flowid_from_jobid val-vastai2-4000)" "vastai2" "flowid parser: a flow id ending in a digit keeps it (only an ALL-digit trailing segment is stripped)"

# ── scan() walks the whole validations dir and reports only NEWLY emitted jobs ──
mkdir -p "$VDIR/val-untested-flow-9999"
cat > "$VDIR/val-untested-flow-9999/status.jsonl" <<'EOF'
{"ts":9000,"phase":"terminal","deploys":[],"verdict":"ABORT","evidence":null}
EOF
scanned="$(govern::valpending_scan "$VDIR" | sort)"
assert_contains "$scanned" "val-untested-flow-9999" "scan() emits the new ABORT job"
case "$scanned" in *val-deploy-example-2000*) got=yes;; *) got=no;; esac
assert_eq "$got" "no" "scan() does NOT re-report job B (already emitted earlier, even though re-consumed)"

assert_done
