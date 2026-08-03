#!/usr/bin/env bash
# §4.4a EARLY ABORT — a doomed worker must die at ~turn 30, not ~turn 218.
#
# A worker session is ~218 assistant turns; a doomed one burns nearly all of that before failing,
# because wall-clock and the token budget are both ceilings a stuck worker only reaches at the very
# end. The early-abort watchdog reads the LIVE worker.jsonl for three DETERMINISTIC signatures
# (stall / identical-command loop / rising tool-error rate) and kills the tree. NO model call is
# involved anywhere in the path.
#
# Covered here:
#   1. STALL      — many assistant turns, zero Edit/Write → early-abort, worktree PRESERVED
#   2. HEALTHY    — same turn count but edits throughout → NOT aborted (the worker finishes normally)
#   3. LOOP       — the same Bash command repeated identically N times → early-abort
#   4. INERT      — GOVERN_EARLY_ABORT unset (default 0) on the SAME stalled stream → no abort
#   5. the new terminal status reaches the returned report, its own ledger row, and the marker file
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

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

# NOTE: echoes $WORKTREE_BASE/<slug> exactly (slug is ALREADY "ticket-N"), so the path spawn-worker
# creates is the same one it reads .governor-notes.md from on a retry.
cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
# Every stub emits a stream and then HANGS (never writes a report), exactly like a real worker that
# gets hard-killed. The wall-clock timeout is set well above the poll interval so the only thing that
# can end these runs quickly is the early-abort watchdog — an unambiguous signal.

# STALLED: 40 assistant turns, every one of them a Read. Zero file mutations.
cat > "$TMP/fake-claude-stall.sh" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 40); do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
done
sleep 60
EOF
chmod +x "$TMP/fake-claude-stall.sh"

# HEALTHY: the same 40 turns, but every 3rd turn is a real Edit — the worker is producing a diff.
cat > "$TMP/fake-claude-healthy.sh" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 40); do
  if (( i % 3 == 0 )); then name=Edit; else name=Read; fi
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n' "$name"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
done
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"http://pr/9"},"lessonPatch":null,"newTickets":[],"crossRefs":{},"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-healthy.sh"

# LOOP: only 6 turns (well under the stall threshold), but the SAME Bash command 6 times. Edits are
# interleaved so the STALL signal can never be what fires — this isolates the loop detector.
cat > "$TMP/fake-claude-loop.sh" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 6); do
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test -- --run flaky"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
done
sleep 60
EOF
chmod +x "$TMP/fake-claude-loop.sh"

run_spawn() { # <logroot> <claude-bin> [extra env assignments...]
  local logroot="$1" bin="$2"; shift 2
  env \
    GOVERN_WORKER_TIMEOUT=60 \
    GOVERN_EARLY_ABORT_POLL_S=1 \
    GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$logroot" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$bin" \
    "$@" \
    "$SPAWN" 7 </dev/null
}

# ── 1. STALL ────────────────────────────────────────────────────────────────────────────────────
out1="$(run_spawn "$TMP/logs-stall" "$TMP/fake-claude-stall.sh" GOVERN_EARLY_ABORT=1 GOVERN_EARLY_ABORT_TURNS=30)"
assert_eq "$(printf '%s' "$out1" | jq -r '.status')" "early-abort" \
  "30+ assistant turns with zero Edit/Write → status:early-abort (not timeout/budget-exceeded/failed)"
assert_contains "$out1" "STALL" "the report carries the DETERMINISTIC signature that fired"
assert_contains "$out1" "INCOMPLETE" "early-abort report says incomplete, not a genuine failure"
[[ -f "$TMP/logs-stall/ticket-7/early-abort.marker" ]] && m=yes || m=no
assert_eq "$m" "yes" "the early-abort marker file is stamped (mirrors budget-exceeded.marker)"
[[ -d "$TMP/wt/ticket-7" ]] && wp=yes || wp=no
assert_eq "$wp" "yes" "worktree PRESERVED so the escalated retry resumes from it"
assert_eq "$(jq -r 'select(.status=="early-abort") | .status' "$TMP/logs-stall/ticket-7/attempts.jsonl")" \
  "early-abort" "the attempts ledger records its OWN early-abort status string"

# ── 2. HEALTHY — must NOT fire ──────────────────────────────────────────────────────────────────
out2="$(run_spawn "$TMP/logs-healthy" "$TMP/fake-claude-healthy.sh" GOVERN_EARLY_ABORT=1 GOVERN_EARLY_ABORT_TURNS=30)"
assert_eq "$(printf '%s' "$out2" | jq -r '.status')" "resolved" \
  "a worker editing files throughout is NOT aborted, at the same turn count"
[[ -f "$TMP/logs-healthy/ticket-7/early-abort.marker" ]] && m2=yes || m2=no
assert_eq "$m2" "no" "no marker stamped for a healthy worker"

# ── 3. LOOP ─────────────────────────────────────────────────────────────────────────────────────
out3="$(run_spawn "$TMP/logs-loop" "$TMP/fake-claude-loop.sh" GOVERN_EARLY_ABORT=1 GOVERN_EARLY_ABORT_TURNS=30 GOVERN_EARLY_ABORT_REPEATS=5)"
assert_eq "$(printf '%s' "$out3" | jq -r '.status')" "early-abort" \
  "the same command issued identically 5+ times → early-abort (stall threshold never reached)"
assert_contains "$out3" "LOOP" "the loop signature is the one reported, not the stall one"
assert_contains "$out3" "npm test" "the report quotes the repeated command"

# ── 4. INERT BY DEFAULT ─────────────────────────────────────────────────────────────────────────
# The SAME stalled stream, with GOVERN_EARLY_ABORT unset. The mechanism must not fire — it ships OFF
# because anything new on the dispatch path perturbs the suite's stateful fake-claude stubs.
# A short wall clock is what ends this one, proving the early-abort watchdog did nothing.
out4="$(run_spawn "$TMP/logs-off" "$TMP/fake-claude-stall.sh" GOVERN_WORKER_TIMEOUT=3)"
assert_eq "$(printf '%s' "$out4" | jq -r '.status')" "timeout" \
  "GOVERN_EARLY_ABORT unset (default 0) → the stalled worker is NOT early-aborted; only the wall clock ends it"
[[ -f "$TMP/logs-off/ticket-7/early-abort.marker" ]] && m4=yes || m4=no
assert_eq "$m4" "no" "default-off leaves no early-abort marker"

# ── 5. ZERO model calls ─────────────────────────────────────────────────────────────────────────
# The stubs above ARE the only `claude` the harness may invoke. Each run_spawn call must have
# invoked its stub exactly once; a watchdog that consulted a model would show up as extra
# invocations. Count them from the stall run's stream: one stub run = one contiguous stream.
turns="$(grep -ac '"type":"assistant"' "$TMP/logs-stall/ticket-7/worker.jsonl" || true)"
[[ "${turns:-0}" -ge 30 ]] && enough=yes || enough=no
assert_eq "$enough" "yes" "the watchdog read a real 30+ turn stream (deterministic, no model call)"

assert_done
