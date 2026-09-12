#!/usr/bin/env bash
# A harness bump can ship a `claude` invocation flag/subcommand the fleet's installed CLI
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
#       failed. A bad flag is deterministic, so re-running the same invocation cannot fix itself.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

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

assert_done
