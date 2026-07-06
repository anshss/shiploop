#!/usr/bin/env bash
# Flow-registry lint matrix (validations Phase 1) — one assertion per row of the design's lint table:
#   logs/-ref → FAIL · dangling Evidence ref → FAIL · zero-match glob → FAIL + auto-degrade STALE ·
#   asset size → WARN (no fail) · PII/secret → FAIL, suppressible with a `<!-- lint:allow -->` marker.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 || { echo "git absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
source "$DIR/../lib/common.sh"

# Meta-root git repo with a real tracked file (so globs can resolve) + a real evidence summary.
M="$T/meta"; mkdir -p "$M/src/real" "$M/validation/evidence"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
printf 'keep\n' > "$M/src/real/keep.txt"
printf '# evidence\nverdict: PASS\n' > "$M/validation/evidence/deploy.example.md"
git -C "$M" add -A; git -C "$M" commit -q -m init

F="$M/validation/flows.md"
run_lint() { govern::flows_lint "$M" 2>"$T/err"; echo $?; }   # prints rc; stderr → $T/err

# ── Clean baseline: a validated flow with a real glob + present evidence + no logs/PII → rc 0.
cat > "$F" <<'EOF'
## deploy.example
- **Kind:** correctness
- **Surface:** UI → api
- **Paths:** src/real/**
- **Status:** PASS
- **Validated:** 2026-07-06 · meta@abc123 · PR https://github.com/x/y/pull/1
- **Env:** prod
- **Evidence:** validation/evidence/deploy.example.md
EOF
assert_eq "$(run_lint)" "0" "clean registry lints cleanly (rc 0)"

# ── Row: a logs/ path reference in the registry → FAIL.
cp "$F" "$F.clean"
printf -- '- **Evidence:** logs/investigations/x/report.json\n' >> "$F"
assert_eq "$(run_lint)" "1" "logs/ evidence reference → FAIL (rc 1)"
assert_contains "$(cat "$T/err")" "logs/" "logs/ FAIL message names the path"
cp "$F.clean" "$F"

# ── Row: a dangling Evidence ref (no such file, not a URL) → FAIL.
govern::flow_set_field deploy.example Evidence "validation/evidence/ghost.md" "$F"
assert_eq "$(run_lint)" "1" "dangling Evidence ref → FAIL (rc 1)"
assert_contains "$(cat "$T/err")" "dangles" "dangling FAIL message says 'dangles'"
cp "$F.clean" "$F"

# ── Row: a zero-match glob → FAIL + the flow auto-degrades to STALE in place.
govern::flow_set_field deploy.example Paths "src/ghost/**" "$F"
assert_eq "$(run_lint)" "1" "zero-match glob → FAIL (rc 1)"
assert_contains "$(cat "$T/err")" "0 tracked files" "zero-glob FAIL message"
assert_eq "$(govern::flow_field deploy.example Status "$F")" "STALE" "zero-glob auto-degrades Status→STALE in place"
cp "$F.clean" "$F"

# ── Row: an https URL Evidence ref is accepted (object-storage opt-in) — not a dangle.
govern::flow_set_field deploy.example Evidence "https://storage.example.com/deploy.example.md" "$F"
assert_eq "$(run_lint)" "0" "https Evidence URL is accepted (rc 0)"
cp "$F.clean" "$F"

# ── Row: oversized asset → WARN only (rc stays 0).
mkdir -p "$M/validation/evidence/assets/deploy.example"
dd if=/dev/zero of="$M/validation/evidence/assets/deploy.example/big.bin" bs=1024 count=320 >/dev/null 2>&1
assert_eq "$(run_lint)" "0" "oversized asset is a WARN, not a FAIL (rc 0)"
assert_contains "$(cat "$T/err")" "300 KB" "asset-size WARN message"
rm -rf "$M/validation/evidence/assets"

# ── Row: PII in a tier-2 evidence file → FAIL; a lint:allow marker on the line suppresses it.
printf '# evidence\ncontact leaked: someone@example.com during the run\n' > "$M/validation/evidence/deploy.example.md"
assert_eq "$(run_lint)" "1" "PII (email) in evidence → FAIL (rc 1)"
assert_contains "$(cat "$T/err")" "PII/secret" "PII FAIL message"
printf '# evidence\nauth flow validates an email login someone@example.com <!-- lint:allow email -->\n' > "$M/validation/evidence/deploy.example.md"
assert_eq "$(run_lint)" "0" "PII with a <!-- lint:allow --> marker is suppressed (rc 0)"

assert_done
