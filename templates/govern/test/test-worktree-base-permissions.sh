#!/usr/bin/env bash
# Regression for ticket #175: the default worktree base moves INSIDE the workspace root, so a
# worker's Read/Write/Edit under it aren't denied outside a bypass parent (the sibling default put
# them outside the working-directory grant entirely). An operator-chosen EXTERNAL base still works,
# but now gets an explicit permissions.additionalDirectories grant + a doctor trust line instead of
# silently relying on a permission a fresh workspace was never granted.
#
# Contract:
#   1. No --worktree-base flag -> the default is $WORKSPACE_DIR/.wt (inside the root), and it's in
#      .gitignore.
#   2. Inside-root base: settings.json carries NO permissions.additionalDirectories, but DOES carry
#      claudeMdExcludes for the worktree's own on-disk duplicate of the root CLAUDE.md.
#   3. Outside-root base (fresh scaffold): settings.json gets BOTH additionalDirectories and
#      claudeMdExcludes.
#   4. settings-merge (the /shiploop:update path -- no --worktree-base flag is ever passed) reads
#      the base back out of the workspace's OWN scripts/lib/workspace.sh, merges the grant without
#      touching a pre-existing unrelated entry, and is idempotent on a second run.
#   5. doctor.sh: an inside-root base prints no trust line at all; an outside-root base reports
#      trusted / not-yet-trusted / unknown from ~/.claude.json's hasTrustDialogAccepted, correctly
#      telling an explicit `false` apart from the key being absent altogether.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout -- scaffold.sh + templates/ at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── 1. default base (no --worktree-base) is inside the workspace root, and gitignored ──────────
W1="$ROOT/ws1"; mkdir -p "$W1"
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --component all --yes >/tmp/wtb-w1.log 2>&1
rc=$?
assert_eq "$rc" "0" "1. fresh scaffold with no --worktree-base exits 0"
assert_contains "$(cat "$W1/scripts/lib/workspace.sh")" "WORKTREE_BASE=\"\${WORKTREE_BASE:-$W1/.wt}\"" \
  "1. default WORKTREE_BASE is \$WORKSPACE_DIR/.wt"
assert_contains "$(cat "$W1/.gitignore")" ".wt/" "1. .gitignore carries .wt/"

# ── 2. inside-root base: no additionalDirectories, but claudeMdExcludes IS written ─────────────
assert_eq "$(jq -r '.permissions.additionalDirectories // "none"' "$W1/.claude/settings.json")" "none" \
  "2. inside-root base gets no additionalDirectories entry"
assert_contains "$(jq -r '.claudeMdExcludes[]?' "$W1/.claude/settings.json")" "$W1/.wt/*/CLAUDE.md" \
  "2. claudeMdExcludes covers the worktree's own duplicate root CLAUDE.md"

# ── 3. outside-root base (fresh scaffold): additionalDirectories + claudeMdExcludes ────────────
W2="$ROOT/ws2"; mkdir -p "$W2"
EXT="$ROOT/external.wt"
bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$EXT" --component all --yes >/tmp/wtb-w2.log 2>&1
rc=$?
assert_eq "$rc" "0" "3. fresh scaffold with an explicit outside --worktree-base exits 0"
assert_contains "$(jq -r '.permissions.additionalDirectories[]?' "$W2/.claude/settings.json")" "$EXT" \
  "3. outside base gets an additionalDirectories entry"
assert_contains "$(jq -r '.claudeMdExcludes[]?' "$W2/.claude/settings.json")" "$EXT/*/CLAUDE.md" \
  "3. and a claudeMdExcludes entry for its own duplicate CLAUDE.md"

# ── 4. settings-merge (the /shiploop:update path) reads the base from workspace.sh, preserves a
# pre-existing unrelated entry, and is idempotent ──────────────────────────────────────────────
W3="$ROOT/ws3"; mkdir -p "$W3/.claude"
cat > "$W3/.claude/settings.json" <<'JSON'
{ "hooks": {}, "permissions": { "additionalDirectories": ["/some/other/dir"] }, "claudeMdExcludes": ["/some/other/CLAUDE.md"] }
JSON
EXT2="$ROOT/external2.wt"
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$EXT2" --component workspace-sh --yes >/tmp/wtb-w3.log 2>&1
# settings-merge with NO --worktree-base flag -- exactly what /shiploop:update passes.
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" --pm npm --component settings-merge \
  >/tmp/wtb-w3b.log 2>&1
rc=$?
assert_eq "$rc" "0" "4. settings-merge with no --worktree-base flag exits 0"
assert_contains "$(jq -r '.permissions.additionalDirectories[]?' "$W3/.claude/settings.json")" "/some/other/dir" \
  "4. a pre-existing additionalDirectories entry survives"
assert_contains "$(jq -r '.permissions.additionalDirectories[]?' "$W3/.claude/settings.json")" "$EXT2" \
  "4. and the base already recorded in the workspace's OWN workspace.sh is added, though --worktree-base was never passed"
assert_contains "$(jq -r '.claudeMdExcludes[]?' "$W3/.claude/settings.json")" "/some/other/CLAUDE.md" \
  "4. a pre-existing claudeMdExcludes entry survives"
before="$(cat "$W3/.claude/settings.json")"
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" --pm npm --component settings-merge \
  >/dev/null 2>&1
after="$(cat "$W3/.claude/settings.json")"
assert_eq "$after" "$before" "4. re-running settings-merge is idempotent (no duplicate entries)"

# ── 5. doctor.sh trust line ──────────────────────────────────────────────────────────────────
FAKE_HOME_TRUSTED="$ROOT/home-trusted"; mkdir -p "$FAKE_HOME_TRUSTED"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$W2" > "$FAKE_HOME_TRUSTED/.claude.json"
out="$(HOME="$FAKE_HOME_TRUSTED" bash "$W2/scripts/doctor.sh" 2>&1)"
assert_contains "$out" "outside the workspace and trusted" "5. outside base + trusted -> ok line names it trusted"

FAKE_HOME_UNTRUSTED="$ROOT/home-untrusted"; mkdir -p "$FAKE_HOME_UNTRUSTED"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' "$W2" > "$FAKE_HOME_UNTRUSTED/.claude.json"
out="$(HOME="$FAKE_HOME_UNTRUSTED" bash "$W2/scripts/doctor.sh" 2>&1)"
assert_contains "$out" "NOT trusted yet" "5. outside base + explicit false -> warns NOT trusted (not 'unknown')"

FAKE_HOME_NOFILE="$ROOT/home-nofile"; mkdir -p "$FAKE_HOME_NOFILE"
out="$(HOME="$FAKE_HOME_NOFILE" bash "$W2/scripts/doctor.sh" 2>&1)"
assert_contains "$out" "trust state unknown" "5. outside base + no ~/.claude.json -> unknown, not silently skipped"

out="$(HOME="$FAKE_HOME_TRUSTED" bash "$W1/scripts/doctor.sh" 2>&1)"
assert_not_contains "$out" "worktree base" "5. inside-root base: no trust line printed at all"

assert_done
