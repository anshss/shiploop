#!/usr/bin/env bash
# Hermetic tests for the wrap-in-place transform (templates/lib/wrap.sh).
#
# Covers the full contract from the design spec:
#   - happy path (untracked + submodule preserved; scaffold root valid; undo removed)
#   - EVERY preflight refusal fires (hard refuses + warn/confirm)
#   - failure injection at each move step → trap rollback restores byte-identical
#   - undo after a COMPLETED scaffold → original layout, no residue, same-named files intact
#   - SIGINT injection mid-move → trap fires, layout restored
#   - all six mode-detection rows
#
# wrap.sh lives only in the hub/template checkout (it is a setup-time transform,
# not an installed workspace mechanism), so this test SKIPs when run from a
# scaffolded workspace where wrap.sh is absent.
set -uo pipefail
set -m 2>/dev/null || true   # job control so the SIGINT-injection case can deliver a real INT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Resolve wrap.sh (template layout: templates/govern/test/ -> templates/lib/wrap.sh).
WRAP="$(cd "$DIR/../../lib" 2>/dev/null && pwd)/wrap.sh"
[ -f "$WRAP" ] || { echo "SKIP: wrap.sh not found (installed workspace, not the hub) — $WRAP" >&2; exit 77; }
# scaffold.sh at the hub root (templates/govern/test/ -> ../../../scaffold.sh).
SCAFFOLD="$(cd "$DIR/../../.." 2>/dev/null && pwd)/scaffold.sh"
[ -f "$SCAFFOLD" ] || { echo "SKIP: scaffold.sh not found at hub root — $SCAFFOLD" >&2; exit 77; }

# ── Fixtures ────────────────────────────────────────────────────────────────
# A minimal git repo with a tracked tree, its OWN root package.json + CLAUDE.md
# (to catch same-named-file collisions on undo), and an untracked file.
mk_repo() {
  local d; d="$(mktemp -d)/proj"; mkdir -p "$d"
  ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    printf '{"name":"myapp"}\n' > package.json
    printf '# my app (user)\n' > CLAUDE.md
    mkdir -p src && printf 'console.log(1)\n' > src/index.js
    git add -A && git commit -q -m init
    printf 'scratch\n' > notes.txt          # untracked — must travel with the folder
  )
  printf '%s' "$d"
}

# snapshot of the workspace layout (relative paths), stable for byte-compare.
layout() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort ); }
# layout excluding the retained wrap artifacts (used after an intentional rollback).
layout_no_wrap() { layout "$1" | grep -v '/\.wrap-'; }

WRAP_COMMON=(--pm npm --org acme --repos "myapp:3000:npm run dev" --merge-allowlist "" \
             --scaffold "$SCAFFOLD" --confirm-live-writer)

run_wrap() { # <workspace> [extra args...]
  local ws="$1"; shift
  /bin/bash "$WRAP" --workspace-dir "$ws" --name myapp "${WRAP_COMMON[@]}" "$@" --yes
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Happy path
# ══════════════════════════════════════════════════════════════════════════════
echo "── 1. happy path (untracked + scaffold root + undo removed) ──" >&2
T="$(mk_repo)"; PRE_HEAD="$(git -C "$T" rev-parse HEAD)"; PRE_BR="$(git -C "$T" rev-parse --abbrev-ref HEAD)"

# Add a submodule if this git allows file:// submodules; otherwise continue without.
SUB_OK=0
SUBREMOTE="$(mktemp -d)/subrmt"; git init -q "$SUBREMOTE" 2>/dev/null
( cd "$SUBREMOTE"; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  printf 'lib\n' > lib.txt; git add -A; git commit -q -m sub ) 2>/dev/null
if git -C "$T" -c protocol.file.allow=always submodule add "$SUBREMOTE" vendor/lib >/dev/null 2>&1; then
  git -C "$T" -c protocol.file.allow=always commit -q -m "add submodule" 2>/dev/null
  SUB_OK=1
  PRE_HEAD="$(git -C "$T" rev-parse HEAD)"
  PRE_SUBM="$(git -C "$T" submodule status)"
fi
PRE_STATUS="$(git -C "$T" status --porcelain)"

out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. wrap exits 0"
assert_eq "$(git -C "$T/myapp" rev-parse HEAD)" "$PRE_HEAD" "1. HEAD preserved"
assert_eq "$(git -C "$T/myapp" rev-parse --abbrev-ref HEAD)" "$PRE_BR" "1. branch preserved"
assert_eq "$(git -C "$T/myapp" status --porcelain)" "$PRE_STATUS" "1. status snapshot byte-identical"
[ -f "$T/myapp/notes.txt" ] && printf 'ok   - 1. untracked file moved with folder\n' || { printf 'FAIL - 1. untracked file lost\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(cat "$T/myapp/package.json")" '{"name":"myapp"}' "1. user package.json preserved in subfolder"
[ -f "$T/scripts/lib/workspace.sh" ] && printf 'ok   - 1. scaffold root produced\n' || { printf 'FAIL - 1. scaffold root missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -d "$T/.git" ] && printf 'ok   - 1. root git initialized\n' || { printf 'FAIL - 1. root git missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
git -C "$T" check-ignore -q myapp && printf 'ok   - 1. subfolder gitignored at root\n' || { printf 'FAIL - 1. subfolder not gitignored\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ "$(git -C "$T" ls-files -- myapp | wc -l | tr -d ' ')" = 0 ] && printf 'ok   - 1. subfolder not in root commit\n' || { printf 'FAIL - 1. subfolder swept into root commit\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ ! -f "$T/.wrap-undo.sh" ] && printf 'ok   - 1. undo script removed post-verify\n' || { printf 'FAIL - 1. undo script left behind\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
if [ "$SUB_OK" = 1 ]; then
  assert_eq "$(git -C "$T/myapp" submodule status)" "$PRE_SUBM" "1. submodule SHAs preserved"
else
  printf 'ok   - 1. (submodule case skipped — git blocks file:// submodules here)\n'
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. Preflight refusals
# ══════════════════════════════════════════════════════════════════════════════
echo "── 2. preflight refusals ──" >&2

# 2a. dirty tracked tree → refuse (exit 3)
T="$(mk_repo)"; echo "mutate" >> "$T/src/index.js"   # tracked modification
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2a. dirty tracked tree → refuse (3)"
assert_contains "$out" "uncommitted" "2a. message names the dirty tree"
[ -d "$T/myapp" ] && { printf 'FAIL - 2a. touched the tree on refusal\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok   - 2a. nothing moved on refusal\n'

# 2b. in-progress operation (fake a rebase) → refuse
T="$(mk_repo)"; mkdir -p "$T/.git/rebase-merge"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2b. mid-rebase → refuse (3)"
assert_contains "$out" "in progress" "2b. message names the in-progress op"

# 2c. .git is a FILE → refuse
T="$(mk_repo)"; rm -rf "$T/.git"; printf 'gitdir: /elsewhere/.git/worktrees/x\n' > "$T/.git"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2c. .git-as-file → refuse (3)"
assert_contains "$out" "linked worktree" "2c. names the linked-worktree hazard"

# 2d. linked worktree present → refuse
T="$(mk_repo)"; git -C "$T" worktree add -q "$(mktemp -d)/wt" -b sidebranch >/dev/null 2>&1
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2d. linked worktree → refuse (3)"
assert_contains "$out" "linked worktrees" "2d. names linked worktrees"

# 2e. absolute core.worktree → refuse
T="$(mk_repo)"; git -C "$T" config --local core.worktree "/abs/where"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2e. core.worktree set → refuse (3)"
assert_contains "$out" "core.worktree" "2e. names core.worktree"

# 2f. absolute core.hooksPath → refuse
T="$(mk_repo)"; git -C "$T" config --local core.hooksPath "/abs/hooks"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2f. absolute core.hooksPath → refuse (3)"
assert_contains "$out" "core.hooksPath" "2f. names core.hooksPath"

# 2g. includeIf gitdir:/abs → refuse
T="$(mk_repo)"; printf '\n[includeIf "gitdir:/abs/path/"]\n\tpath = /x\n' >> "$T/.git/config"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2g. includeIf gitdir:/abs → refuse (3)"
assert_contains "$out" "includeIf" "2g. names includeIf"

# 2h. escaping relative symlink → needs-confirm (exit 5) without the flag
T="$(mk_repo)"; OUTSIDE="$(mktemp -d)/outside"; mkdir -p "$OUTSIDE"; ln -s "../../$(basename "$(dirname "$OUTSIDE")")/outside" "$T/escape"
out="$(/bin/bash "$WRAP" --workspace-dir "$T" --name myapp --pm npm --org acme --repos "myapp::" --merge-allowlist "" --scaffold "$SCAFFOLD" --confirm-live-writer --yes 2>&1)"; rc=$?
assert_eq "$rc" "5" "2h. escaping symlink → needs-confirm (5)"
assert_contains "$out" "confirm-symlinks" "2h. surfaces the confirm flag"

# 2i. pre-existing .wrap-undo.sh → refuse
T="$(mk_repo)"; printf '#!/bin/sh\n' > "$T/.wrap-undo.sh"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "3" "2i. pre-existing .wrap-undo.sh → refuse (3)"
assert_contains "$out" ".wrap-undo.sh already exists" "2i. names the artifact"

# 2j. case-insensitive name collision (skip-mark on case-sensitive FS)
T="$(mk_repo)"; mkdir "$T/MyApp"
# probe FS case-sensitivity: create lowercase, see if uppercase resolves
CASEPROBE="$(mktemp -d)"; : > "$CASEPROBE/aa"
if [ -e "$CASEPROBE/AA" ]; then
  out="$(run_wrap "$T" 2>&1)"; rc=$?
  assert_eq "$rc" "4" "2j. case-insensitive name collision → exit 4"
  assert_contains "$out" "COLLISION" "2j. reports a collision"
else
  printf 'ok   - 2j. SKIP case-insensitive collision (filesystem is case-SENSITIVE)\n'
fi
# exact-name collision must fail regardless of FS case sensitivity
T="$(mk_repo)"; mkdir "$T/myapp"
out="$(run_wrap "$T" 2>&1)"; rc=$?
assert_eq "$rc" "4" "2j'. exact name collision → exit 4"

# 2k. below repo root → refuse
T="$(mk_repo)"; mkdir -p "$T/sub"
out="$(/bin/bash "$WRAP" --workspace-dir "$T/sub" --name myapp "${WRAP_COMMON[@]}" --yes 2>&1)"; rc=$?
assert_eq "$rc" "3" "2k. below repo root → refuse (3)"
assert_contains "$out" "repo root" "2k. tells you to cd to the root"

# 2l. bare repo → refuse
BARE="$(mktemp -d)/bare.git"; git init -q --bare "$BARE"
out="$(/bin/bash "$WRAP" --workspace-dir "$BARE" --name myapp "${WRAP_COMMON[@]}" --yes 2>&1)"; rc=$?
assert_eq "$rc" "3" "2l. bare repo → refuse (3)"
assert_contains "$out" "bare" "2l. names the bare repo"

# ══════════════════════════════════════════════════════════════════════════════
# 3. Failure injection at each move step → trap rollback restores byte-identical
# ══════════════════════════════════════════════════════════════════════════════
echo "── 3. failure injection / trap rollback ──" >&2
for stage in moving pre-rename renamed scaffolding post-scaffold; do
  T="$(mk_repo)"; PRE_HEAD="$(git -C "$T" rev-parse HEAD)"; BEFORE="$(layout "$T")"
  out="$(WRAP_TEST_FAIL_AT="$stage" run_wrap "$T" 2>&1)"; rc=$?
  assert_eq "$rc" "1" "3.$stage: nonzero exit on injected failure"
  assert_eq "$(layout_no_wrap "$T")" "$BEFORE" "3.$stage: layout restored byte-identical"
  assert_eq "$(git -C "$T" rev-parse HEAD)" "$PRE_HEAD" "3.$stage: repo HEAD intact at root"
  [ -f "$T/.wrap-undo.sh" ] && printf 'ok   - 3.%s: .wrap-undo.sh retained on failure\n' "$stage" || { printf 'FAIL - 3.%s: undo not retained\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  [ ! -d "$T/myapp" ] && printf 'ok   - 3.%s: no half-wrapped subfolder\n' "$stage" || { printf 'FAIL - 3.%s: subfolder left behind\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  [ ! -f "$T/.wrap-manifest" ] && printf 'ok   - 3.%s: stale manifest dropped (retained undo is a safe no-op)\n' "$stage" || { printf 'FAIL - 3.%s: stale manifest kept\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  # The retained undo must be safe to run against the restored repo (no data loss).
  ( cd "$T" && /bin/bash .wrap-undo.sh >/dev/null 2>&1 )
  [ -f "$T/package.json" ] && [ -f "$T/src/index.js" ] && [ "$(git -C "$T" rev-parse HEAD)" = "$PRE_HEAD" ] \
    && printf 'ok   - 3.%s: retained undo did not harm the restored repo\n' "$stage" \
    || { printf 'FAIL - 3.%s: retained undo damaged the restored repo\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done

# ══════════════════════════════════════════════════════════════════════════════
# 4. Undo after a COMPLETED scaffold
# ══════════════════════════════════════════════════════════════════════════════
echo "── 4. undo after completed scaffold ──" >&2
T="$(mk_repo)"; PRE_HEAD="$(git -C "$T" rev-parse HEAD)"; BEFORE="$(layout "$T")"
USER_PKG="$(cat "$T/package.json")"; USER_CLAUDE="$(cat "$T/CLAUDE.md")"
out="$(run_wrap "$T" --keep-undo 2>&1)"; rc=$?
assert_eq "$rc" "0" "4. wrap+scaffold ok (--keep-undo)"
[ -f "$T/.wrap-undo.sh" ] && printf 'ok   - 4. undo retained under --keep-undo\n' || { printf 'FAIL - 4. undo missing under --keep-undo\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
( cd "$T" && /bin/bash .wrap-undo.sh >/dev/null 2>&1 ); urc=$?
assert_eq "$urc" "0" "4. undo runs cleanly"
assert_eq "$(layout "$T")" "$BEFORE" "4. original layout fully restored"
assert_eq "$(cat "$T/package.json")" "$USER_PKG" "4. user package.json intact (no collision with scaffold's)"
assert_eq "$(cat "$T/CLAUDE.md")" "$USER_CLAUDE" "4. user CLAUDE.md intact (no collision with scaffold's)"
[ ! -d "$T/scripts" ] && [ ! -f "$T/learnings.md" ] && printf 'ok   - 4. no scaffold residue\n' || { printf 'FAIL - 4. scaffold residue left\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ "$(git -C "$T" rev-parse HEAD)" = "$PRE_HEAD" ] && printf 'ok   - 4. original repo HEAD restored at root\n' || { printf 'FAIL - 4. repo HEAD not restored\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -d "$T/.git" ] && [ ! -d "$T/myapp" ] && printf 'ok   - 4. root .git is the original repo (subfolder gone)\n' || { printf 'FAIL - 4. root repo state wrong after undo\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ══════════════════════════════════════════════════════════════════════════════
# 5. SIGINT injection mid-move
# ══════════════════════════════════════════════════════════════════════════════
echo "── 5. SIGINT injection mid-move ──" >&2
T="$(mk_repo)"; PRE_HEAD="$(git -C "$T" rev-parse HEAD)"; BEFORE="$(layout "$T")"
WRAP_TEST_HANG_BEFORE_RENAME=1 /bin/bash "$WRAP" --workspace-dir "$T" --name myapp \
  "${WRAP_COMMON[@]}" --yes >/dev/null 2>&1 &
WPID=$!
staged=0
for _ in $(seq 1 100); do
  if find "$T" -maxdepth 1 -name '.wrap-staging.*' -type d 2>/dev/null | grep -q .; then staged=1; break; fi
  sleep 0.1
done
if [ "$staged" = 1 ]; then
  kill -INT "$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null; rc=$?
  assert_eq "$rc" "1" "5. wrap exits nonzero after SIGINT"
  assert_eq "$(layout_no_wrap "$T")" "$BEFORE" "5. trap restored layout byte-identical"
  [ ! -d "$T/myapp" ] && ! find "$T" -maxdepth 1 -name '.wrap-staging.*' | grep -q . \
    && printf 'ok   - 5. no staging / half-wrapped state left\n' \
    || { printf 'FAIL - 5. residue after SIGINT rollback\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  assert_eq "$(git -C "$T" rev-parse HEAD)" "$PRE_HEAD" "5. repo HEAD intact after SIGINT"
else
  kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  printf 'ok   - 5. SKIP SIGINT injection (staging window not observed in this harness)\n'
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. Mode detection — all six rows
# ══════════════════════════════════════════════════════════════════════════════
echo "── 6. mode detection (six rows) ──" >&2
detect() { /bin/bash "$WRAP" --detect --workspace-dir "$1" 2>/dev/null; }

D="$(mktemp -d)"; assert_eq "$(detect "$D")" "fresh" "6a. empty folder → fresh"
D="$(mktemp -d)"; mkdir -p "$D/scripts/lib"; : > "$D/scripts/lib/workspace.sh"
assert_eq "$(detect "$D")" "upgrade" "6b. existing workspace → upgrade"
D="$(mk_repo)"; assert_eq "$(detect "$D")" "wrap" "6c. git repo root (.git dir) → wrap"
D="$(mk_repo)"; rm -rf "$D/.git"; printf 'gitdir: /x/.git/worktrees/y\n' > "$D/.git"
assert_eq "$(detect "$D")" "refuse:gitfile" "6d. .git-as-file → refuse:gitfile"
D="$(mk_repo)"; mkdir -p "$D/sub"; assert_eq "$(detect "$D/sub")" "refuse:below-root" "6e. below root → refuse:below-root"
D="$(mktemp -d)/bare.git"; git init -q --bare "$D"; assert_eq "$(detect "$D")" "refuse:bare" "6f. bare repo → refuse:bare"

assert_done
