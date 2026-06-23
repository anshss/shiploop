#!/usr/bin/env bash
# #76 regression: re-running govern on a previously-resolved/re-opened ticket must spawn a fresh
# worker cleanly (no manual branch/worktree cleanup), and any GENUINE collision must surface its
# real cause instead of an opaque "#N FAILED".
#
#   Part A — worktree registry self-heals a STALE entry (path gone) and re-allocates; a LIVE entry
#            (path still on disk) still hard-errors as a real collision.
#   Part B — spawn-worker emits a `failed` report carrying the REAL reason when worktree:new fails,
#            rather than `set -e`-aborting (the driver runs it `2>/dev/null || true`, so an abort
#            would discard the cause and yield a bare FAILED).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# ── Part A: registry self-heal ──────────────────────────────────────────────
TMPA="$(mktemp -d)"; trap 'rm -rf "$TMPA"' EXIT
export WT_ROOT="$TMPA"
mkdir -p "$TMPA/.worktrees"
# Seed: slot 1 = a STALE entry whose path is gone; slot 2 = a LIVE entry whose path exists.
LIVE_PATH="$TMPA/live-wt"; mkdir -p "$LIVE_PATH"
GONE_PATH="$TMPA/gone-wt"   # deliberately NOT created
jq -n --arg gone "$GONE_PATH" --arg live "$LIVE_PATH" --arg root "$TMPA" '{
  slots: {
    "0": {name:"__main__", path:$root},
    "1": {name:"ticket-67", path:$gone, createdAt:"x"},
    "2": {name:"ticket-99", path:$live, createdAt:"x"}
  }, nextSlot: 3
}' > "$TMPA/.worktrees/registry.json"

source "$DIR/../../worktree/lib/registry.sh"

# Stale entry (path gone) → self-heals: returns a slot, drops the stale entry, frees its slot.
set +e
slot="$(wt_registry_alloc_and_register "ticket-67" "$TMPA/wt/ticket-67" 2>"$TMPA/err67")"; rc=$?
set -e
assert_eq "$rc" "0" "stale ticket-67 registry entry → alloc_and_register succeeds (self-heal)"
assert_contains "$(cat "$TMPA/err67")" "self-healing" "stale entry logs a self-heal, not a hard error"
# The healed registry must hold exactly one ticket-67 entry pointing at the NEW path.
reg="$(cat "$TMPA/.worktrees/registry.json")"
assert_eq "$(printf '%s' "$reg" | jq '[.slots[] | select(.name=="ticket-67")] | length')" "1" "exactly one ticket-67 entry after self-heal"
assert_eq "$(printf '%s' "$reg" | jq -r '[.slots[] | select(.name=="ticket-67")][0].path')" "$TMPA/wt/ticket-67" "ticket-67 entry now points at the fresh path"

# Live entry (path exists) → genuine collision: hard error, registry untouched.
set +e
out99="$(wt_registry_alloc_and_register "ticket-99" "$TMPA/wt/ticket-99" 2>&1)"; rc99=$?
set -e
assert_eq "$rc99" "1" "live ticket-99 (path on disk) → alloc_and_register refuses (real collision)"
assert_contains "$out99" "already in registry (path exists" "live collision reports the path that exists"

# ── Part B: spawn-worker surfaces a worktree-create failure as a real reason ─
# The template's spawn-worker calls `bash scripts/worktree/new.sh` DIRECTLY (PM-agnostic), so we
# stub THAT (not npm) to fail like a genuine, un-healable collision. A self-contained mini-
# workspace under GOVERN_WS_ROOT keeps the test hermetic — common.sh sources its workspace.sh.
TMPB="$(mktemp -d)"; trap 'rm -rf "$TMPA" "$TMPB"' EXIT
mkdir -p "$TMPB/governor" "$TMPB/scripts/lib" "$TMPB/scripts/worktree" "$TMPB/wt"
# Minimal workspace.sh — exactly what common.sh needs at source time (REPOS + wsp_is_merge_repo),
# plus WORKTREE_BASE so spawn-worker's wtpath resolves into our empty $TMPB/wt (→ else branch).
cat > "$TMPB/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$TMPB}"
ROOT_PM="npm"
GITHUB_ORG="acme"
REPOS=(alpha)
GOVERN_MERGE_REPOS=(alpha)
WORKTREE_BASE="\${WORKTREE_BASE:-$TMPB/wt}"
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
EOF
printf 'DOCTRINE\n' > "$TMPB/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMPB/governor/worker-prompt.md"
cat > "$TMPB/tickets.md" <<'EOF'
## #67 — re-opened ticket
**Severity:** Medium — test.
Observed: collides on re-run.
---
EOF

# Fake new.sh that fails worktree:new exactly like a genuine, un-healable live collision would.
cat > "$TMPB/scripts/worktree/new.sh" <<'EOF'
#!/usr/bin/env bash
echo "worktree 'ticket-67' already in registry (path exists: /somewhere)" >&2
exit 1
EOF
chmod +x "$TMPB/scripts/worktree/new.sh"

# wtpath ($WORKTREE_BASE/ticket-67 = $TMPB/wt/ticket-67) must be ABSENT so the create-failure path
# triggers (a present dir would be treated as a resume/reuse, not a fresh create).
set +e
out="$(GOVERN_WS_ROOT="$TMPB" \
  GOVERN_TICKETS_FILE="$TMPB/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMPB/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMPB/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMPB/logs" \
  bash "$DIR/../spawn-worker.sh" 67 2>/dev/null)"; rc=$?
set -e
assert_eq "$rc" "0" "spawn-worker exits 0 (emits a report) instead of set -e-aborting on a worktree-create failure"
assert_eq "$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)" "failed" "worktree-create failure → status:failed report"
assert_contains "$out" "already in registry" "failed report carries the REAL collision reason (not a bare FAILED)"

assert_done
