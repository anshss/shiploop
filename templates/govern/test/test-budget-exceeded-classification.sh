#!/usr/bin/env bash
# Regression: a worker HARD-KILLED by GOVERN_WORKER_MAX_TOKENS before it could write its verdict
# must NOT be recorded as `failed` (masks a possibly-working feature as broken) and must NOT be
# conflated with a wall-clock `timeout` — it is a DISTINCT `budget-exceeded` (incomplete, re-run)
# outcome, because a future evidence-based escalation needs to tell "ran out of budget while still
# exploring" apart from other failure modes. Also: GOVERN_WORKER_MAX_TOKENS=0 (default) preserves
# current unbounded-token behavior. Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ── Part 1 — spawn-worker.sh: budget kill-before-verdict → status:"budget-exceeded", not "timeout"/"failed". ──
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

# Fake claude that emits ONE assistant usage event well over budget (150 tokens), then hangs forever
# (never writes a report). The token watchdog polls every 1s and should kill it long before the 30s
# wall-clock timeout, so the distinguishing signal is unambiguous.
cat > "$TMP/fake-claude-budget.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
sleep 30
EOF
chmod +x "$TMP/fake-claude-budget.sh"

out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-budget.sh" \
  GOVERN_WORKER_TIMEOUT=30 \
  GOVERN_WORKER_MAX_TOKENS=100 \
  GOVERN_TOKEN_POLL_S=1 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "budget-exceeded" "killed-before-verdict via token budget → status:budget-exceeded (NOT timeout/failed)"
assert_contains "$out" "INCOMPLETE" "budget-exceeded report explains it is incomplete, not a genuine failure"
assert_contains "$out" "GOVERN_WORKER_MAX_TOKENS" "budget-exceeded report names the knob that fired"

# ── Part 1b — GOVERN_WORKER_MAX_TOKENS=0 (default) never triggers the token watchdog, even with the
#    SAME over-threshold usage — preserves current unbounded-token behavior for anyone who doesn't set it.
cat > "$TMP/fake-claude-finish.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"http://pr/9"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"validation":null,"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-finish.sh"

out0="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-finish.sh" \
  GOVERN_WORKER_TIMEOUT=30 \
  GOVERN_TOKEN_POLL_S=1 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out0" | jq -r '.status')" "resolved" "GOVERN_WORKER_MAX_TOKENS unset (default 0=unlimited) never kills on token usage"

assert_done
