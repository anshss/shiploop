#!/usr/bin/env bash
# #94/#40 — RUN-END BLOCKS FIRE ONCE PER DISPATCH, in the orchestrator.
#
# Every run-end block is a WHOLE-DISPATCH pass over shared state: the pending-escalations emit, the
# self-improvement review, the health ROI line, the sync-port trigger, the orphan reap and the
# validations-pending adopt. Firing them per DRIVER made an N-way run file N near-identical
# self-improvement tickets over N slices of the same run (#75 and #76 are one wall-clock run, two
# drivers, two duplicates). Proven here two ways, because either alone is weak:
#
#   A. BEHAVIOURAL: under --parallel every child logs that it skipped the run-end blocks, and the
#      orchestrator does not. One dispatch, one pass, whatever the fan-out.
#   B. STRUCTURAL: every run-end block in run-loop.sh is actually guarded by $RUN_END. A behavioural
#      test alone would pass if someone added a NEW unguarded block tomorrow.
#   C. A sequential dispatch IS the orchestrator: it never skips, and takes the same path as before.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_fixture() { # <T>
  local T="$1"
  mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt" "$T/scripts/lib"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
META_NAME="testws"
ROOT_PM="npm"
GITHUB_ORG="acme"
REPOS=(alpha)
REPO_CMDS=("npm run dev")
REPO_PORTS=(3000)
SLOT_PORT_STEP=10
WORKTREE_BASE="\${WORKTREE_BASE:-$T/.wt}"
GOVERN_MERGE_REPOS=(alpha)
GOVERN_WORKER_MODEL="\${GOVERN_WORKER_MODEL:-opus}"
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
  printf 'worker prompt {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
  printf 'doctrine\n' > "$T/governor/preferences.md"
  cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
  chmod +x "$T/wt.sh"
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$T/bin/gh"
  cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s\n---\n' "\$prompt" >> "$T/prompts.txt"
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"tickets":[],"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
}
mk_fixture "$T"
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — one area
**Severity:** High. x.

**Files:** alpha/one.ts
---
## #2 — another area
**Severity:** High. y.

**Files:** alpha/two.ts
---
EOF

run_driver() {
  rm -f "$T/prompts.txt"; rm -rf "$T/logs"; mkdir -p "$T/logs"
  env GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_WORKTREE_CMD="$T/wt.sh" GOVERN_CLAUDE_BIN="$T/bin/claude" \
    GOVERN_SETTING_SOURCES=user GOVERN_WORKER_TIMEOUT=60 GOVERN_PARALLEL_STAGGER_S=0 \
    PATH="$T/bin:$PATH" bash "$RL" --dry-run "$@" 2>&1 || true
}

SKIPLINE="run-end blocks: skipped"

# ── A — one dispatch, one run-end pass ─────────────────────────────────────────────────────────
logA="$(run_driver --parallel=2 1 2)"
assert_contains "$logA" "parallel: spawned #1" "A1: the orchestrator fanned out"
assert_contains "$logA" "parallel: spawned #2" "A2: …two children, one per locality group"
skips="$(grep -c "$SKIPLINE" <<<"$logA" || true)"
assert_eq "$skips" "2" "A3: BOTH children skip the run-end blocks (one pass per dispatch, not per driver)"
assert_contains "$logA" "the orchestrator runs them once for the whole dispatch" \
  "A4: …and say why, so the absence is never mistaken for a bug"
# The orchestrator's own DONE line lands AFTER the children were reaped, and it is the run-end
# section that emits it, so the parent reached the run-end blocks itself.
assert_contains "$logA" "parallel run done: 2 driver(s)" "A5: the orchestrator reaped both children"

# ── B — every run-end block is guarded ─────────────────────────────────────────────────────────
src="$(cat "$RL")"
assert_contains "$src" 'RUN_END=1' "B1: run-loop defines the run-end guard"
assert_contains "$src" 'if [[ "$ORCHESTRATED" -eq 1 ]]; then
  RUN_END=0' "B2: …cleared for a child driver"
for probe in \
  'if [[ "$RUN_END" -eq 1 ]]; then
  govern::_improve_final' \
  'if [[ "$RUN_END" -eq 1 && "$MODE" == "live" ]]; then
  "$DIR/escalations-emit-pending.sh"' \
  'if [[ "$RUN_END" -eq 1 && -x "$DIR/govern-health.sh"' \
  'if [[ "$RUN_END" -eq 1 && "$MODE" == "live" && -f "$DIR/../reap-orphan-deploys.sh" ]]' \
  'if [[ "$RUN_END" -eq 1 && "$MODE" == "live" && -f "$DIR/validations-pending-apply.sh" ]]' \
  'if [[ "$RUN_END" -eq 1 \'
do
  assert_contains "$src" "$probe" "B3: run-end block guarded: ${probe%%$'\n'*}"
done
# No supervisor is left on the dispatch path at all: it costs zero unless invoked by hand.
if printf '%s' "$src" | grep -q 'govern-supervise.sh'; then f=1; else f=0; fi
assert_eq "$f" "0" "B4: run-loop.sh never invokes govern-supervise.sh (manual audit only)"

# ── C — a sequential dispatch IS the orchestrator ──────────────────────────────────────────────
logC="$(run_driver --serial 1)"
if printf '%s' "$logC" | grep -qF "$SKIPLINE"; then f=1; else f=0; fi
assert_eq "$f" "0" "C1: a sequential dispatch never skips its run-end blocks"
assert_contains "$logC" "DONE — resolved=" "C2: …and ends on the canonical DONE line"

assert_done
