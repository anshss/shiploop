#!/usr/bin/env bash
# K6 — content-aware drift: a hub→workspace CONVERGE (a /shiploop:update pull that
# rewrites a mirrored mechanism script to MATCH the current template) must NOT be
# reported as harness→hub drift. Before this fix, drift_commits() was purely
# commit-based, so a pull looked identical to a local improvement and every
# converge inflated the "N unported commits" count (verified live in aquanode:
# 3 of 5 "unported" commits were actually /shiploop:update pulls).
#
# Proves:
#   1. a commit whose post-state MATCHES the template (a pull-converge) → NOT drift → --check exit 0
#   2. a subsequent commit that DIVERGES from the template (a genuine local improvement) → drift exit 3
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-templates.sh"

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"; mkdir -p "$REPO/scripts/govern/test"
TPL_ROOT="$SANDBOX/templates"; TPL="$TPL_ROOT/govern"; mkdir -p "$TPL/test"

git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t

# The HUB's current template for run-loop.sh (what a pull would bring the workspace TO).
printf 'echo run\necho HUB_IMPROVEMENT_V2\n' > "$TPL/run-loop.sh"

# Workspace starts at an OLDER state (differs from the template — but that's the base).
printf 'echo run\n' > "$REPO/scripts/govern/run-loop.sh"
echo 'echo assert' > "$REPO/scripts/govern/test/assert.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

export GOVERN_DIR="$REPO/scripts/govern"
export GOVERN_SYNC_MARKER="$REPO/scripts/govern/.templates-synced-at"
export GOVERN_TEMPLATE_DIR="$TPL"

bash "$TOOL" --mark "$BASE" >/dev/null

# ── 1. simulate a /shiploop:update pull-converge: rewrite the mirrored file to MATCH the template ──
printf 'echo run\necho HUB_IMPROVEMENT_V2\n' > "$REPO/scripts/govern/run-loop.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore(harness): converge to hub v2 (/shiploop:update)"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "pull-converge (post-state == template) → NOT drift, exit 0"
assert_contains "$out" "in sync" "converge → in-sync message (pull not counted as drift)"

# ── 2. a genuine local improvement that DIVERGES from the template IS still drift ─────────────────
printf 'echo run\necho HUB_IMPROVEMENT_V2\necho LOCAL_TWEAK\n' > "$REPO/scripts/govern/run-loop.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(govern): genuine local improvement (#12)"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "local improvement (post-state != template) → drift exit 3"
assert_contains "$out" "genuine local improvement (#12)" "drift lists the divergent local commit"

assert_done
