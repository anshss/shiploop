#!/usr/bin/env bash
# Leak B regression: `worktree:rm` must kill the dev stack (orchestrator/server/Next.js) a governor
# worker booted INSIDE the worktree BEFORE removing the dir — otherwise a prod-pointed dev process
# outlives its removed worktree as a zombie squatting the slot's port. The kill MUST be
# OWNERSHIP-scoped (anti-pattern #10): a process on a slot port is killed ONLY if its cwd is under
# THIS worktree, so a parallel session on a colliding slot is never cross-killed.
#
# This is a focused function-level test: it extracts the REAL `kill_worktree_stack` function from
# rm.sh (no duplicated copy to drift) and exercises it against two live processes —
#   (a) OWNED   : binds a worktree port, cwd UNDER the worktree  → must be killed
#   (b) FOREIGN : binds ANOTHER worktree port, cwd OUTSIDE it    → must SURVIVE (proves cwd scoping:
#                 a port-holder on a worktree port is spared when it isn't ours)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RM="$DIR/../../worktree/rm.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 unavailable (needed to hold a real listening port)"; exit 0; }

# Extract the actual kill_worktree_stack() function text from rm.sh and source it — so the test
# runs the SHIPPED implementation, not a copy.
FN="$(mktemp)"; trap 'rm -f "$FN"' EXIT
awk '/^kill_worktree_stack\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$RM" > "$FN"
if ! grep -q 'kill_worktree_stack' "$FN"; then
  printf 'FAIL - could not extract kill_worktree_stack() from %s\n' "$RM"; exit 1
fi
# shellcheck disable=SC1090
source "$FN"

# --- sandbox: a worktree dir + a sibling dir OUTSIDE it ---
# `pwd -P` resolves the macOS mktemp symlink (/var → /private/var) so the sandbox path matches what
# lsof reports as a process cwd — otherwise the ownership check would symlink-mismatch every time.
T="$(cd "$(mktemp -d)" && pwd -P)"; WT="$T/wt"; OUT="$T/outside"
mkdir -p "$WT" "$OUT"

# Three free-ish ports (high, randomized per run so overlapping runs don't collide). The first two
# are declared in the worktree.env so the function inspects BOTH — the foreign one must still survive
# on cwd grounds.
BASE=$(( 39000 + (RANDOM % 400) * 3 ))
OWNED_PORT=$BASE
FOREIGN_PORT=$((BASE + 1))
GONE_PORT=$((BASE + 2))
cat > "$WT/worktree.env" <<EOF
export WORKTREE_SLOT=99
export WORKTREE_ALPHA_PORT=$OWNED_PORT
export WORKTREE_WEB_PORT=$FOREIGN_PORT
EOF

# Bind a listening TCP port from a chosen cwd, print the pid. python's fds are redirected to
# /dev/null INSIDE the subshell so this function's command-substitution ($()) captures ONLY the
# pid and returns immediately (otherwise the live python holds the pipe open and $() blocks).
hold_port() { # cwd port
  ( cd "$1" && exec python3 -c '
import socket,sys,time
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)
' "$2" >/dev/null 2>&1 ) &
  echo $!
}
wait_listen() { # port timeout_s
  local i=0; while ! lsof -ti tcp:"$1" >/dev/null 2>&1 && [[ "$i" -lt "${2:-50}" ]]; do sleep 0.1; i=$((i+1)); done; }

owned_pid="$(hold_port "$WT" "$OWNED_PORT")"       # cwd UNDER the worktree → ours
foreign_pid="$(hold_port "$OUT" "$FOREIGN_PORT")"  # cwd OUTSIDE the worktree → NOT ours
cleanup() { kill -9 "$owned_pid" "$foreign_pid" 2>/dev/null || true; rm -rf "$T"; }
trap 'cleanup; rm -f "$FN"' EXIT
wait_listen "$OWNED_PORT" 50
wait_listen "$FOREIGN_PORT" 50

# sanity: both up before the kill
up_o=no; kill -0 "$owned_pid" 2>/dev/null && up_o=yes
up_f=no; kill -0 "$foreign_pid" 2>/dev/null && up_f=yes
assert_eq "$up_o" "yes" "owned port-holder is up before kill"
assert_eq "$up_f" "yes" "foreign port-holder is up before kill"

# --- run the real function ---
kill_worktree_stack "$WT" >/dev/null 2>&1 || true

# owned must be dead; foreign must survive.
wait_gone() { local i=0; while kill -0 "$1" 2>/dev/null && [[ "$i" -lt "${2:-50}" ]]; do sleep 0.1; i=$((i+1)); done; }
wait_gone "$owned_pid" 50
dead_o=no; kill -0 "$owned_pid" 2>/dev/null || dead_o=yes
alive_f=no; kill -0 "$foreign_pid" 2>/dev/null && alive_f=yes
assert_eq "$dead_o"   "yes" "OWNED stack process (cwd under worktree) is killed"
assert_eq "$alive_f"  "yes" "FOREIGN process on a worktree port (cwd OUTSIDE) is NOT killed — ownership-scoped (anti-pattern #10)"

# --- worktree.env gone → skip gracefully, never an unscoped kill ---
GONE="$T/gone"; mkdir -p "$GONE"
# a process on a would-be worktree port, cwd anywhere — with no worktree.env the fn can't scope, so
# it must NOT kill it.
gp="$(hold_port "$OUT" "$GONE_PORT")"; wait_listen "$GONE_PORT" 50
kill_worktree_stack "$GONE" >/dev/null 2>&1 || true
gp_alive=no; kill -0 "$gp" 2>/dev/null && gp_alive=yes
kill -9 "$gp" 2>/dev/null || true
assert_eq "$gp_alive" "yes" "no worktree.env → stack kill skipped (nothing to scope to; never an unscoped port kill)"

assert_done
