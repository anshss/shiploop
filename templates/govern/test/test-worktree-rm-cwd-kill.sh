#!/usr/bin/env bash
# Regression: `worktree:rm` cwd-sweep kill pass and the survivor gate.
#
# The port-scoped kill pass can only see a process that is LISTENING on a port
# worktree.env declares; a node child of a watcher outlives its parent holding nothing a
# port scan can see, and once the worktree dir is removed the cwd string is the only
# identification left. Covers:
#   (a) function level: kill_worktree_cwd_procs kills an allowlisted dev-stack process
#       whose cwd is under the worktree, and ONLY that one; a foreign cwd and a
#       non-allowlisted process survive;
#   (b) end to end: the survivor gate REFUSES removal (exit 1, dir left in place) while
#       an allowlisted process still runs inside the tree, and --force-clean-fail; a
#       SEPARATE flag from --force; tears down anyway.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# A process's ps comm is its executable basename, so the test compiles a trivial sleeper
# and NAMES the output after allowlisted binaries; the same trick the stack-kill test
# uses with python, extended to control the NAME. A compiled helper, not a copied system
# binary: macOS kills a copied platform binary on launch (SIGKILL from AMFI), which would
# make every spawned "process" dead before the function under test ever ran.
command -v cc >/dev/null 2>&1 || { echo "SKIP - cc unavailable (needed to build a helper binary with a controlled comm name)"; exit 0; }
BIN="$(mktemp -d)"
cat > "$BIN/sleeper.c" <<'EOF'
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 60;
  while (n-- > 0) sleep(1);
  return 0;
}
EOF
cc -o "$BIN/node" "$BIN/sleeper.c" || { echo "SKIP - cc failed to build the helper binary"; exit 0; }
T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"   # pwd -P: lsof reports the PHYSICAL cwd (macOS /var → /private/var)
trap 'kill -9 "${SPAWNED_PIDS:-}" 2>/dev/null; rm -rf "$T" "$BIN"' EXIT
SPAWNED_PIDS=""

start_named() { # <cwd> → sets LAST_PID (runs in the test's own shell so SPAWNED_PIDS accumulates)
  ( cd "$1" && exec "$BIN/node" 60 >/dev/null 2>&1 ) &
  LAST_PID=$!
  SPAWNED_PIDS="$SPAWNED_PIDS $LAST_PID"
}

# ══ (a) function level: the shipped kill_worktree_cwd_procs ═══════════════════════════
RM="$DIR/../../worktree/rm.sh"
FN="$(mktemp)"
awk '/^procs_with_cwd_under\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$RM" > "$FN"
awk '/^kill_worktree_cwd_procs\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$RM" >> "$FN"
grep -q 'kill_worktree_cwd_procs' "$FN" || { printf 'FAIL - could not extract cwd-kill functions from %s\n' "$RM"; exit 1; }
# The allowlist default lives OUTSIDE the two functions in rm.sh; under `set -u` an
# unbound STACK_KILL_NAMES would abort this whole test silently, so set the same
# default the script itself declares before sourcing the extracted functions.
STACK_KILL_NAMES="${STACK_KILL_NAMES:-node tsx npm npx next go air esbuild vite}"
# shellcheck disable=SC1090
source "$FN"

KT="$(cd "$(mktemp -d)" && pwd -P)"   # pwd -P: match what lsof reports (macOS /var symlink)
KWT="$KT/wt"; KOUT="$KT/outside"
mkdir -p "$KWT" "$KOUT"
start_named "$KWT"; owned_pid="$LAST_PID"       # allowlisted, cwd UNDER the worktree → killed
start_named "$KOUT"; foreign_pid="$LAST_PID"    # allowlisted, cwd OUTSIDE → survives (scoping)
# A non-allowlisted process INSIDE the tree must also survive; same helper compiled
# under a name outside STACK_KILL_NAMES:
inside_pid=""
if cc -o "$BIN/python3" "$BIN/sleeper.c" 2>/dev/null; then
  ( cd "$KWT" && exec "$BIN/python3" 60 >/dev/null 2>&1 ) &
  inside_pid=$!
  SPAWNED_PIDS="$SPAWNED_PIDS $inside_pid"
fi
for p in $owned_pid $foreign_pid; do kill -0 "$p" 2>/dev/null; done   # sanity: all up

kill_worktree_cwd_procs "$KWT" >/dev/null 2>&1

if kill -0 "$owned_pid" 2>/dev/null; then
  printf 'FAIL - cwd kill: allowlisted process under the worktree survived\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1))
else
  printf 'ok   - cwd kill: allowlisted process under the worktree is killed\n'
fi
if ! kill -0 "$foreign_pid" 2>/dev/null; then
  printf 'FAIL - cwd kill: FOREIGN process (cwd outside) was killed; scoping broken\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1))
else
  printf 'ok   - cwd kill: foreign cwd survives (ownership scoping)\n'
fi
if [ -n "$inside_pid" ] && ! kill -0 "$inside_pid" 2>/dev/null; then
  printf 'FAIL - cwd kill: non-allowlisted process inside the tree was killed\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1))
else
  printf 'ok   - cwd kill: non-allowlisted process inside the tree survives\n'
fi
kill -9 "$foreign_pid" "$inside_pid" 2>/dev/null || true
rm -f "$FN"

# ══ (b) end to end: survivor gate refuses, --force-clean-fail waives ══════════════════
mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib" "$T/alpha"
cp "$DIR/../../worktree/new.sh" "$T/scripts/worktree/new.sh"
cp "$DIR/../../worktree/rm.sh" "$T/scripts/worktree/rm.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$T/scripts/worktree/lib/registry.sh"
cp "$DIR/../../worktree/lib/base-ref.sh" "$T/scripts/worktree/lib/base-ref.sh"
cat > "$T/scripts/lib/workspace.sh" <<EOF
ROOT_PM=npm
WORKTREE_BASE="$T/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
EOF

git -C "$T" init -q -b main
git -C "$T" config user.email t@t; git -C "$T" config user.name t
# A real workspace's .gitignore (templates/gitignore) keeps the generated per-worktree
# env file out of `git status`; without it the dirty-tree refusal would fire before the
# survivor gate is ever reached.
printf '.dispatch-packet.md\nworktree.env\n.env\n/alpha/\n' > "$T/.gitignore"
echo root > "$T/root.txt"; git -C "$T" add -A; git -C "$T" commit -qm init
git -C "$T/alpha" init -q -b main
git -C "$T/alpha" config user.email t@t; git -C "$T/alpha" config user.name t
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm init

export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10
(cd "$T" && bash "$T/scripts/worktree/new.sh" t99 --skip-bootstrap >/dev/null 2>&1)
assert_eq "$([ -e "$T/wt/t99/alpha/.git" ] && echo y || echo n)" "y" "setup: worktree t99 exists"

# An allowlisted process runs with its cwd INSIDE the worktree. WT_RM_SKIP_STACK_KILL=1
# skips the kill passes (the shipped test seam) so the gate is exercised deterministically.
start_named "$T/wt/t99"; gate_pid="$LAST_PID"
wait_cwd() { local i=0; while [ "$i" -lt 50 ]; do
  # Here-string, never `lsof | grep -qF`: under pipefail, grep -q exits on the first match,
  # lsof takes SIGPIPE on output larger than the pipe buffer, and a FOUND cwd reads as 141
  # ("never showed"). The here-string hands grep the whole snapshot with no live pipe.
  grep -qF "$T/wt/t99" <<<"$(lsof -d cwd -Fpn 2>/dev/null)" && return 0
  sleep 0.1; i=$((i+1)); done; return 1; }
wait_cwd || { printf 'FAIL - setup: the gate process never showed a cwd in the worktree\n'; exit 1; }

out_r="$(cd "$T" && WT_RM_SKIP_STACK_KILL=1 bash "$T/scripts/worktree/rm.sh" t99 2>&1)"; rc_r=$?
assert_eq "$rc_r" "1" "survivor gate: removal REFUSED while a dev-stack process runs in the tree"
assert_contains "$out_r" "STILL running with a cwd under" "survivor gate: names the survivor"
assert_contains "$out_r" "force-clean-fail" "survivor gate: names the waiver flag"
assert_eq "$([ -e "$T/wt/t99" ] && echo y || echo n)" "y" \
  "survivor gate: the worktree dir is left in place"
assert_eq "$([ -e "$T/alpha" ] && echo y || echo n)" "y" "survivor gate: main checkout untouched"
# The refusal must NOT free the registry slot: a retry re-runs the same named path.
assert_contains "$(cd "$T" && bash "$T/scripts/worktree/rm.sh" t99-nonexistent 2>&1)" "unknown worktree" "sanity: registry intact"

# --force-clean-fail tears down anyway (still skipping the kill passes; the survivor runs).
out_f="$(cd "$T" && WT_RM_SKIP_STACK_KILL=1 bash "$T/scripts/worktree/rm.sh" t99 --force-clean-fail 2>&1)"; rc_f=$?
assert_eq "$rc_f" "0" "--force-clean-fail: teardown proceeds despite the survivor"
assert_contains "$out_f" "continuing anyway per --force-clean-fail" \
  "--force-clean-fail: says it accepted the orphan risk"
assert_eq "$([ -e "$T/wt/t99" ] && echo y || echo n)" "n" \
  "--force-clean-fail: the worktree dir is removed"
kill -9 "$gate_pid" 2>/dev/null || true   # the waived survivor is now an orphan; kill it

# A non-allowlisted survivor ALONE (only a shell-like process in the tree) is reported but
# NEVER blocks: the same teardown goes through with only that process inside.
if command -v zsh >/dev/null 2>&1; then
  (cd "$T" && bash "$T/scripts/worktree/new.sh" t97 --skip-bootstrap >/dev/null 2>&1)
  assert_eq "$([ -e "$T/wt/t97" ] && echo y || echo n)" "y" "setup: worktree t97 exists"
  shell_pid=""
  ( cd "$T/wt/t97" && exec /bin/zsh -c 'sleep 60' >/dev/null 2>&1 ) &
  shell_pid=$!; SPAWNED_PIDS="$SPAWNED_PIDS $shell_pid"
  sleep 0.5
  out_ns="$(cd "$T" && WT_RM_SKIP_STACK_KILL=1 bash "$T/scripts/worktree/rm.sh" t97 2>&1)"; rc_ns=$?
  assert_eq "$rc_ns" "0" "non-allowlisted survivor alone does not block removal"
  assert_contains "$out_ns" "not a dev-stack process, leaving it" \
    "non-allowlisted survivor: reported, never killed, never blocking"
  assert_eq "$([ -e "$T/wt/t97" ] && echo y || echo n)" "n" \
    "non-allowlisted survivor: the worktree was removed"
  kill -9 "$shell_pid" 2>/dev/null || true
fi

# A plain --force does NOT waive the live-process gate (that is why the flag is separate):
(cd "$T" && bash "$T/scripts/worktree/new.sh" t98 --skip-bootstrap >/dev/null 2>&1)
start_named "$T/wt/t98"; gate2_pid="$LAST_PID"
sleep 0.5
out_g="$(cd "$T" && WT_RM_SKIP_STACK_KILL=1 bash "$T/scripts/worktree/rm.sh" t98 --force 2>&1)"; rc_g=$?
assert_eq "$rc_g" "1" "--force alone does NOT waive the survivor gate"
assert_eq "$([ -e "$T/wt/t98" ] && echo y || echo n)" "y" "--force alone: worktree still in place"
kill -9 "$gate2_pid" 2>/dev/null || true

assert_done
