#!/usr/bin/env bash
# Regression for #151: a post-merge prod deploy/verify failure must NOT abort the whole run (set -e on
# an unguarded command-substitution assignment) and mislabel the session "completed normally" while
# leaving the in-flight ticket merged-but-unbookkept AND omitted from the summary.
#
# Reproduces the observed shape: #1's auto-merge-repo PR merges, then the additive-migration
# deploy/verify step FAILS. The run must:
#   1. NOT exit non-zero — the migrate-command capture is guarded (|| true), so control reaches the
#      verify+classify+PARK logic instead of `set -e` aborting at the capture line;
#   2. PARK #1 with an escalation (the PR is merged but the post-merge step failed) — keeping its
#      tickets.md block and recording a `parked` state entry, so it is surfaced, not silently dropped;
#   3. write a summary that lists #1 (no half-resolved ticket left both unbookkept AND unreported).
# Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — additive-migration ticket whose post-merge deploy fails
**Severity:** Medium — x.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'DOC\n' > "$T/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

# stub gh: `pr list` (resume/find-pr) → none; `pr checks` → green; `pr merge` → SUCCESS; else pass.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)    echo '[]';;
  *"pr checks"*)  echo '[{"bucket":"pass"}]';;
  *"pr merge"*)   echo 'merged';  exit 0;;
  *"pr view"*)    echo 'MERGED';  exit 0;;
  *)              echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor verdict on the marker; else a worker that resolves with an auto-merge-repo PR
# AND declares an ADDITIVE prod migration (needed:true, destructive:false) — the path that, post-merge,
# applies the migration + verifies the deploy (the step that fails here).
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":{\"needed\":true,\"destructive\":false,\"name\":\"20260623_add_index\",\"note\":\"CREATE INDEX\"},\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

# GOVERN_MIGRATE_CMD=false → the post-merge migrate-command capture exits NON-ZERO (the #151 failure).
# Pre-fix this aborted the whole script at the unguarded `mout=$(...)` assignment; post-fix the
# `|| true` lets control reach the verify (GOVERN_VERIFY_CMD=false) → PARK.
set +e
out="$(PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_MIGRATE_CMD="false" GOVERN_VERIFY_CMD="false" \
  GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 </dev/null 2>&1)"
rc=$?
set -e

assert_eq "$rc" "0" "run exits 0 — a post-merge deploy/verify failure does NOT abort the loop via set -e (#151 root cause)"
assert_contains "$out" "merged alpha#101"            "the backend/auto-merge PR merged before the deploy step"
assert_contains "$out" "migration/verify FAILED for #1" "the post-merge migrate/verify failure was CLASSIFIED (not a silent abort)"
assert_contains "$out" "parked=1"                    "#1 was PARKED (surfaced), not dropped"

# #1 is half-resolved (PR merged) → its block MUST survive (not bookkept/deleted) and be surfaced.
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "1"                           "ticket #1 block SURVIVES (merged-but-unbookkept, not deleted)"
assert_contains "$(cat "$T/governor/escalations.md")" "### #1"  "an escalation was filed for #1 (surfaced, not silently dropped)"

# The session summary must reflect reality: #1 listed (recorded parked), NOT omitted.
SUM="$T/logs/last-session.md"
[[ -f "$SUM" ]] || SUM="$(ls -t "$T"/logs/run-*/summary.md 2>/dev/null | head -1)"
assert_contains "$(cat "$SUM")" "#1: parked"         "summary names #1 (no in-flight ticket silently omitted) (#151)"

assert_done
