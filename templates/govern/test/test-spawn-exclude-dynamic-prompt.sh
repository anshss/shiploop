#!/usr/bin/env bash
# Locks in `--exclude-dynamic-system-prompt-sections` on the worker spawn (moves per-machine
# system-prompt sections — cwd, env info, memory paths, git status — into the first user
# message, improving cross-worker prompt-cache reuse since this spawn never passes
# --system-prompt / --append-system-prompt):
#   1. Default (no override) → flag IS present.
#   2. GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag is ABSENT (kill switch).
#   3. `--forward-subagent-text` (forwards subagent text+thinking into the parent — the OPPOSITE
#      of what we want) must NEVER appear in spawn-worker.sh, regression-locked by source scan.
#
# Uses GOVERN_SPAWN_DRY_RUN=1 to short-circuit BEFORE worktree creation / worker launch — pure
# observation of the assembled invocation params. No auth, no claude binary, no state on disk
# beyond the tmp workspace.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #301 — sample ticket
**Severity:** Medium
Observed: bare ticket, exercises the default spawn flags.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

run() { # ticket-N [GOVERN_EXCLUDE_DYNAMIC_PROMPT]
  local n="$1" edp="${2:-unset}"
  if [[ "$edp" == "unset" ]]; then
    GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs-$n-$edp" \
      GOVERN_WORKER_MODEL="opus" \
      GOVERN_SPAWN_DRY_RUN=1 \
      "$SPAWN" "$n"
  else
    GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs-$n-$edp" \
      GOVERN_WORKER_MODEL="opus" \
      GOVERN_SPAWN_DRY_RUN=1 \
      GOVERN_EXCLUDE_DYNAMIC_PROMPT="$edp" \
      "$SPAWN" "$n"
  fi
}

# 1. Default (no override) → flag present.
out1="$(run 301)"
assert_eq "$(printf '%s' "$out1" | jq -r '.exclude_dynamic_prompt')" \
  "--exclude-dynamic-system-prompt-sections" \
  "default → --exclude-dynamic-system-prompt-sections present"

# 2. GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag absent (kill switch).
out2="$(run 301 0)"
assert_eq "$(printf '%s' "$out2" | jq -r '.exclude_dynamic_prompt')" "" \
  "GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag absent"

# 3. GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 (explicit on) → same as default.
out3="$(run 301 1)"
assert_eq "$(printf '%s' "$out3" | jq -r '.exclude_dynamic_prompt')" \
  "--exclude-dynamic-system-prompt-sections" \
  "GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 → flag present"

# 4. Regression lock: --forward-subagent-text (forwards subagent text+thinking into the
#    parent — the opposite of the token-efficiency goal) must never be introduced into the
#    spawn script.
if grep -qF -- '--forward-subagent-text' "$SPAWN"; then
  printf 'FAIL - %s\n' "--forward-subagent-text must never appear in spawn-worker.sh"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "--forward-subagent-text absent from spawn-worker.sh"
fi

assert_done
