#!/usr/bin/env bash
# Proves deterministic-apply.sh resolves a mechanical ticket with ZERO model turns, and that every
# ambiguity guard exits 10 (= "fall through to a normal worker") instead of landing a wrong patch.
#
# Hermetic: a stub workspace, a real throwaway git repo for the sub-repo, a hand-seeded tickets.md
# (the patch itself comes straight from --patch, no cache read, no model call), and a `claude` on
# PATH that RECORDS any invocation — every case asserts that recorder file was never written.
#
# Covered:
#   - GOVERN_DETERMINISTIC=0 (emergency disable) → exit 10 immediately, no stdout; UNSET (the
#     default) is proven enabled by every other case below never setting it at all
#   - a clean applicable patch, supplied via --patch <file> → exit 0, report JSON with the
#     `zeroModel` marker, commit landed
#   - the extracted patch is BYTE-IDENTICAL to the supplied file (trailing newline survives)
#   - a patch supplied on stdin via `--patch -`, missing its own trailing newline → exit 0, and the
#     extracted patch gets exactly one newline appended
#   - a patch that fails `git apply --check` → exit 10
#   - a patch touching a path OUTSIDE the ticket's measured `**Files:**` paths → exit 10
#   - more files than GOVERN_DETERMINISTIC_MAX_FILES → exit 10
#   - a failing verify command → exit 10 AND the working tree is reverted
#   - no verify command configured → exit 10 (verification is required by default)
#   - a dirty sub-repo → exit 10
#   - a ticket carrying no `**Files:**` field → exit 10, nothing applied
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
APPLY="$DIR/../deterministic-apply.sh"

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed";  exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/wt" "$T/logs" "$T/bin" "$T/queue"
: > "$T/queue/tickets.md"

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

# Same edit, byte-identical except the LAST line carries no trailing newline — exercises the
# append-a-newline guard, which the heredoc-built GOOD_DIFF above never touches.
NONL_DIFF="$T/no-trailing-newline.diff"
printf -- '--- a/alpha/config.js\n+++ b/alpha/config.js\n@@ -1,4 +1,4 @@\n module.exports = {\n-  retries: 1,\n+  retries: 3,\n   timeout: 30,\n };' > "$NONL_DIFF"

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

OUTSIDE_DIFF="$T/outside.diff"   # a real, applicable edit — but to a path the ticket never measured
cat > "$OUTSIDE_DIFF" <<'EOF'
--- a/alpha/other.js
+++ b/alpha/other.js
@@ -1 +1 @@
-x
+y
EOF

TWOFILE_DIFF="$T/twofile.diff"
cat "$GOOD_DIFF" "$OUTSIDE_DIFF" > "$TWOFILE_DIFF"

# seed_ticket <N> <files-space-separated, "" for none> — hand-writes the ticket block deterministic-
# apply.sh reads its path allowlist from (govern::ticket_paths → the `**Files:**` field).
seed_ticket() { # <n> <files> [title]
  local n="$1" files="$2"
  local title="${3:-ticket $n}"
  {
    printf '## #%s — %s\n\n**Severity:** High\n\n' "$n" "$title"
    if [[ -n "$files" ]]; then printf '**Files:** %s\n\n' "$files"; fi
    printf -- '---\n\n'
  } >> "$T/queue/tickets.md"
}

# run_apply <ticket> <patch-file> [env assignments...] — supplies the patch via --patch <file>.
run_apply() {
  local n="$1" patchfile="$2"; shift 2
  set +e
  OUT="$(env GOVERN_WS_ROOT="$T" GOVERN_LOG_ROOT="$T/logs" \
      GOVERN_WORKTREE_CMD="$T/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$T/bin/claude" \
      "$@" "$APPLY" --dry-run --patch "$patchfile" "$n" 2>"$T/err-$n.txt")"
  RC=$?
  set -e
}

# run_apply_stdin <ticket> <patch-file-fed-on-stdin> [env assignments...] — supplies the patch via
# --patch - (stdin), the other half of the interface.
run_apply_stdin() {
  local n="$1" patchfile="$2"; shift 2
  set +e
  OUT="$(env GOVERN_WS_ROOT="$T" GOVERN_LOG_ROOT="$T/logs" \
      GOVERN_WORKTREE_CMD="$T/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$T/bin/claude" \
      "$@" "$APPLY" --dry-run --patch - "$n" < "$patchfile" 2>"$T/err-$n.txt")"
  RC=$?
  set -e
}

ONE="alpha/config.js"

# ── 1. kill switch: EMERGENCY DISABLE only — the default is ENABLED, proven by every other case
#    below never setting GOVERN_DETERMINISTIC at all. ────────────────────────────────────────────
seed_ticket 1 "$ONE"
run_apply 1 "$GOOD_DIFF" GOVERN_DETERMINISTIC=0
assert_eq "$RC" "10" "GOVERN_DETERMINISTIC=0 → exit 10"
assert_eq "$OUT" "" "GOVERN_DETERMINISTIC=0 → nothing on stdout"
assert_contains "$(cat "$T/err-1.txt")" "disabled (GOVERN_DETERMINISTIC=0)" "logs the disabled reason"

# ── 2. the happy path: GOVERN_DETERMINISTIC left UNSET (proves the default is enabled), a clean
#    applicable patch, zero model turns ─────────────────────────────────────────────────────────
seed_ticket 2 "$ONE" "happy path patch"
run_apply 2 "$GOOD_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true" \
            _GOVERN_DET_PATCH_COPY="$T/seen-patch.diff"
assert_eq "$RC" "0" "clean applicable patch → exit 0"
assert_eq "$(printf '%s' "$OUT" | jq -r '.status')"            "resolved" "report status=resolved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.zeroModel')"         "true"     "report carries the zeroModel marker"
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
assert_contains "$(git -C "$T/wt/ticket-2/alpha" log -1 --format=%B)" "happy path patch" "commit message describes the change, not a classification"

# ── 3. byte-exactness: the extracted patch == the supplied --patch file, trailing newline included
if cmp -s "$GOOD_DIFF" "$T/seen-patch.diff"; then
  assert_eq "ok" "ok" "extracted patch is BYTE-IDENTICAL to the supplied --patch file (trailing newline survives)"
else
  assert_eq "$(od -c "$T/seen-patch.diff" | tail -2)" "$(od -c "$GOOD_DIFF" | tail -2)" \
    "extracted patch is BYTE-IDENTICAL to the supplied --patch file (trailing newline survives)"
fi
assert_eq "$(tail -c 1 "$T/seen-patch.diff" | od -An -tx1 | tr -d ' \n')" "0a" \
  "extracted patch ends in exactly one newline"

# ── 4. --patch - (stdin), missing its own trailing newline → applies, and one newline is appended
seed_ticket 3 "$ONE" "stdin patch, no trailing newline"
run_apply_stdin 3 "$NONL_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true" \
            _GOVERN_DET_PATCH_COPY="$T/seen-patch-stdin.diff"
assert_eq "$RC" "0" "--patch - (stdin) applies the same edit → exit 0"
assert_eq "$(printf '%s' "$OUT" | jq -r '.zeroModel')" "true" "stdin-supplied patch also reports zeroModel"
assert_contains "$(cat "$T/err-3.txt")" "no trailing newline — appended one" "logs the newline-append"
assert_eq "$(tail -c 1 "$T/seen-patch-stdin.diff" | od -An -tx1 | tr -d ' \n')" "0a" \
  "the stdin-fed patch ends in exactly one newline after the append"

# ── 5. git apply --check fails → 10 ─────────────────────────────────────────────────────────────
seed_ticket 4 "$ONE"
run_apply 4 "$BAD_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "patch that fails git apply --check → exit 10"
assert_eq "$OUT" "" "failed --check → nothing on stdout"
assert_contains "$(cat "$T/err-4.txt")" "does not apply cleanly" "logs the apply-check reason"

# ── 6. a path outside the ticket's measured Files: → 10 ─────────────────────────────────────────
seed_ticket 5 "$ONE"
run_apply 5 "$OUTSIDE_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "patch touching a path outside the measured Files: → exit 10"
assert_contains "$(cat "$T/err-5.txt")" "outside the ticket's measured paths" "logs the out-of-scope path"

# ── 7. too many files → 10 ──────────────────────────────────────────────────────────────────────
seed_ticket 6 "alpha/config.js alpha/other.js"
run_apply 6 "$TWOFILE_DIFF" GOVERN_DETERMINISTIC_MAX_FILES=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "more files than GOVERN_DETERMINISTIC_MAX_FILES → exit 10"
assert_contains "$(cat "$T/err-6.txt")" "GOVERN_DETERMINISTIC_MAX_FILES=1" "logs the file-count ceiling"
# …and the same patch under a ceiling of 2 is accepted, so case 6 isolates the ceiling itself.
run_apply 6 "$TWOFILE_DIFF" GOVERN_DETERMINISTIC_MAX_FILES=2 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "0" "the SAME 2-file patch under a ceiling of 2 → exit 0 (the ceiling was the only blocker)"

# ── 8. verification failure → 10, and the tree is reverted ──────────────────────────────────────
seed_ticket 7 "$ONE"
run_apply 7 "$GOOD_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="exit 3"
assert_eq "$RC" "10" "failing verify command → exit 10"
assert_contains "$(cat "$T/err-7.txt")" "verification failed (rc=3)" "logs the verify failure"
if cmp -s "$PRISTINE_CONFIG" "$T/wt/ticket-7/alpha/config.js"; then
  assert_eq "ok" "ok" "a failed verification REVERTS the applied patch"
else
  assert_eq "$(cat "$T/wt/ticket-7/alpha/config.js")" "$(cat "$PRISTINE_CONFIG")" \
    "a failed verification REVERTS the applied patch"
fi
assert_eq "$(git -C "$T/wt/ticket-7/alpha" log --oneline | wc -l | tr -d ' ')" "1" "no commit after a failed verification"

# ── 9. no verify command configured → 10 (verification is required by default) ──────────────────
seed_ticket 8 "$ONE"
run_apply 8 "$GOOD_DIFF"
assert_eq "$RC" "10" "no GOVERN_DETERMINISTIC_VERIFY_CMD → exit 10 by default"
assert_contains "$(cat "$T/err-8.txt")" "verification is required" "logs the missing-verify reason"

# ── 10. a dirty sub-repo → 10 ───────────────────────────────────────────────────────────────────
seed_ticket 9 "$ONE"
printf 'dirt\n' >> "$T/alpha/other.js"
run_apply 9 "$GOOD_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "dirty sub-repo → exit 10"
assert_contains "$(cat "$T/err-9.txt")" "is dirty" "logs the dirty-repo reason"
git -C "$T/alpha" checkout -- other.js

# ── 11. a ticket with NO `**Files:**` field → 10, nothing applied ───────────────────────────────
seed_ticket 10 "" "no measured paths"
run_apply 10 "$GOOD_DIFF" GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$RC" "10" "ticket with no Files: field → exit 10"
assert_eq "$OUT" "" "no Files: field → nothing on stdout"
assert_contains "$(cat "$T/err-10.txt")" "no measured paths" "logs the missing-measured-paths reason"
assert_eq "$([[ -d "$T/wt/ticket-10" ]] && printf 'exists' || printf '')" "" \
  "no Files: field → the guard fires before a worktree is ever created"

# ── 12. THE constraint: not one model invocation on any path above ──────────────────────────────
assert_eq "$([[ -f "$CLAUDE_CALLS" ]] && cat "$CLAUDE_CALLS" || printf '')" "" \
  "ZERO claude invocations across every case"
# Static backstop: no line of the script may EXECUTE a claude binary. Every `claude` token in the
# file lives in a comment or a knob name, never in command position.
assert_eq "$(grep -nE '^[[:space:]]*[^#]*(\$\{?GOVERN_CLAUDE_BIN|claude)[[:space:]]+-p[[:space:]]' "$APPLY" | wc -l | tr -d ' ')" \
  "0" "no 'claude -p' invocation anywhere in the script"

assert_done
