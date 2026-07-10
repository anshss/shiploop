#!/usr/bin/env bash
# #34 (b): a per-ticket worker whose `claude -p` stream dies from a TRANSIENT connection drop
# mid-response (laptop sleep / network suspend) — the worker exits on its OWN (NOT hard-killed by the
# timeout watchdog) with a result event `is_error:true, result:"API Error: Connection closed
# mid-response"` — must be classified as the DISTINCT per-worker status `interrupted`, auto-retried
# ONCE in-run from the preserved worktree, and if the retry ALSO transport-fails the ticket is
# recorded `interrupted` (NOT `failed`), the worktree is preserved, and it never pollutes the
# cross-run history. It DOES trip the in-run bad-streak so a chronically-sleeping laptop halts cleanly.
# Hermetic + generic (mk_ws_stub seeds a throwaway workspace).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

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

out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-interrupted.sh" \
  GOVERN_WORKER_TIMEOUT=30 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "interrupted" "self-exit mid-stream drop → status:interrupted (NOT failed/infra) [#34]"
assert_eq "$(printf '%s' "$out" | jq -r '(.interrupted.error // "") | length > 0')" "true" "interrupted report carries a non-empty .interrupted.error signature"

# ---------------------------------------------------------------------------
# Part 2 — run-loop.sh: 1st worker attempt is interrupted → AUTO-RETRY ONCE →
#          the retry resolves → final state.jsonl status == resolved.
# ---------------------------------------------------------------------------
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — normal bugfix ticket
**Severity:** Medium — fix the thing.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

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

# stub claude (counter-file driven, path inherited via env):
#   supervisor → ok verdict.
#   worker call #1 → transient connection drop (interrupted), NO report file, exit 0 (self-exit).
#   worker call #2 (the auto-retry) → normal resolved report to $GOVERN_REPORT_PATH.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
c=$(cat "$WORKER_ATTEMPT_COUNTER" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$WORKER_ATTEMPT_COUNTER"
if [[ "$c" -eq 1 ]]; then
  # first attempt: transient mid-response connection drop, worker self-exits, NO report file written.
  printf '{"type":"result","is_error":true,"result":"API Error: Connection closed mid-response"}\n'
  exit 0
fi
# the auto-retry recovers and resolves the ticket.
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"validation":{"required":false,"ranLiveTest":false,"evidence":""},"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out2="$(PATH="$T/bin:$PATH" \
  ROOT_PM=npm \
  WORKER_ATTEMPT_COUNTER="$T/counter" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_WORKER_TIMEOUT=30 \
  bash "$RL" 2>&1)"

state="$(ls -t "$T"/logs/run-*/state.jsonl | head -1)"
assert_eq "$(jq -r 'select(.ticket==1) | .status' "$state")" "resolved" "#1 interrupted then auto-retried → resolved [#34]"
assert_contains "$out2" "auto-retrying once" "run log shows the ONE in-run interrupted auto-retry fired"
assert_eq "$(cat "$T/counter")" "2" "exactly two worker attempts (initial + one retry)"

rm -rf "$T"

# ---------------------------------------------------------------------------
# Part 3 — run-loop.sh: BOTH the initial attempt and the auto-retry drop →
#          final status interrupted (NOT failed), worktree preserved, NO history row.
# ---------------------------------------------------------------------------
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — normal bugfix ticket
**Severity:** Medium — fix the thing.
body1
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
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor ok; EVERY worker attempt drops mid-response (interrupted).
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
printf '{"type":"result","is_error":true,"result":"API Error: Connection closed mid-response"}\n'
exit 0
EOF
chmod +x "$T/bin/claude"

out3="$(PATH="$T/bin:$PATH" \
  ROOT_PM=npm \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_WORKER_TIMEOUT=30 \
  bash "$RL" 2>&1)"

state="$(ls -t "$T"/logs/run-*/state.jsonl | head -1)"
assert_eq "$(jq -r 'select(.ticket==1) | .status' "$state")" "interrupted" "retry ALSO drops → recorded interrupted (NOT failed) [#34]"
assert_contains "$out3" "interrupted=1" "DONE/summary line counts the interrupt distinctly"
assert_contains "$out3" "failed=0"      "a transient interrupt is NEVER counted as a failure"

[[ -d "$T/wt/ticket-1" ]] && wp=yes || wp=no
assert_eq "$wp" "yes" "interrupted ticket's worktree PRESERVED for resume"

# cross-run history must have NO row for #1 (an environment artifact, not #60 ticket difficulty).
if [[ -s "$T/history.jsonl" ]]; then
  hrows="$(jq -r 'select(.ticket==1) | .status' "$T/history.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
else
  hrows=0
fi
assert_eq "$hrows" "0" "interrupted is DROPPED from cross-run history (no #60 auto-escalation) [#34]"

rm -rf "$T"

# ---------------------------------------------------------------------------
# Part 4 (optional) — a chronically-sleeping laptop: consecutive terminal interrupts
#          DO trip the in-run circuit breaker (LOCKED design: interrupted → bad_streak++).
# ---------------------------------------------------------------------------
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — ticket one
**Severity:** Medium — fix.
b1
---
## #2 — ticket two
**Severity:** Medium — fix.
b2
---
## #3 — ticket three
**Severity:** Medium — fix.
b3
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
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
printf '{"type":"result","is_error":true,"result":"API Error: Connection closed mid-response"}\n'
exit 0
EOF
chmod +x "$T/bin/claude"

out4="$(PATH="$T/bin:$PATH" \
  ROOT_PM=npm \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_WORKER_TIMEOUT=30 \
  GOVERN_MAX_BAD_STREAK=2 \
  bash "$RL" 2>&1)"

assert_contains "$out4" "circuit breaker" "consecutive interrupts trip the in-run circuit breaker [#34 LOCKED]"

rm -rf "$T"
assert_done
