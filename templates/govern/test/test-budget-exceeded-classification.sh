#!/usr/bin/env bash
# #16 regression: a worker HARD-KILLED by GOVERN_WORKER_MAX_TOKENS before it could write its verdict
# must NOT be recorded as `failed` (masks a possibly-working feature as broken) and must NOT be
# conflated with a wall-clock `timeout` — it is a DISTINCT `budget-exceeded` (incomplete, re-run)
# outcome, because a future evidence-based escalation needs to tell "ran out of budget while still
# exploring" apart from other failure modes. Also: GOVERN_WORKER_MAX_TOKENS=0 (default) preserves
# current unbounded-token behavior. Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

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

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "budget-exceeded" "killed-before-verdict via token budget → status:budget-exceeded (NOT timeout/failed) [#16]"
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

# ── Part 2 — run-loop.sh classifies a budget-exceeded worker as `budget-exceeded` (not `failed`/`timeout`), ──
#    preserves the worktree, and counts it distinctly in the DONE summary + cross-run history.
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — sample ticket one
**Severity:** Medium — test.
body1
---
## #2 — sample ticket two
**Severity:** Medium — test.
body2
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

# stub gh: resume `pr list` → none; checks → pass
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude:
#   supervisor → ok verdict.
#   worker #1 → resolved.
#   worker #2 → burns way over budget then hangs → token watchdog kills it → budget-exceeded.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
if [[ "$n" == "2" ]]; then
  printf '{"type":"assistant","message":{"usage":{"input_tokens":500,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
  exec sleep 30
fi
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"validation":null,"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out2="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 \
  GOVERN_WORKER_TIMEOUT=30 GOVERN_WORKER_MAX_TOKENS=100 GOVERN_TOKEN_POLL_S=1 \
  bash "$RL" </dev/null 2>&1)"

# locate the run's state.jsonl
state="$(ls -t "$T"/logs/run-*/state.jsonl | head -1)"

s1="$(jq -r 'select(.ticket==1) | .status' "$state")"
s2="$(jq -r 'select(.ticket==2) | .status' "$state")"
assert_eq "$s1" "resolved" "ticket #1 resolves normally"
assert_eq "$s2" "budget-exceeded" "killed-before-verdict via token budget #2 → recorded budget-exceeded (NOT failed/timeout) [#16]"

assert_contains "$out2" "budget-exceeded=1" "DONE summary counts budget-exceeded distinctly"
assert_contains "$out2" "timed-out=0" "a budget kill is NOT counted as a wall-clock timeout"
assert_contains "$out2" "failed=0"    "a budget kill is NOT counted as a failure"

# cross-run history records #2 as `budget-exceeded` (its own #60-style streak axis)
assert_eq "$(jq -r 'select(.ticket==2) | .status' "$T/history.jsonl")" "budget-exceeded" "history records #2 as budget-exceeded"

# the budget-killed worktree is PRESERVED (re-run resumes); wt teardown is a no-op under GOVERN_WORKTREE_CMD.
[[ -d "$T/wt/ticket-2" ]] && wp=yes || wp=no
assert_eq "$wp" "yes" "budget-exceeded ticket's worktree preserved for resume"

rm -rf "$T"
assert_done
