#!/usr/bin/env bash
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
printf 'PROMPT-HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Fake worktree-create: just makes the dir and prints its path.
cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude: write the assembled prompt to a sink, emit a stream-json result line whose
# .result is the report JSON, AND write the report file (simulating a writable live worker).
cat > "$TMP/fake-claude.sh" <<EOF
#!/usr/bin/env bash
# args include -p "<prompt>" ... ; capture the prompt (the arg after -p)
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" > "$TMP/seen-prompt.txt"
report='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"u"},"lessonToPromote":null,"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
  "$SPAWN" 7)"

assert_contains "$out" '"status":"resolved"' "returns the worker's JSON report"
assert_contains "$out" '"number":99' "report carries the PR number"
seen="$(cat "$TMP/seen-prompt.txt")"
assert_contains "$seen" "sample ticket" "prompt includes the ticket block"
assert_contains "$seen" "DOCTRINE-MARKER" "prompt includes the preferences doctrine"

# #66 regression: a worker that DID the work but emitted "JSON + trailing prose" as its final
# message (and wrote NO report file) must be parsed as its real status, not synthesized `failed`.
cat > "$TMP/fake-claude-prose.sh" <<EOF
#!/usr/bin/env bash
# Emit a result message whose .result is "<valid JSON> + trailing prose"; write NO report file.
report='{"status":"resolved","pr":{"repo":"alpha","number":116},"newTickets":[],"escalation":null}'
msg="\$report

Ticket #12 resolved. PR #116 is open and ready for review."
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$msg" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-prose.sh"

out2="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs2" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-prose.sh" \
  "$SPAWN" 7)"

assert_eq "$(printf '%s' "$out2" | jq -r '.status')" "resolved" "JSON+prose final message → resolved, not failed"
assert_eq "$(printf '%s' "$out2" | jq -r '.pr.number')" "116" "JSON+prose final message → PR number preserved"

# #66: a worker that produced NO parseable JSON anywhere still yields a synthesized failed report.
cat > "$TMP/fake-claude-noreport.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"result","result":"I could not finish the ticket today, sorry."}\n'
EOF
chmod +x "$TMP/fake-claude-noreport.sh"

out3="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs3" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-noreport.sh" \
  "$SPAWN" 7)"

assert_eq "$(printf '%s' "$out3" | jq -r '.status')" "failed" "no parseable JSON anywhere → synthesized failed"

assert_done
