#!/usr/bin/env bash
# #90: an infra/auth outage mid-run (expired OAuth token, API unreachable, network down) must NOT
# be misclassified as a ticket `failed`. Proves:
#   (1) spawn-worker tags a transport/auth error as status:"infra" (carrying the signature), not failed.
#   (2) run-loop HALTS on a confirmed infra outage with a DISTINCT re-auth message.
#   (3) NO infra-caused outcome is written to the cross-run history (ticket-history.jsonl) — so it
#       never counts toward #60 auto-escalation or misleads govern-improve.
#   (4) the affected ticket stays in tickets.md (clean) for a re-authed re-run; the rest of the
#       backlog is never touched.
#   (5) govern::infra_error_signature matches the auth signature, and does NOT match ordinary content.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

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

# ── integration: run-loop HALTS + leaves no false history ───────────────────
T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — first ticket
**Severity:** High — x.
---
## #2 — second ticket
**Severity:** Medium — y.
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]';; *) echo '[{"bucket":"pass"}]';; esac
EOF
chmod +x "$T/bin/gh"
# every worker dies on the SAME auth outage — simulates an expired token mid-run.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok"}' | jq -Rs .)"; exit 0
fi
printf '{"type":"result","is_error":true,"result":"API Error: 401 Invalid authentication credentials"}\n'
EOF
chmod +x "$T/bin/claude"

out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_HISTORY_FILE="$T/governor/ticket-history.jsonl" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_INFRA_RETRY_PAUSE=0 \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 \
  bash "$RL" 2>&1)"

assert_contains "$out" "INFRA HALT"                 "run halts with a DISTINCT infra signal (not the generic bad-streak message)"
assert_contains "$out" "claude login"               "halt message tells the operator to re-authenticate"
assert_contains "$out" "retrying once before halting" "retried once before halting (transient-blip tolerance)"
assert_contains "$out" "resolved=0 parked=0 failed=0" "the infra ticket was NOT counted as failed/parked"

hist="$T/governor/ticket-history.jsonl"
hcount=0; [[ -f "$hist" ]] && hcount="$(grep -c . "$hist" 2>/dev/null || echo 0)"
assert_eq "$hcount" "0" "NO infra outcome written to the cross-run history (no #60 false auto-escalation)"

remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "2" "both tickets remain in tickets.md (clean) for a re-authed re-run"

# no per-ticket escalation was filed under ## Open
open_entries="$(awk '/^## Open/{f=1;next} /^## /{f=0} f&&/^### #/{c++} END{print c+0}' "$T/governor/escalations.md")"
assert_eq "$open_entries" "0" "no per-ticket escalation filed for an infra outage"

# the run summary carries the re-auth callout
assert_contains "$(cat "$T/logs"/run-*/summary.md 2>/dev/null || true)" "Action needed — re-authenticate" "session summary surfaces the re-auth action"
rm -rf "$T"

assert_done
