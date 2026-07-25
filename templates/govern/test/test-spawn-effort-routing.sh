#!/usr/bin/env bash
# Locks in the #18 reasoning-effort knob in spawn-worker.sh — an INDEPENDENT control from model
# tier (raising effort is far cheaper than raising tier, so it's the correct first escalation rung):
#   1. `Effort: high` on first attempt → --effort high
#   2. Same ticket on retry (preserved worktree) → falls back to GOVERN_WORKER_EFFORT (or none)
#   3. No `Effort:` field, no GOVERN_WORKER_EFFORT → no --effort flag at all (default unchanged)
#   4. No `Effort:` field, GOVERN_WORKER_EFFORT set → uses the env floor
#   5. Unknown `Effort:` value → fail-safe, run continues with the pre-existing resolution
#
# Uses GOVERN_SPAWN_DRY_RUN=1 to short-circuit BEFORE worktree creation / worker
# launch — pure observation of the assembled invocation params. No auth, no
# claude binary, no state on disk beyond the tmp workspace.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #201 — high-effort ticket

**Severity:** Medium
**Effort:** high
Observed: needs more reasoning than the session default.
Done when: PR opens.

---

## #202 — no-effort ticket

**Severity:** Medium
Observed: bare ticket, no Effort field.
Done when: PR opens.

---

## #203 — unknown-effort ticket

**Severity:** Medium
**Effort:** ultra
Observed: unknown tier — must be dropped.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

run() { # ticket-N [FORCE_RETRY] [GOVERN_WORKER_EFFORT]
  local n="$1" force="${2:-0}" env_effort="${3:-}"
  GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs-$n-$force-$env_effort" \
    GOVERN_WORKER_MODEL="opus" \
    GOVERN_WORKER_EFFORT="$env_effort" \
    GOVERN_SPAWN_DRY_RUN=1 \
    GOVERN_SPAWN_FORCE_RETRY="$force" \
    "$SPAWN" "$n"
}

# 1. First-attempt Effort: high, no env floor → --effort high.
out1="$(run 201 0 "")"
assert_eq "$(printf '%s' "$out1" | jq -r '.effort')" "high" \
  "first-attempt ticket with Effort: high → --effort high"
assert_eq "$(printf '%s' "$out1" | jq -r '.ticket_effort')" "high" \
  "ticket_effort observed = high"
assert_eq "$(printf '%s' "$out1" | jq -r '.effort_source')" "ticket-Effort-field" \
  "effort source = ticket-Effort-field"

# 2. Same ticket on RETRY → escalates AWAY from the ticket field, falls back to unset (no env floor).
out2="$(run 201 1 "")"
assert_eq "$(printf '%s' "$out2" | jq -r '.effort')" "" \
  "retry of Effort: high ticket with no env floor → falls back to unset (no flag)"

# 3. No Effort: field, no GOVERN_WORKER_EFFORT → unset, NO flag at all (default behavior preserved).
out3="$(run 202 0 "")"
assert_eq "$(printf '%s' "$out3" | jq -r '.effort')" "" \
  "no Effort: field + no env floor → empty (no --effort flag passed)"
assert_eq "$(printf '%s' "$out3" | jq -r '.effort_source')" "none (unset)" \
  "effort source = none (unset) when nothing is configured"

# 4. No Effort: field, GOVERN_WORKER_EFFORT=medium → uses the env floor.
out4="$(run 202 0 "medium")"
assert_eq "$(printf '%s' "$out4" | jq -r '.effort')" "medium" \
  "no Effort: field + GOVERN_WORKER_EFFORT=medium → medium"
assert_eq "$(printf '%s' "$out4" | jq -r '.effort_source')" "GOVERN_WORKER_EFFORT" \
  "effort source = GOVERN_WORKER_EFFORT when only the env floor is set"

# 5. Unknown Effort: value → dropped, fail-safe, falls back to whatever the env floor resolves to.
out5="$(run 203 0 "medium")"
assert_eq "$(printf '%s' "$out5" | jq -r '.effort')" "medium" \
  "unknown Effort: value → fail-safe to GOVERN_WORKER_EFFORT"
assert_eq "$(printf '%s' "$out5" | jq -r '.ticket_effort')" "ultra" \
  "unknown ticket_effort still reported in the dry-run output"

assert_done
