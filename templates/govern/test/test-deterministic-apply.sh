#!/usr/bin/env bash
# Proves deterministic-apply.sh resolves a mechanical ticket with ZERO model turns, and that every
# ambiguity guard exits 10 (= "fall through to a normal worker") instead of landing a wrong patch.
#
# Hermetic: a stub workspace, a real throwaway git repo for the sub-repo, a hand-seeded scout cache
# (the cache-read path takes no model call), and a `claude` on PATH that RECORDS any invocation —
# every case asserts that recorder file was never written.
#
# Covered:
#   - kill switch default/0 → exit 10 immediately, no stdout
#   - a clean applicable patch → exit 0, report JSON with the `zeroModel` marker, commit landed
#   - the extracted patch is BYTE-IDENTICAL to the cached diff (trailing newline survives)
#   - a patch that fails `git apply --check` → exit 10
#   - a patch touching a path OUTSIDE the scout's measured targetPaths → exit 10
#   - more files than GOVERN_DETERMINISTIC_MAX_FILES → exit 10
#   - a failing verify command → exit 10 AND the working tree is reverted
#   - no verify command configured → exit 10 (verification is required by default)
#   - a dirty sub-repo → exit 10
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
APPLY="$DIR/../deterministic-apply.sh"

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed";  exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/wt" "$T/logs" "$T/bin"

# A `claude` that RECORDS instead of running. Any invocation from the script under test writes this
# file; every case below asserts it does not exist. (GOVERN_CLAUDE_BIN points here too.)
CLAUDE_CALLS="$T/claude-calls.txt"
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKED\n' >> "$CLAUDE_CALLS"
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"
export GOVERN_CLAUDE_BIN="$T/bin/claude"

# ── the sub-repo (`alpha`, per mk_ws_stub) ──────────────────────────────────────────────────────
mkdir -p "$T/alpha"
cat > "$T/alpha/config.js" <<'EOF'
module.exports = {
  retries: 1,
  timeout: 30,
};
EOF
printf 'x\n' > "$T/alpha/other.js"
git -C "$T/alpha" init -q
git -C "$T/alpha" checkout -q -b main 2>/dev/null || true
git -C "$T/alpha" config user.email t@t.t
git -C "$T/alpha" config user.name t
git -C "$T/alpha" add -A
git -C "$T/alpha" commit -qm init
PRISTINE_CONFIG="$T/pristine-config.js"; cp "$T/alpha/config.js" "$PRISTINE_CONFIG"

# ── worktree stub: a standalone COPY of the workspace's alpha checkout ───────────────────────────
cat > "$T/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
set -e
wt="$T/wt/\$1"
rm -rf "\$wt"; mkdir -p "\$wt"
cp -R "$T/alpha" "\$wt/alpha"
git -C "\$wt/alpha" checkout -q -b "\$1"
echo "\$wt"
EOF
chmod +x "$T/fake-worktree.sh"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
GOOD_DIFF="$T/good.diff"
cat > "$GOOD_DIFF" <<'EOF'
--- a/alpha/config.js
+++ b/alpha/config.js
@@ -1,4 +1,4 @@
 module.exports = {
-  retries: 1,
+  retries: 3,
   timeout: 30,
 };
EOF

BAD_DIFF="$T/bad.diff"   # context lines that do not exist in the file → git apply --check fails
cat > "$BAD_DIFF" <<'EOF'
--- a/alpha/config.js
+++ b/alpha/config.js
@@ -1,3 +1,3 @@
 module.exports = {
-  retries: 99,
+  retries: 3,
   timeout: 30,
EOF

OUTSIDE_DIFF="$T/outside.diff"   # a real, applicable edit — but to a path the scout never measured
cat > "$OUTSIDE_DIFF" <<'EOF'
--- a/alpha/other.js
+++ b/alpha/other.js
@@ -1 +1 @@
-x
+y
EOF

TWOFILE_DIFF="$T/twofile.diff"
cat "$GOOD_DIFF" "$OUTSIDE_DIFF" > "$TWOFILE_DIFF"

# seed_case <N> <diff-file> <targetPaths-json> — hand-writes the scout cache the script reads.
seed_case() {
  local n="$1" diff="$2" paths="$3"
  local d="$T/logs/ticket-$n"   # split: a later `local` can't read an earlier one in the SAME statement
  mkdir -p "$d"
  jq -n --argjson n "$n" --argjson paths "$paths" --rawfile diff "$diff" \
    '{ticket:$n, scoutModel:"haiku", ts:0,
      scope:{files:1, repos:1, testsCover:true, precedent:true, changeKind:"local",
             fixDirection:"concrete", targetPaths:$paths, precedentCommit:"", testCommand:"",
             deterministic:{kind:"config-default", rationale:"flip a default", diff:$diff}}}' \
    > "$d/scout.json"
}

# run <extra-env...> -- <args...>; sets RC and OUT.
run_apply() { # <ticket> [env assignments...]
  local n="$1"; shift
  set +e
  OUT="$(env GOVERN_WS_ROOT="$T" GOVERN_LOG_ROOT="$T/logs" \
      GOVERN_WORKTREE_CMD="$T/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$T/bin/claude" \
      "$@" "$APPLY" --dry-run "$n" 2>"$T/err-$n.txt")"
  RC=$?
  set -e
}

ONE='["alpha/config.js"]'

# ── 1. kill switch: default (unset) and explicit 0 ──────────────────────────────────────────────
seed_case 1 "$GOOD_DIFF" "$ONE"
run_apply 1
assert_eq "$RC" "10" "kill switch unset (default 0) → exit 10"
assert_eq "$OUT" "" "kill switch unset → nothing on stdout"
assert_contains "$(cat "$T/err-1.txt")" "disabled (GOVERN_DETERMINISTIC=0)" "logs the disabled reason"

run_apply 1 GOVERN_DETERMINISTIC=0
assert_eq "$RC" "10" "GOVERN_DETERMINISTIC=0 → exit 10"

# ── 2. the happy path: a clean applicable patch, zero model turns ───────────────────────────────
seed_case 2 "$GOOD_DIFF" "$ONE"
run_apply 2 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true" \
            _GOVERN_DET_PATCH_COPY="$T/seen-patch.diff"
assert_eq "$RC" "0" "clean applicable patch → exit 0"
assert_eq "$(printf '%s' "$OUT" | jq -r '.status')"            "resolved" "report status=resolved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.zeroModel')"         "true"     "report carries the zeroModel marker"
assert_eq "$(printf '%s' "$OUT" | jq -r '.deterministic.kind')" "config-default" "report echoes the scout kind"
assert_eq "$(printf '%s' "$OUT" | jq -r '.deterministic.repo')" "alpha"    "report names the sub-repo"
assert_eq "$(printf '%s' "$OUT" | jq -r '.deterministic.files')" "1"       "report counts the patched files"
assert_eq "$(printf '%s' "$OUT" | jq -r '.deterministic.verified')" "true" "report records that verification ran"
assert_eq "$(printf '%s' "$OUT" | jq -r '.deterministic.dryRun')" "true"   "--dry-run is marked in the report"
assert_eq "$(printf '%s' "$OUT" | jq -r '.lessonPatch')"       "null"     "lessonPatch is null"
assert_eq "$(printf '%s' "$OUT" | jq -r '.newTickets|length')" "0"        "newTickets is empty"
assert_eq "$(printf '%s' "$OUT" | jq -r '.escalation')"        "null"     "escalation is null"
assert_contains "$(grep 'retries' "$T/wt/ticket-2/alpha/config.js")" "retries: 3" "the patch landed in the worktree"
assert_eq "$(git -C "$T/wt/ticket-2/alpha" log --oneline | wc -l | tr -d ' ')" "2" "a commit was created"
assert_eq "$(git -C "$T/wt/ticket-2/alpha" status --porcelain)" "" "worktree is clean after the commit"
assert_eq "$(git -C "$T/alpha" status --porcelain)" "" "the source checkout was never touched"

# ── 3. byte-exactness: the extracted patch == the cached diff, trailing newline included ────────
if cmp -s "$GOOD_DIFF" "$T/seen-patch.diff"; then
  assert_eq "ok" "ok" "extracted patch is BYTE-IDENTICAL to the cached diff (trailing newline survives)"
else
  assert_eq "$(od -c "$T/seen-patch.diff" | tail -2)" "$(od -c "$GOOD_DIFF" | tail -2)" \
    "extracted patch is BYTE-IDENTICAL to the cached diff (trailing newline survives)"
fi
assert_eq "$(tail -c 1 "$T/seen-patch.diff" | od -An -tx1 | tr -d ' \n')" "0a" \
  "extracted patch ends in exactly one newline"

# ── 4. git apply --check fails → 10 ─────────────────────────────────────────────────────────────
seed_case 4 "$BAD_DIFF" "$ONE"
run_apply 4 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "patch that fails git apply --check → exit 10"
assert_eq "$OUT" "" "failed --check → nothing on stdout"
assert_contains "$(cat "$T/err-4.txt")" "does not apply cleanly" "logs the apply-check reason"

# ── 5. a path outside the scout's measured targetPaths → 10 ─────────────────────────────────────
seed_case 5 "$OUTSIDE_DIFF" "$ONE"
run_apply 5 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "patch touching a path outside targetPaths → exit 10"
assert_contains "$(cat "$T/err-5.txt")" "outside the scout's measured targetPaths" "logs the out-of-scope path"

# ── 6. too many files → 10 ──────────────────────────────────────────────────────────────────────
seed_case 6 "$TWOFILE_DIFF" '["alpha/config.js","alpha/other.js"]'
run_apply 6 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_MAX_FILES=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "more files than GOVERN_DETERMINISTIC_MAX_FILES → exit 10"
assert_contains "$(cat "$T/err-6.txt")" "GOVERN_DETERMINISTIC_MAX_FILES=1" "logs the file-count ceiling"
# …and the same patch under a ceiling of 2 is accepted, so case 6 isolates the ceiling itself.
run_apply 6 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_MAX_FILES=2 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "0" "the SAME 2-file patch under a ceiling of 2 → exit 0 (the ceiling was the only blocker)"

# ── 7. verification failure → 10, and the tree is reverted ──────────────────────────────────────
seed_case 7 "$GOOD_DIFF" "$ONE"
run_apply 7 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="exit 3"
assert_eq "$RC" "10" "failing verify command → exit 10"
assert_contains "$(cat "$T/err-7.txt")" "verification failed (rc=3)" "logs the verify failure"
if cmp -s "$PRISTINE_CONFIG" "$T/wt/ticket-7/alpha/config.js"; then
  assert_eq "ok" "ok" "a failed verification REVERTS the applied patch"
else
  assert_eq "$(cat "$T/wt/ticket-7/alpha/config.js")" "$(cat "$PRISTINE_CONFIG")" \
    "a failed verification REVERTS the applied patch"
fi
assert_eq "$(git -C "$T/wt/ticket-7/alpha" log --oneline | wc -l | tr -d ' ')" "1" "no commit after a failed verification"

# ── 8. no verify command configured → 10 (verification is required by default) ──────────────────
seed_case 8 "$GOOD_DIFF" "$ONE"
run_apply 8 GOVERN_DETERMINISTIC=1
assert_eq "$RC" "10" "no GOVERN_DETERMINISTIC_VERIFY_CMD → exit 10 by default"
assert_contains "$(cat "$T/err-8.txt")" "verification is required" "logs the missing-verify reason"

# ── 9. a dirty sub-repo → 10 ────────────────────────────────────────────────────────────────────
seed_case 9 "$GOOD_DIFF" "$ONE"
printf 'dirt\n' >> "$T/alpha/other.js"
run_apply 9 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "dirty sub-repo → exit 10"
assert_contains "$(cat "$T/err-9.txt")" "is dirty" "logs the dirty-repo reason"
git -C "$T/alpha" checkout -- other.js

# ── 10. no scout cache at all → 10 ──────────────────────────────────────────────────────────────
run_apply 11 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "no cached scout survey → exit 10"
assert_contains "$(cat "$T/err-11.txt")" "no cached deterministic verdict" "logs the missing-cache reason"

# ── 11. THE constraint: not one model invocation on any path above ──────────────────────────────
assert_eq "$([[ -f "$CLAUDE_CALLS" ]] && cat "$CLAUDE_CALLS" || printf '')" "" \
  "ZERO claude invocations across every case"
# Static backstop: no line of the script may EXECUTE a claude binary. Every `claude` token in the
# file lives in a comment or a knob name, never in command position.
assert_eq "$(grep -nE '^[[:space:]]*[^#]*(\$\{?GOVERN_CLAUDE_BIN|claude)[[:space:]]+-p[[:space:]]' "$APPLY" | wc -l | tr -d ' ')" \
  "0" "no 'claude -p' invocation anywhere in the script"

assert_done
