#!/usr/bin/env bash
# Regression for ticket #239: spawn-worker.sh must run the post-worker orphan-resource sweep on
# EVERY exit path — including a worker hard-KILLED by GOVERN_WORKER_TIMEOUT (the #3001 leak: a
# killed worker never ran its own cleanup). We use the GOVERN_DEPLOY_SWEEP_CMD test seam to record
# that the sweep fired, and assert it fires both when the worker resolves cleanly AND when it is
# killed mid-run. The sweep is also passed the worker's start epoch (so the real sweep is windowed).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"  # hermetic workspace stub (independent of the live workspace.sh)
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

# Sweep recorder: appends "<since>\t<ticket>" each time spawn-worker invokes the sweep.
SWEEPLOG="$TMP/sweep-calls.txt"; : > "$SWEEPLOG"
cat > "$TMP/fake-sweep.sh" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\${1:-}" "\${2:-}" >> "$SWEEPLOG"
EOF
chmod +x "$TMP/fake-sweep.sh"

run_spawn() { # claude-bin logsuffix
  GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-$2" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$1" \
  GOVERN_DEPLOY_SWEEP_CMD="$TMP/fake-sweep.sh" \
  "$SPAWN" 7
}

# Case 1 — clean resolve: sweep must still fire (defence-in-depth even when the worker self-cleaned).
cat > "$TMP/fake-claude-ok.sh" <<EOF
#!/usr/bin/env bash
report='{"status":"resolved","pr":{"repo":"alpha","number":99},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-ok.sh"

out1="$(run_spawn "$TMP/fake-claude-ok.sh" ok)"
assert_eq "$(printf '%s' "$out1" | jq -r '.status')" "resolved" "clean worker still resolves"
assert_eq "$(grep -c . "$SWEEPLOG")" "1" "sweep fires once after a cleanly-resolved worker"

# Case 2 — KILLED worker (exit >128, no report): the load-bearing case. Sweep MUST fire.
: > "$SWEEPLOG"
cat > "$TMP/fake-claude-killed.sh" <<'EOF'
#!/usr/bin/env bash
# Simulate a worker hard-killed mid-run after it created a resource: emit nothing, die with 137.
exit 137
EOF
chmod +x "$TMP/fake-claude-killed.sh"

out2="$(run_spawn "$TMP/fake-claude-killed.sh" killed)"
# #241: a worker hard-killed before writing a verdict is now `timeout` (incomplete → re-run), NOT
# `failed` — a kill-before-verdict can mask a possibly-working result, so it must not read as a
# genuine feature failure. (The #239 orphan-resource sweep below still fires regardless of status.)
assert_eq "$(printf '%s' "$out2" | jq -r '.status')" "timeout" "killed worker → synthesized timeout report (not failed) [#241]"
assert_eq "$(grep -c . "$SWEEPLOG")" "1" "sweep fires after a KILLED/timed-out worker (the #3001 leak fix)"

# The sweep was handed a numeric start epoch (so the real sweep can window by --created-after).
since="$(cut -f1 "$SWEEPLOG" | head -1)"
[[ "$since" =~ ^[0-9]+$ ]] && numeric=y || numeric=n
assert_eq "$numeric" "y" "sweep is passed the worker's start epoch"
assert_eq "$(cut -f2 "$SWEEPLOG" | head -1)" "7" "sweep is passed the ticket number"

assert_done
