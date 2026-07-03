#!/usr/bin/env bash
# Regression for ticket #75: the worker log must be RUN-SCOPED so a re-run of ticket N never reads
# a PRIOR run's stale worker.jsonl. Asserts:
#   1. with GOVERN_RUN_DIR set, spawn-worker writes under $GOVERN_RUN_DIR/ticket-N/ (NOT flat).
#   2. a pre-existing legacy flat logs/govern/ticket-N/worker.jsonl is ROTATED away at spawn, so no
#      consumer can tail a prior run's stale data.
#   3. standalone (no GOVERN_RUN_DIR) still falls back to the legacy flat $LOG_ROOT/ticket-N/.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

# #127: be HERMETIC. When this test runs UNDER the governor (e.g. as part of the suite during a
# govern run, or in a worker worktree) the loop has exported GOVERN_RUN_DIR / GOVERN_RUN / GOVERN_*
# into the environment. Case 3 below asserts the STANDALONE fallback (no GOVERN_RUN_DIR → flat
# path); an inherited GOVERN_RUN_DIR leaks into that spawn and the worker writes to the run-scoped
# dir instead, so the flat log never appears (expected yes, actual no). Scrub every inherited
# GOVERN_* var up front so each case controls exactly the env it sets via run_spawn.
while IFS='=' read -r v _; do [[ -n "$v" ]] && unset "$v"; done < <(env | sed -n 's/^\(GOVERN_[A-Za-z0-9_]*\)=.*/\1/p')

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # hermetic workspace stub (seeds + exports GOVERN_WS_ROOT after the scrub)
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude: print a stream-json result line (→ becomes worker.jsonl) + write the report file.
cat > "$TMP/fake-claude.sh" <<'EOF'
#!/usr/bin/env bash
report='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

run_spawn() { # extra-env...
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
    "$@" "$SPAWN" 7 >/dev/null
}

# ── 1+2: run-scoped, with a STALE legacy flat log pre-seeded ──────────────────
LR="$TMP/logs"; RUNDIR="$LR/run-20260612-000000"
mkdir -p "$LR/ticket-7"
printf '{"stale":"PRIOR-RUN-DATA"}\n' > "$LR/ticket-7/worker.jsonl"

run_spawn GOVERN_LOG_ROOT="$LR" GOVERN_RUN_DIR="$RUNDIR"

exists() { [[ -f "$1" ]] && echo yes || echo no; }
assert_eq "$(exists "$RUNDIR/ticket-7/worker.jsonl")" yes "worker log written under the RUN dir"
assert_eq "$(exists "$RUNDIR/ticket-7/report.json")"  yes "report written under the RUN dir"
assert_contains "$(cat "$RUNDIR/ticket-7/worker.jsonl")" 'resolved' "run-scoped log holds THIS run's output"
# the legacy flat log must be GONE (rotated) — no stale prior-run data left for any tail consumer
assert_eq "$(exists "$LR/ticket-7/worker.jsonl")" no "legacy flat worker.jsonl rotated away when run-scoped"

# ── 3: standalone (no GOVERN_RUN_DIR) → legacy flat path fallback ─────────────
LR2="$TMP/logs-standalone"
run_spawn GOVERN_LOG_ROOT="$LR2"
assert_eq "$(exists "$LR2/ticket-7/worker.jsonl")" yes "standalone falls back to the legacy flat path"

assert_done
