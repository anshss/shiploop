#!/usr/bin/env bash
# #242 regression: stopping/killing the run-loop or a worker must leave ZERO surviving
# spawn-worker / claude children. Before the fix, SIGTERM on the driver left its spawn-worker.sh +
# child `claude -p` (and tool grandchildren) ALIVE — reparented to init, needing a manual `kill -9`
# sweep; a worker orphaned mid-task could keep holding a billable resource. The fix runs the worker
# `claude` in its OWN process group and installs INT/TERM/EXIT traps (spawn-worker + run-loop) that
# tear the whole subtree down on stop. Hermetic + generic (alpha auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
RL="$DIR/../run-loop.sh"

# A live-process assertion: pid file exists, recorded pid is NOT alive.
assert_dead() { # pidfile message
  local p; p="$(cat "$1" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then printf 'FAIL - %s\n       no pid recorded in %s (worker never started?)\n' "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); return; fi
  if kill -0 "$p" 2>/dev/null; then printf 'FAIL - %s\n       pid %s still ALIVE\n' "$2" "$p"; ASSERT_FAILS=$((ASSERT_FAILS+1)); kill -KILL "$p" 2>/dev/null || true
  else printf 'ok   - %s\n' "$2"; fi
}
wait_file() { # path timeout_2s_units
  local i=0; while [[ ! -s "$1" && "$i" -lt "${2:-50}" ]]; do sleep 0.2; i=$((i+1)); done; }
wait_gone() { # pid timeout_2s_units
  local i=0; while kill -0 "$1" 2>/dev/null && [[ "$i" -lt "${2:-100}" ]]; do sleep 0.2; i=$((i+1)); done; }

# ── Unit: govern::kill_tree / _kill_tree_walk reap a whole process subtree ──
T0="$(mktemp -d)"; mk_ws_stub "$T0"; source "$DIR/../lib/common.sh"
mkdir -p "$T0/marks"
# Spawn a leader under set -m (its own group) that forks a grandchild; both sleep far past teardown.
cat > "$T0/tree.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$T0/marks/leader.pid"
( echo \$\$ > "$T0/marks/grand.pid"; exec sleep 300 ) &
sleep 300
EOF
chmod +x "$T0/tree.sh"
set -m; ( exec "$T0/tree.sh" ) & lead=$!; set +m
wait_file "$T0/marks/grand.pid" 50
grand="$(cat "$T0/marks/grand.pid" 2>/dev/null || true)"
if kill -0 "$lead" 2>/dev/null && [[ -n "$grand" ]] && kill -0 "$grand" 2>/dev/null; then
  printf 'ok   - kill_tree: leader+grandchild tree is up before teardown\n'
else printf 'FAIL - kill_tree: tree never came up\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
govern::kill_tree "$lead" 3
wait_gone "$lead" 50; [[ -n "$grand" ]] && wait_gone "$grand" 50
assert_dead "$T0/marks/leader.pid" "kill_tree reaps the process-group leader"
assert_dead "$T0/marks/grand.pid"  "kill_tree reaps the GRANDCHILD (subtree teardown) [#242]"
rm -rf "$T0"

# ── End-to-end: SIGTERM the spawn-worker → claude + grandchild torn down ──
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -f "$TMP/fake-claude" 2>/dev/null || true' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt" "$TMP/marks"
printf '## #7 — sample\n**Severity:** Medium.\n---\n' > "$TMP/tickets.md"
printf 'DOC\n' > "$TMP/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"
cat > "$TMP/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/wt.sh"

# Fake claude modelling a real worker tree: records its own pid, forks a long-lived GRANDCHILD (a
# tool/deploy child) recording ITS pid, then sleeps far past teardown. An orphaned grandchild is the
# #242 leak.
cat > "$TMP/fake-claude" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$TMP/marks/claude.pid"
( echo \$\$ > "$TMP/marks/grandchild.pid"; exec sleep 300 ) &
sleep 300
EOF
chmod +x "$TMP/fake-claude"

GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs" \
  GOVERN_WORKTREE_CMD="$TMP/wt.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude" \
  GOVERN_WORKER_TIMEOUT=120 \
  "$SPAWN" 7 >/dev/null 2>&1 </dev/null &
sw_pid=$!
wait_file "$TMP/marks/grandchild.pid" 50
[[ -s "$TMP/marks/claude.pid" ]] && cpid="$(cat "$TMP/marks/claude.pid")" || cpid=""
gpid="$(cat "$TMP/marks/grandchild.pid" 2>/dev/null || true)"
if [[ -n "$cpid" ]] && kill -0 "$cpid" 2>/dev/null; then printf 'ok   - worker claude tree is up before signal\n'; else printf 'FAIL - worker claude never came up\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

kill -TERM "$sw_pid" 2>/dev/null || true     # signal the worker (as run-loop's trap forwards on stop)
wait_gone "$sw_pid" 100
[[ -n "$cpid" ]] && wait_gone "$cpid" 100
[[ -n "$gpid" ]] && wait_gone "$gpid" 100

if kill -0 "$sw_pid" 2>/dev/null; then printf 'FAIL - spawn-worker.sh survived its own SIGTERM\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); kill -KILL "$sw_pid" 2>/dev/null || true
else printf 'ok   - spawn-worker.sh exits on SIGTERM\n'; fi
assert_dead "$TMP/marks/claude.pid"     "SIGTERM to worker → child claude killed (no orphan) [#242]"
assert_dead "$TMP/marks/grandchild.pid" "SIGTERM to worker → GRANDCHILD killed (process-group teardown) [#242]"

# ── End-to-end: SIGTERM the DRIVER (run-loop) → its spawn-worker + claude tree torn down ──
T="$(mktemp -d)"; mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt" "$T/marks"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — long-running worker
**Severity:** High — x.
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
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor → ok; worker → record pids, fork a grandchild, hang.
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
if printf '%s' "\$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "\$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
echo \$\$ > "$T/marks/claude.pid"
( echo \$\$ > "$T/marks/grandchild.pid"; exec sleep 300 ) &
sleep 300
EOF
chmod +x "$T/bin/claude"

PATH="$T/bin:$PATH" \
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
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_WORKER_TIMEOUT=120 \
  bash "$RL" 1 >"$T/loop.out" 2>&1 </dev/null &
rl_pid=$!

wait_file "$T/marks/grandchild.pid" 80
cpid="$(cat "$T/marks/claude.pid" 2>/dev/null || true)"
gpid="$(cat "$T/marks/grandchild.pid" 2>/dev/null || true)"
if [[ -n "$cpid" ]] && kill -0 "$cpid" 2>/dev/null; then printf 'ok   - driver spawned a live worker tree before stop\n'; else printf 'FAIL - driver never spawned a worker tree\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi

kill -TERM "$rl_pid" 2>/dev/null || true     # stop: signal ONLY the driver pid (the #242 scenario)
wait_gone "$rl_pid" 150
[[ -n "$cpid" ]] && wait_gone "$cpid" 150
[[ -n "$gpid" ]] && wait_gone "$gpid" 150

if kill -0 "$rl_pid" 2>/dev/null; then printf 'FAIL - run-loop survived SIGTERM\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); kill -KILL "$rl_pid" 2>/dev/null || true
else printf 'ok   - run-loop exits on SIGTERM\n'; fi
# No spawn-worker.sh process may remain (scoped to this sandbox's worktree path).
if pgrep -f "spawn-worker.sh 1" >/dev/null 2>&1 && pgrep -fl "spawn-worker.sh 1" | grep -q "$T"; then
  printf 'FAIL - a spawn-worker.sh child survived the driver stop [#242]\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
  pkill -f "spawn-worker.sh 1" 2>/dev/null || true
else printf 'ok   - no spawn-worker.sh child survives the driver stop [#242]\n'; fi
assert_dead "$T/marks/claude.pid"     "driver SIGTERM → child claude killed (no orphan) [#242]"
assert_dead "$T/marks/grandchild.pid" "driver SIGTERM → GRANDCHILD killed (no billable-box orphan) [#242]"

rm -rf "$T"
assert_done
