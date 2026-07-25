#!/usr/bin/env bash
# A ticket that ends NON-RESOLVED must be answered ONCE PER RUN — even under the parallel default.
#
# The claim lock only keeps two drivers off a ticket WHILE one holds it. A ticket that times out (or
# burns its token budget, or fails, or parks) is still in tickets.md, and its claim is released the
# instant its outcome is recorded — while `$excludes`, the thing that stops the SAME driver re-picking
# it, is per-process in-memory state a sibling cannot see. So any sibling that reaches selection after
# that release re-picks the ticket and burns a SECOND full worker on a question this run has already
# answered, and writes a second state.jsonl + ticket-history row for one ticket in one run (which
# double-counts the #60 consecutive-failure streak).
#
# This fixture forces exactly that interleaving deterministically rather than waiting for a slow CI
# runner to hit it: driver 1 takes ticket #1 and stays busy for 4s, driver 2 takes ticket #2 and is
# token-budget-killed after ~1s, so driver 1 reaches its NEXT selection long after #2 was recorded and
# released. Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — slow ticket that resolves
**Severity:** Medium — test.
body1
---
## #2 — ticket whose worker is killed before a verdict
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
#   worker #1 → sleeps 4s (holding driver 1 well past #2's kill), then resolves. It emits NO
#               `assistant` usage events, so the token watchdog never counts anything against it.
#   worker #2 → emits one over-budget usage event then hangs → token watchdog kills it at ~1s.
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
sleep 4
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"validation":null,"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

# --parallel=2 with NO stagger, so both drivers reach selection immediately and each claims one
# ticket. GOVERN_WORKER_TIMEOUT is deliberately generous (the kill under test is the TOKEN budget,
# which fires in ~1s) so ticket #1's 4s worker is never wall-clock-killed.
out="$(PATH="$T/bin:$PATH" \
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
  GOVERN_ALLOW_CONCURRENT=1 \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_PARALLEL_STAGGER_S=0 \
  GOVERN_WORKER_TIMEOUT=20 GOVERN_WORKER_MAX_TOKENS=100 GOVERN_TOKEN_POLL_S=1 \
  bash "$RL" --parallel=2 </dev/null 2>&1)"

# The cross-run history is ONE file shared by every driver, so it is the unambiguous place to count
# how many workers a ticket actually consumed this run — the per-driver state.jsonl files are folded
# into the orchestrator's, which would hide nothing but is harder to attribute.
n2="$(jq -r 'select(.ticket==2) | .status' "$T/history.jsonl" 2>/dev/null | grep -c . || true)"
n1="$(jq -r 'select(.ticket==1) | .status' "$T/history.jsonl" 2>/dev/null | grep -c . || true)"
assert_eq "$n2" "1" "a killed-before-verdict ticket consumes exactly ONE worker per run, not one per driver [#19]"
assert_eq "$n1" "1" "the resolved ticket is recorded exactly once too"
assert_eq "$(jq -r 'select(.ticket==2) | .status' "$T/history.jsonl" | head -1)" "budget-exceeded" \
  "and it is still classified budget-exceeded (the dedup does not change the outcome)"

# Same invariant in the orchestrator's AGGREGATED state.jsonl — that is what an operator, the
# whole-run supervisor and the session summary all read.
agg="$(ls -t "$T"/logs/run-*/state.jsonl | head -1)"
assert_eq "$(jq -r 'select(.ticket==2)' "$agg" | grep -c '"ticket"' || true)" "1" \
  "the aggregated state.jsonl carries ONE row for the killed ticket, not one per driver"

rm -rf "$T"
assert_done
