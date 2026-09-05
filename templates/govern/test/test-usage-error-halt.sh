#!/usr/bin/env bash
# #56: a harness bump can ship a `claude` invocation flag/subcommand the fleet's installed CLI
# doesn't support yet (version skew). The CLI then rejects the invocation itself — e.g.
# `error: unknown option '--definitely-not-a-real-flag'`, exit 1, a single PLAIN-TEXT line, never
# touching the streaming JSON protocol at all (spawn-worker redirects 2>&1 into $jsonl). That trips
# NEITHER worker_killed (exit 1, not >128) NOR infra/interrupted (no result event, no matching
# signature) NOR extract_report (not JSON) — before this fix it fell through to the generic
# synthesized `failed` bucket, indistinguishable from an ordinary ticket failure, even though every
# worker in the fleet would die identically until the mismatch is fixed. Proves:
#   (1) govern::usage_error_signature matches a non-JSON first line, and does NOT match a real
#       infra/auth outage or an ordinary clean result (no false positive).
#   (2) spawn-worker tags a CLI usage error as status:"usage-error" (carrying the signature), not
#       failed. Unlike infra, run-loop does NOT retry it before halting: a bad flag is deterministic
#       and re-running the same invocation cannot fix itself with a pause.
#   (3) run-loop HALTS on a usage error with a DISTINCT signal (not the generic bad-streak message,
#       and not the infra re-auth message — a version mismatch needs a different fix).
#   (4) NO usage-error outcome is written to the cross-run history (ticket-history.jsonl) — so it
#       never counts toward #60 auto-escalation or misleads govern-improve.
#   (5) the affected ticket stays in tickets.md (clean) for a re-run once the CLI/flag is fixed; the
#       rest of the backlog is never touched, and no per-ticket escalation is filed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

# ── unit: the detection helper itself ───────────────────────────────────────
mk_ws_stub "$(mktemp -d)"  # hermetic workspace stub (independent of the live workspace.sh) — seed before common.sh is sourced
source "$DIR/../lib/common.sh"
U="$(mktemp -d)"; trap 'rm -rf "$U"' EXIT
printf "error: unknown option '--definitely-not-a-real-flag'\n" > "$U/usage.jsonl"
printf '%s\n' '{"type":"result","is_error":true,"result":"API Error: 401 Invalid authentication credentials"}' > "$U/auth.jsonl"
printf '%s\n' '{"type":"result","is_error":false,"result":"{\"status\":\"resolved\"}"}' > "$U/good.jsonl"
: > "$U/empty.jsonl"
assert_contains "$(govern::usage_error_signature "$U/usage.jsonl")" "unknown option" "detects a plain-text CLI usage-error line"
assert_eq       "$(govern::usage_error_signature "$U/auth.jsonl")" ""                 "a real infra/auth outage (JSON result event) is not a usage error (no false positive)"
assert_eq       "$(govern::usage_error_signature "$U/good.jsonl")" ""                 "a clean JSON result is not a usage error (no false positive)"
assert_eq       "$(govern::usage_error_signature "$U/empty.jsonl")" ""                "an empty stream is not a usage error"

# ── integration: spawn-worker tags status:usage-error (not failed), no retry ────────────────
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
# claude that rejects its own invocation: a single plain-text line, rc=1, no JSON anywhere.
cat > "$TMP/claude-usage.sh" <<'EOF'
#!/usr/bin/env bash
printf "error: unknown option '--definitely-not-a-real-flag'\n"
exit 1
EOF
chmod +x "$TMP/claude-usage.sh"

rep="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/wt.sh" \
  GOVERN_CLAUDE_BIN="$TMP/claude-usage.sh" \
  "$SPAWN" 7)"
assert_eq "$(printf '%s' "$rep" | jq -r '.status')" "usage-error"          "spawn-worker tags a CLI usage error as usage-error, not failed"
assert_contains "$(printf '%s' "$rep" | jq -r '.usageError.error')" "unknown option" "usage-error report carries the signature"
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
# every worker dies on the SAME CLI usage error — simulates a harness bump that shipped a flag the
# fleet's installed claude doesn't support yet.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok"}' | jq -Rs .)"; exit 0
fi
printf "error: unknown option '--definitely-not-a-real-flag'\n"
exit 1
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
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 \
  bash "$RL" --serial 1 2 7 2>&1)"

assert_contains "$out" "USAGE-ERROR HALT"          "run halts with a DISTINCT usage-error signal (not the generic bad-streak message)"
assert_contains "$out" "version mismatch"          "halt message points at a harness/CLI version mismatch, not re-auth"
assert_not_contains "$out" "claude login"          "the halt message does NOT tell the operator to re-authenticate (this isn't an auth problem)"
assert_contains "$out" "resolved=0 parked=0 failed=0" "the usage-error ticket was NOT counted as failed/parked"

hist="$T/governor/ticket-history.jsonl"
hcount=0; [[ -f "$hist" ]] && hcount="$(grep -c . "$hist" 2>/dev/null || echo 0)"
assert_eq "$hcount" "0" "NO usage-error outcome written to the cross-run history (no #60 false auto-escalation)"

remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "2" "both tickets remain in tickets.md (clean) for a re-run once the CLI/flag mismatch is fixed"

# no per-ticket escalation was filed under ## Open
open_entries="$(awk '/^## Open/{f=1;next} /^## /{f=0} f&&/^### #/{c++} END{print c+0}' "$T/governor/escalations.md")"
assert_eq "$open_entries" "0" "no per-ticket escalation filed for a CLI usage-error halt"

# the run summary carries the version-mismatch callout, distinct from the infra re-auth callout
assert_contains "$(cat "$T/logs"/run-*/summary.md 2>/dev/null || true)" "Action needed — CLI usage error" "session summary surfaces the CLI usage-error action, distinct from re-authenticate"
rm -rf "$T"

assert_done
