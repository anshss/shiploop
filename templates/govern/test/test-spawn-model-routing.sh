#!/usr/bin/env bash
# Locks in brain-decided per-ticket model routing in spawn-worker.sh:
#   1. `Model: sonnet` on first attempt → --model sonnet
#   2. Same ticket on retry (preserved worktree) → escalate to GOVERN_WORKER_MODEL
#   3. No `Model:` field → unchanged (GOVERN_WORKER_MODEL default)
#   4. Unknown `Model:` value → fail-safe to GOVERN_WORKER_MODEL, run continues
#   5. NO leading `Model:` field but a fenced `Model: haiku` in the body → NOT parsed as the
#      field; routes to GOVERN_WORKER_MODEL (extraction anchored to leading field block)
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
## #101 — sonnet-tier ticket
**Severity:** Medium
**Model:** sonnet
Observed: standard search+edit ticket.
Done when: PR opens.

---

## #102 — no-model ticket
**Severity:** Medium
Observed: bare ticket, no Model field.
Done when: PR opens.

---

## #103 — unknown-model ticket
**Severity:** Medium
**Model:** gpt-nano
Observed: unknown tier — must be dropped.
Done when: PR opens.

---

## #104 — fenced-Model-in-body ticket
**Severity:** Medium
Observed: ticket has NO leading Model: field, but the body includes a code fence
that mentions Model: haiku in prose. That MUST NOT be parsed as the routing field.

Example log the operator pasted:
```
Model: haiku
```

Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

run() { # ticket-N [FORCE_RETRY]
  local n="$1" force="${2:-0}"
  GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs-$n-$force" \
    GOVERN_WORKER_MODEL="opus" \
    GOVERN_SPAWN_DRY_RUN=1 \
    GOVERN_SPAWN_FORCE_RETRY="$force" \
    "$SPAWN" "$n"
}

# 1. First-attempt Model: sonnet → --model sonnet
out1="$(run 101 0)"
assert_eq "$(printf '%s' "$out1" | jq -r '.model')" "sonnet" \
  "first-attempt ticket with Model: sonnet → --model sonnet"
assert_eq "$(printf '%s' "$out1" | jq -r '.ticket_model')" "sonnet" \
  "ticket_model observed = sonnet"
assert_eq "$(printf '%s' "$out1" | jq -r '.is_retry')" "0" \
  "first-attempt is_retry=0"
assert_eq "$(printf '%s' "$out1" | jq -r '.model_source')" "ticket-Model-field" \
  "model source = ticket-Model-field"

# 2. Same ticket on RETRY (force flag mirrors the real preserved-worktree signal)
#    → escalate to GOVERN_WORKER_MODEL unconditionally.
out2="$(run 101 1)"
assert_eq "$(printf '%s' "$out2" | jq -r '.model')" "opus" \
  "retry of Model: sonnet ticket → escalates to GOVERN_WORKER_MODEL=opus"
assert_eq "$(printf '%s' "$out2" | jq -r '.is_retry')" "1" \
  "retry is_retry=1"

# 3. No Model: field → unchanged (GOVERN_WORKER_MODEL default).
out3="$(run 102 0)"
assert_eq "$(printf '%s' "$out3" | jq -r '.model')" "opus" \
  "no Model: field → uses GOVERN_WORKER_MODEL (default preserved)"
assert_eq "$(printf '%s' "$out3" | jq -r '.ticket_model')" "" \
  "ticket_model empty when no Model: line"
assert_eq "$(printf '%s' "$out3" | jq -r '.model_source')" "GOVERN_WORKER_MODEL" \
  "model source = GOVERN_WORKER_MODEL when no ticket Model"

# 4. Unknown Model: value → dropped, fall back to GOVERN_WORKER_MODEL, no fatal.
out4="$(run 103 0)"
assert_eq "$(printf '%s' "$out4" | jq -r '.model')" "opus" \
  "unknown Model: value → fail-safe to GOVERN_WORKER_MODEL"
assert_eq "$(printf '%s' "$out4" | jq -r '.ticket_model')" "gpt-nano" \
  "unknown ticket_model still reported in the dry-run output"

# 5. Fenced `Model: haiku` in the body (no leading field) → NOT parsed; routes to
#    GOVERN_WORKER_MODEL. Extraction is anchored to the LEADING field block only, so a
#    Model: line inside a code fence / prose later in the body cannot spoof the routing.
out5="$(run 104 0)"
assert_eq "$(printf '%s' "$out5" | jq -r '.ticket_model')" "" \
  "fenced Model: line in body is NOT parsed as the leading field"
assert_eq "$(printf '%s' "$out5" | jq -r '.model')" "opus" \
  "fenced-Model-only ticket → uses GOVERN_WORKER_MODEL (leading field block empty)"
assert_eq "$(printf '%s' "$out5" | jq -r '.model_source')" "GOVERN_WORKER_MODEL" \
  "model source = GOVERN_WORKER_MODEL when only a fenced Model: appears in body"

assert_done
