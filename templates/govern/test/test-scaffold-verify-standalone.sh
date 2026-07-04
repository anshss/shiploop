#!/usr/bin/env bash
# Regression for scaffold.sh --verify running standalone against an
# already-scaffolded workspace — no --org, no --repos, no --component.
#
# Pre-1.4.2 behavior: `scaffold.sh --verify` alone died with
#   "ERROR: --org is required for workspace.sh"
# because the default COMPONENT=all re-ran the workspace.sh writer even
# though --verify is a read-only check.
#
# Contract:
#   1. scaffold.sh --verify (no --org, no --repos) against a scaffolded
#      workspace exits 0 — proving the writer is bypassed.
#   2. --diff-only alone (no --org) also works on the same scaffold.
#   3. scaffold.sh --verify from INSIDE the workspace (no --workspace-dir)
#      also works — default WORKSPACE_DIR to cwd in read-only mode.
#   4. --component X --verify still needs its normal inputs and still runs
#      the writer for that one component — read-only mode is only entered
#      when the caller passed NEITHER --component nor --org/--repos.
#   5. If workspace.sh has a real syntax error, --verify surfaces it
#      (verify_scripts stays active) — the fix only skips the WRITER, not
#      the parse gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout — scaffold.sh + templates/ at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
W="$ROOT/ws"; mkdir -p "$W"

# ── Seed a fresh scaffold ──────────────────────────────────────────────────
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
  --pm npm --org standalone-verify-org \
  --repos "alpha:3000:echo alpha,web:3001:echo web" \
  --merge-allowlist "alpha" --worktree-base "$W.wt" --yes >/tmp/scaf-svs.log 2>&1
rc=$?
assert_eq "$rc" "0" "0. fresh scaffold succeeds"

# ── 1. scaffold.sh --verify --workspace-dir <ws>, no --org, no --repos ────
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --verify 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. --verify standalone (no --org) exits 0"
assert_contains "$out" "verify-only mode" "1. announces verify-only mode"
# The pre-1.4.2 failure signature: it MUST NOT appear.
if grep -qF "org is required for workspace.sh" <<<"$out"; then
  printf 'FAIL - 1. old failure ("--org is required for workspace.sh") resurfaced\n%s\n' "$out"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - 1. no --org demand on the standalone verify path\n'
fi

# ── 2. --diff-only alone against the same scaffold → in-sync, exit 0 ──────
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "0" "2. --diff-only standalone against fresh scaffold → in-sync"

# ── 3. Run scaffold --verify from INSIDE the workspace (no --workspace-dir)
# Emulates the operator's natural invocation. WORKSPACE_DIR should default
# to cwd when read-only mode is inferred.
( cd "$W" && bash "$SCAFFOLD" --templates "$TEMPLATES" --verify >/tmp/scaf-cwd.log 2>&1 ); rc=$?
assert_eq "$rc" "0" "3. --verify from inside the workspace (no --workspace-dir) exits 0"

# ── 4. --component X --verify still writes (read-only mode NOT entered) ───
# component workspace-sh needs --org, so with --component set the writer
# path stays active. Without --org we still expect the old "org is required"
# error — the fix must NOT swallow that path.
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
        --component workspace-sh --verify 2>&1)"; rc=$?
assert_eq "$rc" "1" "4. --component workspace-sh --verify without --org → still fails"
assert_contains "$out" "org is required" "4. explicit --component keeps the writer path"

# ── 5. Broken workspace.sh → --verify surfaces the parse error ────────────
cp "$W/scripts/lib/workspace.sh" "$W/scripts/lib/workspace.sh.bak"
printf '\nBROKEN(((\n' >> "$W/scripts/lib/workspace.sh"
out="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --verify 2>&1)"; rc=$?
assert_eq "$rc" "1" "5. broken workspace.sh → --verify exits nonzero"
assert_contains "$out" "verification failed" "5. verify surfaces the parse error"
mv "$W/scripts/lib/workspace.sh.bak" "$W/scripts/lib/workspace.sh"

assert_done
