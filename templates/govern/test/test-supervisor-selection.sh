#!/usr/bin/env bash
# #92 — proves the supervisor's advice changes SELECTION, not just the log:
#   (1) a bold "NOT govern-automatable" ticket is auto-skipped (no worker burned, logged why);
#   (2) an `attemptNext` recommendation pulls a lower-priority ticket to the FRONT of selection;
#   (3) supervisor concerns are surfaced into pending-escalations.json at run-end.
# Stubbed Claude (worker + supervisor) + gh; sandboxed, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# #1,#2 High; #3 Low (normal order: 1,2,3). #4 is bold-marked NOT-automatable.
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — high one
**Severity:** High — x.
body1
---
## #2 — high two
**Severity:** High — y.
body2
---
## #3 — low one
**Severity:** Low — z.
body3
---
## #4 — high but web-UI only
**Severity:** High — needs GitHub Actions web UI.
**NOT govern-automatable (supervisor):** headless worker can't read web-UI logs. Handle interactively.
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

# supervisor: every review → recommend attemptNext #3 (pull the LOW ticket ahead of high #2) + a
# concern. worker: resolves whatever ticket it's handed.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"concerns","concerns":["#3 unblocked — attempt now"],"skipThisRun":[],"attemptNext":[3],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_PENDING_FILE="$T/governor/pending-escalations.json" \
  GOVERN_WORKER_PROMPT_FILE="$REPO/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$REPO/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$REPO/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_NA_SKIP_FILE="$T/governor/na-skip-counts.json" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_SUPERVISOR_EVERY=1 GOVERN_IMPROVE=0 \
  bash "$RL" 2>&1)"

# (1) NOT-automatable #4 auto-skipped + logged, never worked.
assert_contains "$out" "auto-skipping #4" "bold NOT-automatable #4 is auto-skipped + logged (#92)"

# (2) attemptNext pulls #3 ahead of #2: ticket-start order must be 1, 3, 2 (not 1, 2, 3).
order="$(printf '%s' "$out" | grep -oE '=== ticket #[0-9]+' | grep -oE '[0-9]+' | tr '\n' ',' )"
assert_eq "$order" "1,3,2," "attemptNext pulled low #3 ahead of high #2 (selection changed, #92)"
assert_contains "$out" "attempting #3 now (prioritized" "priority pick logged for #3 (#92)"

# resolved = the 3 automatable tickets; #4 stays in tickets.md (skipped, not worked).
assert_contains "$out" "resolved=3" "exactly the 3 automatable tickets resolved"
remaining="$(grep -cE '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "1" "only the NOT-automatable #4 remains in tickets.md"

# (3) supervisor concerns surfaced to the relay at run-end.
concern="$(jq -r '.supervisorConcerns | join(" ")' "$T/governor/pending-escalations.json" 2>/dev/null || true)"
assert_contains "$concern" "#3 unblocked" "supervisor concern surfaced into pending-escalations.json (#92)"

assert_done
