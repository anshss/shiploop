#!/usr/bin/env bash
# Regression for ticket #104: the per-ticket CLAIM lock (governor/.locks/ticket-N) must be taken
# in DRY mode too — not just live. Before the fix it was gated on MODE==live, so a dry run never
# acquired it and you could NOT rehearse the "no two drivers work the same ticket" safety net
# without going live (opening real PRs). The lock acquire/release is a pure mkdir/rmdir, so taking
# it in dry mode is side-effect-free and lets two concurrent dry drivers faithfully contend.
#
# Proves three things with stubbed claude/gh (no auth, no network, no real repo mutation):
#   A. a HELD claim (a peer driver's lock) makes a DRY driver SKIP that ticket and move to the
#      next — i.e. the lock is consulted in dry mode (the exact behavior the live-only gate hid).
#   B. two CONCURRENT dry drivers on the SAME single-ticket backlog (no --exclude) contend on the
#      lock so the ticket is claimed exactly once — the literal "Done when" of #104.
#   C. wiring: run-loop's claim is no longer guarded by MODE=="live".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt" "$T/scripts/lib"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
# The drivers run under GOVERN_WS_ROOT="$T", so common.sh sources $T/scripts/lib/workspace.sh.
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
printf 'worker prompt {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'doctrine\n' > "$T/governor/preferences.md"

# worktree stub: just make + echo a dir (no real worktree). The claim lock stays active even with
# this set — #104 dropped the GOVERN_WORKTREE_CMD guard on the claim too, so the lock is testable
# through the same stub harness every other run-loop test uses.
cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

# stub gh: resume check → no PR; anything else → passing checks (dry never merges anyway).
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude worker: optionally sleep (so a concurrent peer overlaps the lock-hold window), then
# write a resolved report. Sleep is opt-in via GOVERN_TEST_WORKER_SLEEP to keep Part A fast.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
[[ -n "${GOVERN_TEST_WORKER_SLEEP:-}" ]] && sleep "$GOVERN_TEST_WORKER_SLEEP"
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

run_env() { # extra env... -> exports a base env for a dry driver
  GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_SETTING_SOURCES=user GOVERN_WORKER_TIMEOUT=60 GOVERN_SUPERVISOR_EVERY=99 \
  GOVERN_MAX_TICKETS=1 \
  PATH="$T/bin:$PATH" "$@"
}

# ── Part A — a held claim makes a DRY driver skip the ticket (lock IS consulted in dry mode) ──
mkdir -p "$T/governor/.locks"
mkdir "$T/governor/.locks/ticket-1"   # stand in for a concurrent peer driver already holding #1
logA="$T/driverA.log"
run_env bash "$RL" --dry-run >/dev/null 2>"$logA" || true
rmdir "$T/governor/.locks/ticket-1" 2>/dev/null || true

assert_contains "$(cat "$logA")" "#1 already claimed by another driver" "A: dry driver SEES the held claim lock (not live-gated)"
assert_contains "$(cat "$logA")" "=== ticket #2"                        "A: dry driver moves on and works the free ticket #2"
if grep -q "=== ticket #1 " "$logA"; then f=1; else f=0; fi
assert_eq "$f" "0" "A: dry driver NEVER processes the already-claimed #1"

# ── Part B — two concurrent dry drivers on one shared ticket claim it exactly once ──
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — high one
**Severity:** High — x.
body1
---
EOF
logB1="$T/B1.log"; logB2="$T/B2.log"
run_env env GOVERN_ALLOW_CONCURRENT=1 GOVERN_TEST_WORKER_SLEEP=2 bash "$RL" --dry-run >/dev/null 2>"$logB1" &
p1=$!
run_env env GOVERN_ALLOW_CONCURRENT=1 GOVERN_TEST_WORKER_SLEEP=2 bash "$RL" --dry-run >/dev/null 2>"$logB2" &
p2=$!
wait "$p1"; wait "$p2"

claims=$(grep -h "=== ticket #1 " "$logB1" "$logB2" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$claims" "1" "B: two concurrent dry drivers claim the SHARED ticket #1 exactly once"
if grep -q "#1 already claimed by another driver" "$logB1" "$logB2"; then f=1; else f=0; fi
assert_eq "$f" "1" "B: the losing driver visibly contends on .locks/ticket-1 (logs 'already claimed')"

# ── Part C — wiring: the claim is no longer gated on MODE=="live" ──
claim_line="$(grep -n 'govern::lock_try "\$CUR_CLAIM"' "$RL" | head -1)"
assert_contains "$claim_line" "lock_try" "C: run-loop still takes the per-ticket claim lock"
if printf '%s' "$claim_line" | grep -q 'MODE" == "live"'; then f=1; else f=0; fi
assert_eq "$f" "0" "C: the claim's live-only gate is gone (dry runs acquire it too)"

assert_done
