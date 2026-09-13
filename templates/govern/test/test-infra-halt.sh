#!/usr/bin/env bash
# An infra/auth outage mid-run (expired OAuth token, API unreachable, network down) must NOT
# be misclassified as a ticket `failed`. Proves govern::infra_error_signature matches the auth
# signature, and does NOT match ordinary content.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# ── unit: the detection helper itself ───────────────────────────────────────
mk_ws_stub "$(mktemp -d)"  # hermetic workspace stub (independent of the live workspace.sh) — seed before common.sh is sourced
source "$DIR/../lib/common.sh"
U="$(mktemp -d)"; trap 'rm -rf "$U"' EXIT
printf '%s\n' '{"type":"result","is_error":true,"result":"API Error: 401 Invalid authentication credentials"}' > "$U/auth.jsonl"
printf '%s\n' '{"type":"result","is_error":true,"result":"API Error: Unable to connect to API (ConnectionRefused)"}' > "$U/conn.jsonl"
printf '%s\n' '{"type":"result","is_error":false,"result":"{\"status\":\"failed\"} ticket genuinely could not connect to the deploy host"}' > "$U/realfail.jsonl"
assert_contains "$(govern::infra_error_signature "$U/auth.jsonl")" "401 Invalid authentication" "detects 401 auth outage"
assert_contains "$(govern::infra_error_signature "$U/conn.jsonl")" "ConnectionRefused"          "detects ConnectionRefused transport outage"
assert_eq       "$(govern::infra_error_signature "$U/realfail.jsonl")" ""                        "a NON-error result event is not an infra outage (no false positive)"

assert_done
