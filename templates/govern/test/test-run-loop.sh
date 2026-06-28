#!/usr/bin/env bash
# End-to-end orchestration proof for run-loop.sh with stubbed Claude (worker + supervisor) and
# stubbed gh. No real auth, no network, no real repo mutation — everything in a sandbox.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
# Hermetic config: the worker reports repo "alpha", so make it auto-mergeable (the additive-migration
# auto-apply lives in the merge branch). Independent of the live workspace's allowlist.
mk_ws_stub "$T"

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — high one
**Severity:** High — x.
body1
---
## #2 — medium one
**Severity:** Medium — y.
body2
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

# stub gh: `pr list` (resume check) → none; `pr checks` → all pass
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor (verdict) if prompt has the marker, else worker (writes report file)
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
nt='[]'; mig='null'
if [[ "$n" == "1" ]]; then nt='[{"title":"spawned followup","severity":"Low","body":"**Where:** z"}]'; mig='{"needed":true,"destructive":false,"name":"add_x","note":"ADD COLUMN x"}'; fi
if [[ "$n" == "2" ]]; then mig='{"needed":true,"destructive":true,"name":"drop_y","note":"DROP COLUMN y"}'; fi
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":${nt},\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":${mig},\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$REPO/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$REPO/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$REPO/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=1 GOVERN_IMPROVE=0 \
  GOVERN_MIGRATE_CMD="touch $T/migrated" GOVERN_VERIFY_CMD="true" \
  bash "$RL" 2>&1)"

assert_contains "$out" "resolved=2 parked=1"  "additive #1 + spawned #3 resolved; destructive #2 parked"
assert_contains "$out" "DESTRUCTIVE"          "destructive migration on #2 caught — NOT auto-merged"
assert_contains "$out" "supervisor review"    "supervisor fired (every-1 cadence)"
mr=no; [ -f "$T/migrated" ] && mr=yes
assert_eq "$mr" "yes" "additive prod migration applied (GOVERN_MIGRATE_CMD ran) for #1"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "1" "only the parked #2 remains in tickets.md"
commits="$(cd "$T" && git log --oneline | grep -c 'resolve #' || true)"
assert_eq "$commits" "2" "2 resolve commits (#1,#3); destructive #2 parked, not bookkept"
assert_done
