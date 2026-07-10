#!/usr/bin/env bash
# #B2 regression: the SessionEnd cleanup hook must kill the LOCAL stack ports FIRST, THEN run the
# project-specific session-cleanup hook (which typically does network work — closing billable test
# deploys, sweeping remote orchestrators). The hook runs under one bounded SessionEnd budget (~90s
# on Claude Code); with the OLD order (network first) a slow network phase could exhaust the budget
# before the local orchestrator was ever killed — the exact zombie-reconciler/billing leak the hook
# exists to stop.
#
# Drives the REAL hook's worktree path against a live local-port listener + a fake session-cleanup.sh
# (the "network" phase) that records, at the moment it runs, whether the local port is still up.
# Correct order ⇒ the port is ALREADY free by the time the network phase runs.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REAL_HOOK="$DIR/../../worktree/session-end-cleanup.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 unavailable (needed to hold a real listening port)"; exit 0; }

# `pwd -P` so the sandbox path matches lsof's reported process cwd (macOS /var → /private/var symlink).
T="$(cd "$(mktemp -d)" && pwd -P)"
mk_ws_stub "$T"
# Stage a copy of the hook inside $T so the hook's own `ROOT=<its-dir>/../..` resolves to $T (and
# thus sources the stub workspace.sh at $T/scripts/lib/workspace.sh + finds the stub session-cleanup.sh).
mkdir -p "$T/scripts/worktree" "$T/scripts/lib"
cp "$REAL_HOOK" "$T/scripts/worktree/session-end-cleanup.sh"
HOOK="$T/scripts/worktree/session-end-cleanup.sh"

WT="$T/wt-slot"
mkdir -p "$WT"
PORT=$(( 39500 + (RANDOM % 400) ))
cat > "$WT/worktree.env" <<EOF
export WORKTREE_SLOT=98
export WORKTREE_ALPHA_PORT=$PORT
EOF
ORDER="$T/order.log"; : > "$ORDER"

# Fake session-cleanup.sh = the NETWORK phase. On each call it records whether the local port is
# still listening. Correct hook order (local kill first) ⇒ already free here.
cat > "$T/scripts/lib/session-cleanup.sh" <<EOF
#!/usr/bin/env bash
P="\${WORKTREE_ALPHA_PORT:-$PORT}"
state=free
if [ -n "\$P" ]; then
  i=0
  while lsof -ti tcp:"\$P" >/dev/null 2>&1 && [ "\$i" -lt 5 ]; do sleep 0.1; i=\$((i+1)); done
  lsof -ti tcp:"\$P" >/dev/null 2>&1 && state=listening
fi
printf 'network %s\n' "\$state" >> "$ORDER"
exit 0
EOF
chmod +x "$T/scripts/lib/session-cleanup.sh"

# Hold the local port from a cwd UNDER the worktree so the hook's ownership-scoped kill owns it.
hold_port() { ( cd "$1" && exec python3 -c '
import socket,sys,time
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)' "$2" >/dev/null 2>&1 ) & echo $!; }
pid="$(hold_port "$WT" "$PORT")"
cleanup(){ kill -9 "$pid" 2>/dev/null || true; rm -rf "$T"; }; trap cleanup EXIT
i=0; while ! lsof -ti tcp:"$PORT" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
up=no; kill -0 "$pid" 2>/dev/null && lsof -ti tcp:"$PORT" >/dev/null 2>&1 && up=yes
assert_eq "$up" "yes" "local port is listening before the hook runs"

# Run the staged hook from within the worktree (PWD=$WT → the walk-up finds worktree.env immediately).
( cd "$WT" && bash "$HOOK" ) >/dev/null 2>&1 || true

first="$(head -1 "$ORDER" 2>/dev/null || true)"
assert_eq "$first" "network free" "network phase saw the local port ALREADY killed → local-kill ran FIRST [#B2]"
dead=no; kill -0 "$pid" 2>/dev/null || dead=yes
assert_eq "$dead" "yes" "the hook killed the worktree-owned local port"

assert_done
