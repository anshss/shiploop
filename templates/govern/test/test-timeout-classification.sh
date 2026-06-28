#!/usr/bin/env bash
# #241 regression: a validation worker HARD-KILLED by GOVERN_WORKER_TIMEOUT before it could write its
# verdict must NOT be recorded as `failed` (which masks a possibly-working feature as broken) — it is
# a DISTINCT `timeout` (incomplete, re-run) outcome. And a resolved VALIDATION ticket's state.jsonl
# note must carry its evidence path (the #231 "empty note despite real evidence" gap). Hermetic +
# generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ── Part 1 — spawn-worker.sh: kill-before-verdict → status:"timeout", not "failed". ──
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"
cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample validation ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
printf 'DOCTRINE-MARKER\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude that NEVER finishes (sleeps past the 1s timeout) and writes NO report file — exactly the
# kill-before-verdict shape: the watchdog TERM/KILLs it (rc>128 → worker_killed=1).
cat > "$TMP/fake-claude-hang.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$TMP/fake-claude-hang.sh"

out="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-hang.sh" \
  GOVERN_WORKER_TIMEOUT=1 \
  "$SPAWN" 7 </dev/null)"

assert_eq "$(printf '%s' "$out" | jq -r '.status')" "timeout" "killed-before-verdict → status:timeout (NOT failed) [#241]"
assert_contains "$out" "INCOMPLETE" "timeout report explains it is incomplete, not a genuine failure"

# ── Part 2 — run-loop.sh classifies a timeout worker as `timeout` (not `failed`), preserves the ──
#    worktree, and a resolved validation ticket's note carries evidence.
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — VALIDATION: does the deploy flow work
**Severity:** Medium — live-verify.
body1
---
## #2 — VALIDATION: snapshot/restore spike
**Severity:** Medium — live-verify.
body2
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

# stub gh: resume `pr list` → none; checks → pass
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude:
#   supervisor → ok verdict.
#   worker #1 → resolved validation ticket WITH evidence (ranLiveTest=true).
#   worker #2 → hang forever (no report) → watchdog kills it → timeout.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
# hang → kill-before-verdict. `exec sleep` so the watchdog's TERM kills THIS process (exit 143>128 →
# worker_killed), modelling a real worker hard-killed mid-run; a plain `sleep; exit 0` would mask the
# kill (bash would run `exit 0` after the killed sleep and report rc=0).
if [[ "$n" == "2" ]]; then exec sleep 30; fi
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"validation":{"required":true,"ranLiveTest":true,"evidence":"deploy 2999 service HTTP 200; report.json at logs/investigations/t1/REPORT.md"},"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out2="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_WORKER_TIMEOUT=1 \
  bash "$RL" </dev/null 2>&1)"

# locate the run's state.jsonl
state="$(ls -t "$T"/logs/run-*/state.jsonl | head -1)"

s1="$(jq -r 'select(.ticket==1) | .status' "$state")"
s2="$(jq -r 'select(.ticket==2) | .status' "$state")"
assert_eq "$s1" "resolved" "validation #1 with live evidence → resolved"
assert_eq "$s2" "timeout"  "killed-before-verdict #2 → recorded timeout (NOT failed) [#241]"

note1="$(jq -r 'select(.ticket==1) | .note' "$state")"
assert_contains "$note1" "validation evidence: deploy 2999" "resolved validation note carries its evidence path [#231/#241]"

assert_contains "$out2" "timed-out=1" "DONE summary counts the timeout distinctly from failed"
assert_contains "$out2" "failed=0"    "a kill-before-verdict is NOT counted as a failure"

# cross-run history records #2 as `timeout` (so consecutive_fails counts it for #60 auto-escalate)
assert_eq "$(jq -r 'select(.ticket==2) | .status' "$T/history.jsonl")" "timeout" "history records #2 as timeout (feeds #60 streak, not as failed)"

# the timed-out worktree is PRESERVED (re-run resumes); wt teardown is a no-op under GOVERN_WORKTREE_CMD.
[[ -d "$T/wt/ticket-2" ]] && wp=yes || wp=no
assert_eq "$wp" "yes" "timed-out ticket's worktree preserved for resume"

rm -rf "$T"
assert_done
