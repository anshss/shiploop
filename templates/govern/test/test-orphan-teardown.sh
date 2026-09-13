#!/usr/bin/env bash
# Regression: stopping/killing a worker must leave ZERO surviving process children. The fix runs a
# spawned `claude` in its OWN process group so a supervisor's teardown (govern::kill_tree) can reap
# the whole subtree (leader plus grandchildren) rather than leaving them reparented to init,
# needing a manual `kill -9` sweep, or holding a billable resource. Hermetic + generic (alpha
# auto-merge, web frontend; org acme).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

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
assert_dead "$T0/marks/grand.pid"  "kill_tree reaps the GRANDCHILD (subtree teardown)"
rm -rf "$T0"

assert_done
