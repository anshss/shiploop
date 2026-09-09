#!/usr/bin/env bash
# #241 regression: a validation worker HARD-KILLED by GOVERN_WORKER_TIMEOUT before it could write its
# verdict must NOT be recorded as `failed` (which masks a possibly-working feature as broken) — it is
# a DISTINCT `timeout` (incomplete, re-run) outcome. The classification lives in spawn-worker.sh, so
# it is what this file proves. The cross-attempt consequence of a `timeout` row (it feeds the
# failure-streak breaker) is proved in test-pre-dispatch-check.sh, which owns that gate now.
# Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ── spawn-worker.sh: kill-before-verdict → status:"timeout", not "failed". ──
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"
cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample validation ticket
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

# Fake claude that NEVER finishes (sleeps past the 1s timeout) and writes NO report file — exactly the
# kill-before-verdict shape: the watchdog TERM/KILLs it (rc>128 → worker_killed=1).
cat > "$TMP/fake-claude-hang.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$TMP/fake-claude-hang.sh"

out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-hang.sh" \
  GOVERN_WORKER_TIMEOUT=1 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "timeout" "killed-before-verdict → status:timeout (NOT failed) [#241]"
assert_contains "$out" "INCOMPLETE" "timeout report explains it is incomplete, not a genuine failure"

assert_done
