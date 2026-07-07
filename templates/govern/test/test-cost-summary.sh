#!/usr/bin/env bash
# Onboarding mechanisms: cost transparency. The governor's end-of-run summary gains a Spend line —
# tokens + (when the worker JSONL carried it) dollar cost, per ticket + summed — derived from the
# stream-json result event's usage / total_cost_usd that record()/history_enrich already fold into
# ticket-history.jsonl. Full hermetic loop with a stubbed jsonl carrying those fields (mirrors
# test-aborted-summary.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — a ticket whose worker reports usage + cost
**Severity:** Medium — x.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'DOC\n' > "$T/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)    echo '[]';;
  *"pr checks"*)  echo '[{"bucket":"pass"}]';;
  *"pr merge"*)   echo 'merged';  exit 0;;
  *"pr view"*)    echo 'ticket-1'; exit 0;;
  *)              echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# Worker: supervisor verdict on the marker; else resolve #1 with a PR AND emit a stream-json result
# event carrying top-level `usage` + `total_cost_usd` (what real Claude Code emits) so history_enrich
# can fold cost/tokens into ticket-history.jsonl.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
# result event: usage (1000 in + 500 out = 1500 total) + total_cost_usd 0.0123 (rounds to $0.01).
printf '{"type":"result","result":%s,"usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.0123}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

set +e
out="$(PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_HISTORY_FILE="$T/logs/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 </dev/null 2>&1)"
rc=$?
set -e

assert_eq "$rc" "0" "run exits 0"
assert_contains "$out" "merged alpha#101" "the ticket resolved + merged"

SUM="$T/logs/last-session.md"
[[ -f "$SUM" ]] || SUM="$(ls -t "$T"/logs/run-*/summary.md 2>/dev/null | head -1)"
sumtext="$(cat "$SUM")"
assert_contains "$sumtext" "**Spend:**"       "summary carries a Spend line"
assert_contains "$sumtext" "1500 tokens"      "Spend line reports the summed token total (1000+500)"
assert_contains "$sumtext" '~$0.01'           "Spend line reports the summed dollar cost (0.0123 → \$0.01)"
assert_contains "$sumtext" "#1 \$0.01/1500t"  "Spend line breaks cost + tokens out per ticket"

# Token-only fallback: a worker.jsonl with usage but NO total_cost_usd → tokens shown, no invented price.
mkdir -p "$T/logs2" "$T/governor2"
printf '## Open\n\n## Resolved\n' > "$T/governor2/escalations.md"
printf 'DOC\n' > "$T/governor2/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor2/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor2/supervisor-prompt.md"
cat > "$T/tickets2.md" <<'EOF'
# Tickets
---
## #2 — worker reports usage but no cost
**Severity:** Medium — x.
body2
---
EOF
cat > "$T/bin/claude-nocost" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
report='{"status":"resolved","pr":{"repo":"alpha","number":201,"url":"http://pr/2"},"lessonPatch":null,"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s,"usage":{"input_tokens":700,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n' \
  "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude-nocost"

set +e
out2="$(PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets2.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor2/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor2/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor2/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor2/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs2" \
  GOVERN_HISTORY_FILE="$T/logs2/history.jsonl" \
  GOVERN_LOCK="$T/lock2" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude-nocost" \
  GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 2 </dev/null 2>&1)"
set -e
SUM2="$T/logs2/last-session.md"
[[ -f "$SUM2" ]] || SUM2="$(ls -t "$T"/logs2/run-*/summary.md 2>/dev/null | head -1)"
sumtext2="$(cat "$SUM2")"
assert_contains "$sumtext2" "1000 tokens"                 "no-cost run still reports tokens (700+300)"
assert_contains "$sumtext2" "token counts only"           "no-cost run says token-only (no invented price)"
if grep -qF '~$' <<<"$sumtext2"; then
  printf 'FAIL - %s\n' "no-cost run shows NO dollar figure"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "no-cost run shows NO dollar figure"; fi

assert_done
