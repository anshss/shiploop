#!/usr/bin/env bash
# The background-fixture reap helper in assert.sh: pids recorded through bg_reap
# are reaped via govern::kill_tree on the test's EXIT, pass or fail, and a test's
# own EXIT trap set before the first bg_reap call still runs after the reap.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# 1. bg_kill_all reaps a recorded stub (children first, then the leader).
( sleep 300 ) & SUB=$!
bg_reap "$SUB"
bg_kill_all
wait "$SUB" 2>/dev/null || true
assert_eq "$(kill -0 "$SUB" 2>/dev/null && echo alive || echo dead)" "dead" \
  "bg_kill_all reaps a recorded stub leader"

# 2. the chained EXIT trap reaps a recorded stub when the test exits FAILING,
#    without ever killing it, and the test's own trap still runs after the reap.
LEAK="$T/leak.sh"; PIDFILE="$T/pid"; MARKER="$T/marker"
cat > "$LEAK" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$DIR/assert.sh"
set +e
T2="\$(mktemp -d)"; trap 'rm -rf "\$T2"; touch "$MARKER"' EXIT
( sleep 300 ) & bg_reap "\$!"
printf '%s\n' "\$!" > "$PIDFILE"
exit 1
EOF
bash "$LEAK" >/dev/null 2>&1
leak_rc=$?
stub="$(cat "$PIDFILE")"
dead=no
for i in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$stub" 2>/dev/null || { dead=yes; break; }
  sleep 0.2
done
assert_eq "$leak_rc" "1" "chained reap: the failing test's own exit status is preserved"
assert_eq "$dead" "yes" "a stub recorded via bg_reap is reaped when its test exits failing"
marker=no; [ -f "$MARKER" ] && marker=yes
assert_eq "$marker" "yes" "the test's own EXIT trap still runs after the reap"

assert_done
