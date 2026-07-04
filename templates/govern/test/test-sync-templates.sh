#!/usr/bin/env bash
# Regression for sync-templates.sh — the widened-surface drift reporter.
#
# It must (1) report IN-SYNC + exit 0 when no mirrored commits land past the marker; (2) report
# DRIFT + exit 3 listing the unported commits when a mirrored file changes; (3) NOT count a commit
# that only touches the marker file as drift; (4) advance the marker with --mark so a landed batch
# clears the drift; (5) surface ONLY mirrored files in --files (a live-only file with no template
# counterpart is filtered out); (6) track the governor/ prompt dir too; (7) track mirrored files
# OUTSIDE govern/ (scripts/worktree/*, hook scripts) now that the surface is widened; (8) NOT flag
# a workspace-specific file that has no template counterpart; (9) exclude the workspace.sh config
# sink even though a template counterpart exists.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
TOOL="$(cd "$DIR/.." && pwd)/sync-templates.sh"

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts/govern/test"
TPL_ROOT="$SANDBOX/templates"
TPL="$TPL_ROOT/govern"
mkdir -p "$TPL/test"

git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo 'echo run' > "$REPO/scripts/govern/run-loop.sh"
echo 'echo assert' > "$REPO/scripts/govern/test/assert.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

echo 'echo run' > "$TPL/run-loop.sh"

export GOVERN_DIR="$REPO/scripts/govern"
export GOVERN_SYNC_MARKER="$REPO/scripts/govern/.templates-synced-at"
export GOVERN_TEMPLATE_DIR="$TPL"

# ── 1. initialize marker at BASE → in-sync, exit 0 ──────────────────────────────────────────────
bash "$TOOL" --mark "$BASE" >/dev/null
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "in-sync → exit 0"
assert_contains "$out" "in sync" "in-sync message"

# ── 2. a marker-only commit is NOT drift ────────────────────────────────────────────────────────
echo "# touched" >> "$REPO/scripts/govern/.templates-synced-at"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: touch marker"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "marker-only commit is not drift → exit 0"

# ── 3. a govern-script change IS drift → exit 3, lists the commit ───────────────────────────────
echo 'echo run v2' > "$REPO/scripts/govern/run-loop.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "fix(govern): tweak run-loop (#999)"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "govern change → exit 3"
assert_contains "$out" "tweak run-loop (#999)" "drift lists the commit subject"
assert_contains "$out" "Batch these into ONE" "drift nudges batch, not per-change ticket"

# ── 4. --files surfaces ONLY mirrored files (a live-only file is filtered out) ───────────────────
echo 'echo new test' > "$REPO/scripts/govern/test/test-newthing.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test(govern): add live-only test"
files="$(bash "$TOOL" --files)"
assert_contains "$files" "mirrored" "run-loop.sh classified mirrored"
assert_contains "$files" "scripts/govern/run-loop.sh" "run-loop.sh listed"
assert_not_contains "$files" "test-newthing.sh" "live-only file (no counterpart) is NOT surfaced"

# ── 5. --diff emits the change; --mark to HEAD clears drift ─────────────────────────────────────
diff_out="$(bash "$TOOL" --diff)"
assert_contains "$diff_out" "run v2" "diff carries the ported change"
bash "$TOOL" --mark >/dev/null
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "after --mark, drift cleared → exit 0"

# ── 6. the governor/ prompt dir is ALSO tracked — a worker-prompt change is drift+mirrored ─────
PROMPTS="$REPO/governor"; mkdir -p "$PROMPTS"
PTPL="$TPL_ROOT/governor"; mkdir -p "$PTPL"
echo 'prompt v1' > "$PROMPTS/worker-prompt.md"
echo 'prompt v1' > "$PTPL/worker-prompt.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: seed governor prompt"
bash "$TOOL" --mark >/dev/null
export GOVERN_PROMPTS_DIR="$PROMPTS" GOVERN_PROMPTS_TEMPLATE_DIR="$PTPL"
echo 'prompt v2 — capability section' > "$PROMPTS/worker-prompt.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "docs(governor): worker-prompt capability section"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "governor/ prompt change → drift exit 3"
assert_contains "$out" "worker-prompt capability section" "drift lists the governor commit"
files="$(bash "$TOOL" --files)"
assert_contains "$files" "governor/worker-prompt.md" "worker-prompt.md listed"
assert_contains "$files" "mirrored" "worker-prompt.md classified mirrored"
bash "$TOOL" --mark >/dev/null

# ── 7. WIDENED SURFACE: a mirrored NON-govern change (worktree + a hook script) IS drift ─────────
mkdir -p "$TPL_ROOT/worktree" "$TPL_ROOT/hooks"
echo 'echo new' > "$TPL_ROOT/worktree/new.sh"
echo 'echo snap' > "$TPL_ROOT/hooks/session-snapshot.sh"
mkdir -p "$REPO/scripts/worktree"
echo 'echo new' > "$REPO/scripts/worktree/new.sh"
echo 'echo snap' > "$REPO/scripts/session-snapshot.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: seed worktree + hook scripts"
bash "$TOOL" --mark >/dev/null
echo 'echo new v2' > "$REPO/scripts/worktree/new.sh"
echo 'echo snap v2' > "$REPO/scripts/session-snapshot.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(harness): improve worktree + snapshot (#7)"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "mirrored non-govern change (worktree + hook) → drift exit 3"
assert_contains "$out" "improve worktree + snapshot (#7)" "drift lists the widened-surface commit"
files="$(bash "$TOOL" --files)"
assert_contains "$files" "scripts/worktree/new.sh" "worktree/new.sh surfaced (mirrored)"
assert_contains "$files" "scripts/session-snapshot.sh" "hook script surfaced (mirrored)"
bash "$TOOL" --mark >/dev/null

# ── 8. a workspace-SPECIFIC file with NO template counterpart is NOT flagged ─────────────────────
echo 'echo deploy' > "$REPO/scripts/deploy-check.sh"
mkdir -p "$REPO/scripts/lib"
echo 'REPOS=(a b)' > "$REPO/scripts/lib/repos.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: workspace-specific deploy-check + repos.sh"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "workspace-specific-only change (no counterpart) → NOT drift, exit 0"
assert_contains "$out" "in sync" "in-sync message despite specific-file churn"
files="$(bash "$TOOL" --files)"
assert_contains "$files" "none" "--files reports none (no mirrored drift)"
assert_not_contains "$files" "deploy-check.sh" "deploy-check.sh (specific) NOT surfaced"
assert_not_contains "$files" "repos.sh" "lib/repos.sh (specific) NOT surfaced"

# ── 9. workspace.sh is the config sink — excluded even though templates/lib/workspace.sh exists ──
mkdir -p "$TPL_ROOT/lib"
echo 'CONFIG=1' > "$TPL_ROOT/lib/workspace.sh"
echo 'CONFIG=live v2' > "$REPO/scripts/lib/workspace.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: tweak workspace.sh config"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "workspace.sh config change → NOT drift (config sink excluded), exit 0"

assert_done
