#!/usr/bin/env bash
# Proof for the #67 validation-evidence gate in run-loop.sh: a validation/spike ticket reported
# `resolved` WITHOUT live-test evidence is downgraded to parked (and kept in tickets.md); one WITH
# evidence resolves normally. Stubbed claude + gh, sandboxed — no auth/network/real mutation.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# #1: validation ticket, worker gives NO evidence → must be parked by the gate.
# #2: validation ticket, worker gives real evidence → must resolve.
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — VALIDATION/SPIKE: does the snapshot capture the full env?
**Severity:** High — gates the pillar.
body1
---
## #2 — VALIDATION/SPIKE: does cross-provider restore work?
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

# stub claude: supervisor → ok verdict; worker → resolved, but #1 has validation:null (no test run)
# while #2 reports a real live-test result.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
val='null'   # #1: no validation evidence (the bug we are guarding against)
if [[ "$n" == "2" ]]; then val='{"required":true,"ranLiveTest":true,"evidence":"deploy ticket-2-x → snapshot s1 → restore on alpha; PASS/FAIL table in PR"}'; fi
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"validation\":${val},\"escalation\":null}"
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
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 2>&1)"

assert_contains "$out" "VALIDATION ticket but the worker gave no live-test evidence" "gate fired on #1 (no evidence)"
assert_contains "$out" "resolved=1 parked=1"  "#2 (with evidence) resolved; #1 (no evidence) parked"
# #1 stays in tickets.md (parked, not bookkept-deleted); #2 is gone (resolved + bookkept)
has1="$(grep -c '^## #1 ' "$T/tickets.md" || true)"
has2="$(grep -c '^## #2 ' "$T/tickets.md" || true)"
assert_eq "$has1" "1" "parked validation #1 remains in tickets.md"
assert_eq "$has2" "0" "evidence-backed validation #2 was resolved + removed"
# the gate must NOT merge/bookkeep #1, so only ONE resolve commit (for #2)
commits="$(cd "$T" && git log --oneline 2>/dev/null | grep -c 'resolve #' || true)"
assert_eq "$commits" "1" "only #2 bookkept; the no-evidence validation #1 was not"
assert_done
