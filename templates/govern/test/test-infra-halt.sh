#!/usr/bin/env bash
# #90: an infra/auth outage mid-run (expired OAuth token, API unreachable, network down) must NOT
# be misclassified as a ticket `failed`. Proves:
#   (1) spawn-worker tags a transport/auth error as status:"infra" (carrying the signature), not failed.
#   (2) govern::infra_error_signature matches the auth signature, and does NOT match ordinary content.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
SPAWN="$DIR/../spawn-worker.sh"

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

# ── integration: spawn-worker tags status:infra (not failed) ────────────────
TMP="$(mktemp -d)"; mkdir -p "$TMP/governor" "$TMP/wt"
cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"
cat > "$TMP/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/wt.sh"
# claude that dies on a transport outage: emits an error result event, writes NO report file.
cat > "$TMP/claude-infra.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"result","is_error":true,"result":"API Error: Unable to connect to API (ConnectionRefused)"}\n'
EOF
chmod +x "$TMP/claude-infra.sh"

rep="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/wt.sh" \
  GOVERN_CLAUDE_BIN="$TMP/claude-infra.sh" \
  "$SPAWN" 7)"
assert_eq "$(printf '%s' "$rep" | jq -r '.status')" "infra"          "spawn-worker tags transport outage as infra, not failed"
assert_contains "$(printf '%s' "$rep" | jq -r '.infra.error')" "ConnectionRefused" "infra report carries the signature"
rm -rf "$TMP"

assert_done
