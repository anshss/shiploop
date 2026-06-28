#!/usr/bin/env bash
# Regression for ticket #42: when a PR's merge FAILS (conflict / failing required check),
# run-loop must PARK the ticket — keep its tickets.md block, leave the PR open, and file an
# escalation — NOT bookkeep it as "resolved" (which deletes the block while the PR sits unmerged).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
# Hermetic config: the worker reports repo "alpha" — make it auto-mergeable so run-loop reaches the
# await-CI/merge branch (where the gh stub fails the merge) and routes to park, not bookkeep.
mk_ws_stub "$T"

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — high one
**Severity:** High — x.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

# stub gh: `pr list` (resume check) → none; `pr merge` → FAIL (simulate conflict); else pass.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)   echo '[]';;
  *"pr merge"*)  echo 'X Pull request is not mergeable: merge conflict' >&2; exit 1;;
  *)             echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor verdict on the marker, else a worker that resolves with a mergeable-repo PR.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

# NB: GOVERN_ECHO is unset → merge-pr.sh actually runs `gh pr merge` (which the stub fails).
out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$REPO/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$REPO/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$REPO/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 2>&1)"

assert_contains "$out" "parking (ticket NOT deleted)" "merge failure parks instead of resolving (#42)"
assert_contains "$out" "parked=1"                     "#1 counted as parked, not resolved"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "1" "ticket #1 block SURVIVES a failed merge (not deleted)"
commits="$(cd "$T" && git log --oneline 2>/dev/null | grep -c 'resolve #' || true)"
assert_eq "$commits" "0" "no resolve commit for a PR that never merged"
assert_contains "$(cat "$T/governor/escalations.md")" "could not be merged" "an escalation was filed for the unmerged PR"
assert_done
