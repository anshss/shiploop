#!/usr/bin/env bash
# Fail-closed CI verification (companion to #34b / #42): when a resolved ticket's PR is on a
# merge-repo but its CI state cannot be VERIFIED (gh network/auth/rate-limit/5xx — await-ci returns
# 'error'), run-loop must PARK the ticket (keep its block, leave the PR open, escalate) and NEVER
# merge blind. This is the regression guard for the pre-fix fail-OPEN where a broken gh looked
# identical to a checkless repo (`… || echo '[]'`) and auto-merged an un-verified PR.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

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

# stub gh: `pr list` (resume/discovery) → none; `pr checks` → ERROR (exit 1, no JSON — models a
# gh/GitHub API failure); else pass. await-ci must therefore conclude 'error', NOT 'none'.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)   echo '[]';;
  *"pr checks"*) exit 1;;
  *"pr merge"*)  echo 'MERGED (should never happen for unverifiable CI)'; exit 0;;
  *)             echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor verdict on the marker, else a worker that resolves with a merge-repo PR
# on `alpha` (the mk_ws_stub allowlist default).
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

# NB: GOVERN_SKIP_CI is UNSET → merge_pr_for_ticket runs the real await-ci (which errors here).
# GOVERN_CI_ERR_MAX=1 / GRACE=0 keep the error conclusion instant. GOVERN_CI_FIX_TRIES=0 so an
# 'error' never triggers a CI-fix re-dispatch loop. Governor prompt files come from the
# assert.sh-resolved template governor dir (see GOVERN_PROMPTS_DIR).
[[ -n "${GOVERN_PROMPTS_DIR:-}" ]] || { echo "SKIP - GOVERN_PROMPTS_DIR unresolved"; exit 0; }
out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_CI_ERR_MAX=1 GOVERN_CI_NONE_GRACE=0 GOVERN_CI_FIX_TRIES=0 \
  GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 2>&1)"

assert_contains "$out" "CI state unverifiable"           "unverifiable CI is detected + logged"
assert_contains "$out" "parking (ticket NOT deleted)"    "unverifiable CI parks instead of resolving"
assert_contains "$out" "parked=1"                        "#1 counted as parked, not resolved"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "1" "ticket #1 block SURVIVES unverifiable CI (not deleted)"
commits="$(cd "$T" && git log --oneline 2>/dev/null | grep -c 'resolve #' || true)"
assert_eq "$commits" "0" "no resolve commit for a PR whose CI was never verified"
merged_attempted="$(grep -c 'should never happen for unverifiable CI' <<<"$out" || true)"
assert_eq "$merged_attempted" "0" "gh pr merge was NEVER invoked on unverifiable CI (fail closed)"
assert_contains "$(cat "$T/governor/escalations.md")" "could not be verified" "escalation filed for the unverified PR"
assert_done
