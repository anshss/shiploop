#!/usr/bin/env bash
# Proves the #67 VALIDATION-EVIDENCE gate fires under HEADING WHITESPACE / PUNCTUATION variance.
# Previously the gate awk required exactly `## #N ` (single space), so a ticket whose heading
# was `##  #N` (double-space) or `## #N—Title` (em-dash with no space between `#N` and title)
# yielded an empty tblock — the VALIDATION|SPIKE grep then missed, and a validation ticket
# auto-resolved on static code analysis with no live-test evidence, defeating the gate. The fix
# routes the gate through the shared tolerant parser (govern::ticket_block).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# #1: heading has DOUBLE-SPACE after `##` (`##  #1`) — a common markdown-formatter drift.
# #2: heading has EM-DASH glued to the number (`## #2—…`) — no space between `#2` and `—`.
# Both are validation tickets; the worker reports resolved WITHOUT live-test evidence. If the
# gate parses each block, both must be downgraded to parked. If the strict old regex is used,
# both empty-block through the gate and get bookkept as resolved (the bug).
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
##  #1 — VALIDATION/SPIKE: double-space heading trap
**Severity:** High — gates the pillar.
body1
---
## #2—VALIDATION/SPIKE: em-dash glued to number
**Severity:** High — gates the pillar.
body2
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
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor → ok; worker → resolved with validation:null (no evidence at all,
# exactly the bug the gate exists to catch). If the gate is bypassed on either ticket, its
# resolve will bookkeep the delete + a resolve commit will land.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"validation\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

[[ -n "${GOVERN_PROMPTS_DIR:-}" ]] || { echo "SKIP - GOVERN_PROMPTS_DIR unresolved"; exit 0; }
out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 2>&1)"

# Both tickets should be parked by the gate (no live-test evidence + validation-shaped title).
# The gate must fire on BOTH heading variants. If either variant is missed, that ticket
# resolves+bookkeeps and its block leaves tickets.md.
assert_contains "$out" "resolved=0 parked=2" "both heading-variant validation tickets parked by the gate"

# Both blocks must SURVIVE in tickets.md (parked, not bookkept-deleted).
h1="$(grep -cE '^##  +#1 ' "$T/tickets.md" || true)"
h2="$(grep -cE '^## #2—' "$T/tickets.md" || true)"
assert_eq "$h1" "1" "double-space heading #1 remains in tickets.md (gate did NOT skip it)"
assert_eq "$h2" "1" "em-dash-glued heading #2 remains in tickets.md (gate did NOT skip it)"

# No resolve commit at all — the gate stopped both bookkeeps.
commits="$(cd "$T" && git log --oneline 2>/dev/null | grep -c 'resolve #' || true)"
assert_eq "$commits" "0" "no resolve commit — no validation ticket slipped past the gate"

assert_done
