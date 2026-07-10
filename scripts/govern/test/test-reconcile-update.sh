#!/usr/bin/env bash
# Regression for /shiploop:update — locks the invariants the command
# depends on but doesn't own itself (scaffold.sh does the work; this test
# verifies scaffold.sh honors the promises /update makes to the operator).
#
# Contract:
#   1. --diff-only detects a fresh scaffold as in-sync (exit 0).
#   2. Mutating a mechanism script → --diff-only reports behind (exit 3).
#   3. A component bump (--component govern --yes) re-syncs → exit 0 again.
#   4. workspace.sh SENTINEL VALUE survives a component bump (preservation
#      guarantee — /update's core promise).
#   5. The .harness-version stamp is written on every scaffold run.
#   6. --component seeds does NOT overwrite an existing operator seed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout — scaffold.sh + templates/ + VERSION at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

W="$ROOT/ws"; mkdir -p "$W"
# ── Seed a fresh scaffold with a sentinel value in workspace.sh ────────────
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
  --pm npm --org sentinelorg --repos "alpha:3000:echo alpha,web:3001:echo web" \
  --merge-allowlist "alpha" --worktree-base "$W.wt" --yes >/tmp/scaf-init.log 2>&1
rc=$?
assert_eq "$rc" "0" "0. fresh scaffold succeeds"

# Add an operator-owned SENTINEL line in workspace.sh that a real operator would
# have edited by hand. /update MUST preserve this across bumps.
SENTINEL='# SENTINEL-DO-NOT-TOUCH: operator-edited value that must survive a bump'
printf '\n%s\nMY_CUSTOM_KNOB="preserve-me"\n' "$SENTINEL" >> "$W/scripts/lib/workspace.sh"

# ── 1. after full scaffold, --diff-only reports in-sync ─────────────────────
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. fresh scaffold → --diff-only exit 0 (in-sync)"
assert_contains "$out" "govern: in-sync" "1. govern in-sync"
assert_contains "$out" "core-scripts: in-sync" "1. core-scripts in-sync"

# ── 2. mutate a mechanism script → --diff-only detects behind ──────────────
echo "# drift injected" >> "$W/scripts/govern/run-loop.sh"
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "3" "2. mutated mechanism → --diff-only exit 3"
assert_contains "$out" "govern: behind" "2. govern reported behind"

# ── 3. --component govern --yes bumps → back in-sync ───────────────────────
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
  --component govern --yes >/tmp/scaf-bump.log 2>&1
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "0" "3. after component bump → --diff-only exit 0"

# ── 4. sentinel value in workspace.sh SURVIVED the bump (core /update guarantee)
if grep -qF "$SENTINEL" "$W/scripts/lib/workspace.sh"; then
  printf 'ok   - 4. workspace.sh sentinel line PRESERVED across bump\n'
else
  printf 'FAIL - 4. workspace.sh sentinel line LOST after bump\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
if grep -qF 'MY_CUSTOM_KNOB="preserve-me"' "$W/scripts/lib/workspace.sh"; then
  printf 'ok   - 4. workspace.sh MY_CUSTOM_KNOB PRESERVED across bump\n'
else
  printf 'FAIL - 4. workspace.sh MY_CUSTOM_KNOB LOST after bump\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# ── 5. .harness-version stamp exists + matches hub VERSION ─────────────────
stamp="$W/scripts/lib/.harness-version"
[ -f "$stamp" ] && printf 'ok   - 5. .harness-version stamp exists after bump\n' || \
  { printf 'FAIL - 5. stamp missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
stamp_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$stamp" 2>/dev/null)"
hub_v="$(bash "$SCAFFOLD" --version)"
assert_eq "$stamp_v" "$hub_v" "5. stamp value = hub VERSION"

# ── 6. --component seeds does NOT overwrite operator seed ──────────────────
# The seeds component is invoked by /update to fill absent seeds only.
printf 'OPERATOR CONTENT — must not be overwritten\n' > "$W/queue/tickets.md"
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
  --component seeds --yes >/tmp/scaf-seeds.log 2>&1
if grep -q '^OPERATOR CONTENT' "$W/queue/tickets.md"; then
  printf 'ok   - 6. seeds --component leaves existing operator seed untouched\n'
else
  printf 'FAIL - 6. seeds --component clobbered operator seed\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

assert_done
