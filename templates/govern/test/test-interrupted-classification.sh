#!/usr/bin/env bash
# A per-ticket worker whose `claude -p` stream dies from a TRANSIENT connection drop
# mid-response (laptop sleep / network suspend) — the worker exits on its OWN (NOT hard-killed by the
# timeout watchdog) with a result event `is_error:true, result:"API Error: Connection closed
# mid-response"`, must be classified as the DISTINCT per-worker status `interrupted`, not
# `failed`/`infra`, carrying a non-empty error signature.
# Hermetic + generic (mk_ws_stub seeds a throwaway workspace).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ---------------------------------------------------------------------------
# Part 1 — spawn-worker.sh: worker exits on its own (NOT killed) with a mid-stream
#          connection-drop result event → status:"interrupted", not "failed"/"infra".
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"
cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
printf 'DOCTRINE-MARKER\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude that writes NO report file and emits a stream result event marking a TRANSIENT
# mid-response connection drop, then exits 0 ON ITS OWN (worker_killed=0 — NOT the watchdog).
cat > "$TMP/fake-claude-interrupted.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"result","is_error":true,"result":"API Error: Connection closed mid-response"}\n'
exit 0
EOF
chmod +x "$TMP/fake-claude-interrupted.sh"

# _GOVERN_EDP_SUPPORTED=1 + _GOVERN_TOOLS_SUPPORTED=1: skip BOTH --help capability probes. Each
# one invokes $claude_bin, so an un-seeded probe is an extra fake-claude call — the `claude --help` capability probe (common.sh test seam) — this
# fake claude has no --help branch, and letting the probe fall through to the stub's stateful
# call-counter logic would consume an extra invocation before the real attempt #1 runs.
out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-interrupted.sh" \
  GOVERN_WORKER_TIMEOUT=30 \
  _GOVERN_EDP_SUPPORTED=1 \
  _GOVERN_TOOLS_SUPPORTED=1 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "interrupted" "self-exit mid-stream drop → status:interrupted (NOT failed/infra)"
assert_eq "$(printf '%s' "$out" | jq -r '(.interrupted.error // "") | length > 0')" "true" "interrupted report carries a non-empty .interrupted.error signature"

assert_done
