#!/usr/bin/env bash
# Regression: MODEL_IS_RETRY must come from a RECORDED attempt (a row in attempts.jsonl, written
# by record_attempt()), never from worktree-directory existence alone.
#
# The harness DELIBERATELY preserves a worktree on failure, on a watchdog kill, and on interrupt,
# so a leftover directory is not evidence a worker ever actually ran in it. A hard SIGKILL (OOM,
# host restart) before the EXIT trap fires leaves a worktree with zero recorded attempts; treating
# that as a retry buys the escalation ceiling for a ticket that never even tried the floor.
#
# Covered here:
#   1. leftover worktree dir + NO recorded attempt anywhere → treated as a FIRST attempt (the
#      regression this test guards against).
#   2. a genuinely recorded prior attempt under the FLAT (standalone) log layout → retry.
#   3. a genuinely recorded prior attempt under the RUN-SCOPED log layout (GOVERN_RUN_DIR set,
#      same run) → retry.
#   4. a genuinely recorded prior attempt under the FLAT layout, but THIS dispatch is run-scoped
#      (GOVERN_RUN_DIR set to a fresh run dir) → still detected as a retry: the lookup must work
#      across BOTH layouts, not just whichever one the current invocation resolves to.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }
SPAWN="$DIR/../spawn-worker.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #7: sample ticket
**Severity:** Medium, test.
Observed: thing is broken.
---
EOF
printf 'DOCTRINE-MARKER\n' > "$TMP/governor/preferences.md"
printf 'PROMPT-HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Fake worktree-create: mirrors the real allocator, makes the dir (idempotently) and echoes it.
# spawn-worker.sh calls this with the SLUG ("ticket-7"), already carrying the "ticket-" prefix.
cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude: resolves cleanly every time, no retry-classification noise to chase.
cat > "$TMP/fake-claude.sh" <<'EOF'
#!/usr/bin/env bash
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

run_spawn() { # <logroot> [extra env assignments...]
  local logroot="$1"; shift
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$logroot" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
    "$@" \
    "$SPAWN" 7 </dev/null >/dev/null
}

# ── 1. leftover worktree dir, NO recorded attempt anywhere → NOT a retry (the regression) ───────
rm -rf "$TMP/wt/ticket-7"; mkdir -p "$TMP/wt/ticket-7"   # a directory left by a hard kill; no ledger
LR1="$TMP/logs1"
run_spawn "$LR1"
row1="$(cat "$LR1/ticket-7/attempts.jsonl")"
assert_eq "$(jq -r '.isRetry' <<<"$row1")" "false" \
  "1. a leftover worktree dir with NO recorded attempt is a FIRST attempt, not a retry (the regression)"
assert_eq "$(jq -r '.attempt' <<<"$row1")" "1" "1. it lands as attempt 1"

# ── 2. a genuinely recorded prior attempt, FLAT (standalone) layout → retry ─────────────────────
rm -rf "$TMP/wt/ticket-7"
LR2="$TMP/logs2"; mkdir -p "$LR2/ticket-7"
printf '{"attempt":1,"model":"sonnet","tokens":{"input":10,"output":5,"cacheRead":0,"cacheCreation":0,"total":15},"status":"failed"}\n' \
  > "$LR2/ticket-7/attempts.jsonl"
run_spawn "$LR2"
row2="$(tail -1 "$LR2/ticket-7/attempts.jsonl")"
assert_eq "$(jq -r '.isRetry' <<<"$row2")" "true" "2. a recorded prior attempt (flat layout) is detected as a retry"
assert_eq "$(jq -r '.attempt' <<<"$row2")" "2" "2. attempt number increments off the existing ledger"

# ── 3. a genuinely recorded prior attempt, RUN-SCOPED layout (same run) → retry ─────────────────
rm -rf "$TMP/wt/ticket-7"
LR3="$TMP/logs3"; RD3="$LR3/run-A"; mkdir -p "$RD3/ticket-7"
printf '{"attempt":1,"model":"sonnet","tokens":{"input":10,"output":5,"cacheRead":0,"cacheCreation":0,"total":15},"status":"failed"}\n' \
  > "$RD3/ticket-7/attempts.jsonl"
run_spawn "$LR3" GOVERN_RUN_DIR="$RD3"
row3="$(tail -1 "$RD3/ticket-7/attempts.jsonl")"
assert_eq "$(jq -r '.isRetry' <<<"$row3")" "true" "3. a recorded prior attempt (run-scoped layout) is detected as a retry"
assert_eq "$(jq -r '.attempt' <<<"$row3")" "2" "3. attempt number increments off the run-scoped ledger"

# ── 4. prior attempt recorded FLAT, but THIS dispatch is run-scoped under a FRESH run dir ───────
# The retry lookup must check BOTH layouts: a run-scoped dispatch (a normal governor run) must
# still see a prior attempt left by an earlier standalone/flat spawn (e.g. a manual re-run before
# this run-scoped one), not just whichever layout THIS invocation happens to resolve to.
rm -rf "$TMP/wt/ticket-7"
LR4="$TMP/logs4"; mkdir -p "$LR4/ticket-7"
printf '{"attempt":1,"model":"sonnet","tokens":{"input":10,"output":5,"cacheRead":0,"cacheCreation":0,"total":15},"status":"failed"}\n' \
  > "$LR4/ticket-7/attempts.jsonl"
RD4="$LR4/run-B"   # a FRESH run-scoped dir this dispatch resolves to, empty, no ledger of its own
run_spawn "$LR4" GOVERN_RUN_DIR="$RD4"
row4="$(cat "$RD4/ticket-7/attempts.jsonl")"
assert_eq "$(jq -r '.isRetry' <<<"$row4")" "true" \
  "4. a prior attempt recorded under the FLAT layout is still seen from a fresh run-scoped dispatch"

assert_done
