#!/usr/bin/env bash
# Regression for config-check.sh — the cheap no-auth smoke.
#
# Contract:
#   1. every required knob set → exit 0, prints resolved values, all helpers called
#   2. required knob missing (META_NAME empty) → exit 1, PROBLEM listed
#   3. --json → valid JSON with meta_root / repos / helpers / knobs / problems / warnings
#   4. optional lane misconfiguration → warning (not a problem)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/config-check.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT"
# mk_ws_stub omits knobs the config-check treats as required (META_NAME, ROOT_PM).
# Append them so case 1 exercises the full-pass path.
cat >> "$ROOT/scripts/lib/workspace.sh" <<'EOF'
META_NAME="testmeta"
ROOT_PM="npm"
EOF

# ── 1. every required knob set → exit 0 ────────────────────────────────────
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. every knob set → exit 0"
assert_contains "$out" "config-check" "1. banner printed"
assert_contains "$out" "REPOS" "1. REPOS listed"
assert_contains "$out" "wsp_repo_slug" "1. helper wsp_repo_slug called"
assert_contains "$out" "wsp_repo_localdir" "1. helper wsp_repo_localdir called"
assert_contains "$out" "every required knob resolves" "1. clean-summary line"

# ── 2. required knob missing → exit 1 ──────────────────────────────────────
sed -i.bak 's/META_NAME=.*/META_NAME=""/' "$ROOT/scripts/lib/workspace.sh"
rm -f "$ROOT/scripts/lib/workspace.sh.bak"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "2. missing META_NAME → exit 1"
assert_contains "$out" "META_NAME" "2. calls out the missing knob"
assert_contains "$out" "PROBLEMS" "2. PROBLEMS section printed"

# ── 3. --json → valid JSON with expected keys ──────────────────────────────
# Restore META_NAME first.
sed -i.bak 's/META_NAME=""/META_NAME="testmeta"/' "$ROOT/scripts/lib/workspace.sh"
rm -f "$ROOT/scripts/lib/workspace.sh.bak"
out="$(bash "$TOOL" --json 2>&1)"; rc=$?
assert_eq "$rc" "0" "3. --json → exit 0"
# jq exit codes: 0 valid, non-0 malformed. This is the JSON-validity assertion.
printf '%s' "$out" | jq -e '.meta_name and .repos and .helpers and .knobs' >/dev/null 2>&1 && \
  printf 'ok   - 3. JSON has meta_name / repos / helpers / knobs\n' || \
  { printf 'FAIL - 3. JSON schema mismatch\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 4. GOVERN_EXTERNALIZE_LANE=1 with empty REPO/SUBREPO → warning (not problem)
cat >> "$ROOT/scripts/lib/workspace.sh" <<'EOF'
export GOVERN_EXTERNALIZE_LANE=1
export GOVERN_EXTERNALIZE_REPO=""
export GOVERN_EXTERNALIZE_SUBREPO=""
EOF
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "4. partial lane → exit 0 (warning, not problem)"
assert_contains "$out" "notice" "4. notices section printed"
assert_contains "$out" "lane no-ops" "4. lane no-op notice"

# ── 5. root-remote status line (wrap-in-place "skip remote" surfaces first-class)
# Make the stub root a real git repo with a queue/ so govern::meta_root resolves to it.
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$ROOT/queue" && : > "$ROOT/queue/tickets.md"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "5. no-remote root → still exit 0 (warning, not a problem)"
assert_contains "$out" "root remote" "5. root remote status line printed"
assert_contains "$out" "DISABLED" "5. no-remote surfaces the CAS/sync DISABLED warning"

# ── 6. once a remote exists, the line flips to show it ──────────────────────
( cd "$ROOT" && git remote add origin https://example.com/acme/meta.git )
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "6. with remote → exit 0"
assert_contains "$out" "origin" "6. root remote line shows the remote"

# ── 7. --json carries root_remote ──────────────────────────────────────────
out="$(bash "$TOOL" --json 2>&1)"
printf '%s' "$out" | jq -e 'has("root_remote")' >/dev/null 2>&1 && \
  printf 'ok   - 7. JSON has root_remote key\n' || \
  { printf 'FAIL - 7. JSON missing root_remote\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

assert_done
