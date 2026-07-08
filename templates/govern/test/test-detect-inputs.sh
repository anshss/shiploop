#!/usr/bin/env bash
# Hermetic tests for templates/lib/detect-inputs.sh (the one-shot interview-
# defaults probe used by /shiploop:setup W0 / Phase 1).
#
# Like wrap.sh, detect-inputs.sh lives only in the hub/template checkout, so
# this test SKIPs when run from a scaffolded workspace where it is absent.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

DETECT="$(cd "$DIR/../../lib" 2>/dev/null && pwd)/detect-inputs.sh"
[ -f "$DETECT" ] || { echo "SKIP: detect-inputs.sh not found (installed workspace, not the hub) — $DETECT" >&2; exit 77; }

# Run with gh stripped from PATH so visibility is deterministic ("unknown").
run_detect() { PATH=/usr/bin:/bin /bin/bash "$DETECT" "$@"; }

mk_npm_repo() { # <dir> <origin-url> <dev-script> <lockfile>
  mkdir -p "$1"
  ( cd "$1"; git init -q; git config user.email t@t; git config user.name t
    [ -n "$2" ] && git remote add origin "$2"
    printf '{"scripts":{"dev":"%s"}}\n' "$3" > package.json
    [ -n "$4" ] && : > "$4" )
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. fresh mode — multi-repo: ports, collisions, lockfile signals, org
# ══════════════════════════════════════════════════════════════════════════════
echo "── 1. fresh mode ──" >&2
W="$(mktemp -d)"
mk_npm_repo "$W/web" "git@github.com:acme/web.git" "next dev -p 3000" "pnpm-lock.yaml"
mk_npm_repo "$W/api" "https://github.com/acme/api.git" "PORT=3000 node server.js" "package-lock.json"
mkdir -p "$W/svc"; ( cd "$W/svc"; git init -q; printf 'module m\n' > go.mod )
mkdir -p "$W/not-a-repo"   # no .git — must be ignored

out="$(run_detect --workspace-dir "$W" --mode fresh)"; rc=$?
assert_eq "$rc" "0" "1. fresh detect exits 0"
assert_eq "$(grep -c '^repo=' <<<"$out")" "3" "1. three repos detected (non-repo dir ignored)"
assert_contains "$out" "org=acme" "1. org parsed from first origin"
assert_contains "$out" "root_pm=npm" "1. root PM defaults to npm (no root lockfile)"
WP="$(cd "$W" && pwd -P)"   # detect-inputs canonicalizes (macOS /var → /private/var)
assert_contains "$out" "worktree_base=$(dirname "$WP")/$(basename "$WP").wt" "1. worktree base = sibling .wt"
assert_contains "$out" "|pnpm dev|" "1. pnpm lockfile → pnpm dev"
assert_contains "$out" "|npm run dev|" "1. package-lock → npm run dev"
assert_contains "$out" "|go run ./...|" "1. go.mod fallback"
assert_contains "$out" "repos_spec=" "1. repos_spec emitted"
# port collision: both claim 3000; exactly one must be bumped to 3001
p_web="$(sed -n 's/^repo=web|\([0-9]*\)|.*/\1/p' <<<"$out")"
p_api="$(sed -n 's/^repo=api|\([0-9]*\)|.*/\1/p' <<<"$out")"
[ "$p_web" != "$p_api" ] && printf 'ok   - 1. colliding ports resolved (%s vs %s)\n' "$p_api" "$p_web" \
  || { printf 'FAIL - 1. port collision unresolved (both %s)\n' "$p_web"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
case "$p_web$p_api" in *3000*) : ;; *) printf 'FAIL - 1. neither repo kept port 3000\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;; esac
assert_contains "$out" "|unknown" "1. visibility=unknown when gh is unavailable"

# ══════════════════════════════════════════════════════════════════════════════
# 2. wrap mode — single repo, name from origin, empty-port spec shape
# ══════════════════════════════════════════════════════════════════════════════
echo "── 2. wrap mode ──" >&2
R="$(mktemp -d)/proj-folder"
mk_npm_repo "$R" "https://github.com/anshss/vibelab.git" "next dev" "package-lock.json"
out="$(run_detect --workspace-dir "$R" --mode wrap)"; rc=$?
assert_eq "$rc" "0" "2. wrap detect exits 0"
assert_contains "$out" "repo=vibelab|" "2. NAME from origin (not the folder name)"
assert_contains "$out" "org=anshss" "2. org from https origin"
assert_contains "$out" "repos_spec=vibelab::npm run dev" "2. empty port → name::cmd spec"

# no origin → folder name
R2="$(mktemp -d)/bareproj"
mk_npm_repo "$R2" "" "vite" "yarn.lock"
out="$(run_detect --workspace-dir "$R2" --mode wrap)"
assert_contains "$out" "repo=bareproj|" "2. no origin → folder-name fallback"
assert_contains "$out" "|yarn dev|" "2. yarn lockfile signal"

# ══════════════════════════════════════════════════════════════════════════════
# 3. argument errors
# ══════════════════════════════════════════════════════════════════════════════
echo "── 3. argument errors ──" >&2
run_detect --workspace-dir "$R" >/dev/null 2>&1; assert_eq "$?" "2" "3. missing --mode → exit 2"
run_detect --workspace-dir "$R" --mode bogus >/dev/null 2>&1; assert_eq "$?" "2" "3. bad --mode → exit 2"

assert_done
