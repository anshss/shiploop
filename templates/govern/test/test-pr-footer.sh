#!/usr/bin/env bash
# Onboarding mechanisms: the viral PR footer (WSP_PR_FOOTER) and the observe-mode DRAFT-PR
# instruction (GOVERN_AUTONOMY=observe) are injected into the worker prompt by spawn-worker.sh.
# Both are pure prompt-assembly seams, so we capture the assembled prompt via a fake `claude`
# (the same seam test-spawn-worker.sh uses) and assert the lines appear / disappear per knob.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"  # hermetic stub — sets NEITHER WSP_PR_FOOTER nor GOVERN_AUTONOMY (the unset case)
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
printf 'DOCTRINE-MARKER\n' > "$TMP/governor/preferences.md"
printf 'PROMPT-HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude: capture the assembled prompt (arg after -p) to a per-invocation sink, then emit a
# minimal resolved report so spawn-worker exits cleanly.
cat > "$TMP/fake-claude.sh" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" > "\${PROMPT_SINK:?}"
report='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

run_spawn() { # <sink> [env assignments...]  — invokes spawn-worker for ticket 7, prompt → <sink>
  local sink="$1"; shift
  env "$@" \
    PROMPT_SINK="$sink" \
    GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs-$(basename "$sink")" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
    "$SPAWN" 7 >/dev/null
}

FOOTER='shipped by [shiploop](https://github.com/anshss/shiploop)'
DRAFT='open your PR as a DRAFT'

# 1. Knob UNSET (default) → footer present, no draft instruction (autonomy defaults to auto).
run_spawn "$TMP/p-default.txt"
seen="$(cat "$TMP/p-default.txt")"
assert_contains "$seen" "$FOOTER"       "footer present when WSP_PR_FOOTER unset (on by default)"
assert_contains "$seen" "DOCTRINE-MARKER" "doctrine still appended (assembly intact)"
if grep -qF "$DRAFT" <<<"$seen"; then
  printf 'FAIL - %s\n' "no draft instruction when autonomy unset (auto)"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "no draft instruction when autonomy unset (auto)"; fi

# 2. WSP_PR_FOOTER=off → footer absent.
run_spawn "$TMP/p-off.txt" WSP_PR_FOOTER=off
seen_off="$(cat "$TMP/p-off.txt")"
if grep -qF "$FOOTER" <<<"$seen_off"; then
  printf 'FAIL - %s\n' "footer suppressed when WSP_PR_FOOTER=off"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "footer suppressed when WSP_PR_FOOTER=off"; fi

# 3. GOVERN_AUTONOMY=observe → draft-PR instruction present (footer still on).
run_spawn "$TMP/p-observe.txt" GOVERN_AUTONOMY=observe
seen_obs="$(cat "$TMP/p-observe.txt")"
assert_contains "$seen_obs" "$DRAFT"  "draft-PR instruction present in observe mode"
assert_contains "$seen_obs" "$FOOTER" "footer still present in observe mode"

# 4. GOVERN_AUTONOMY=pr-only → NO draft instruction (only observe drafts).
run_spawn "$TMP/p-pronly.txt" GOVERN_AUTONOMY=pr-only
seen_pro="$(cat "$TMP/p-pronly.txt")"
if grep -qF "$DRAFT" <<<"$seen_pro"; then
  printf 'FAIL - %s\n' "no draft instruction in pr-only mode (only observe drafts)"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "no draft instruction in pr-only mode (only observe drafts)"; fi

assert_done
