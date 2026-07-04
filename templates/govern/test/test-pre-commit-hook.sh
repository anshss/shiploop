#!/usr/bin/env bash
# Regression for the workspace pre-commit lint-fix hook (templates/githooks/pre-commit) and its
# installer (templates/lib/githooks.sh:install_subrepo_pre_commit_hook).
#
# Scenarios:
#   A. WSP_LINT_FIX_CMD unset in workspace.sh → hook runs but is a no-op (exit 0, no CMD sentinel).
#   B. WSP_LINT_FIX_CMD set to a sentinel-touching command → hook runs the command; sentinel appears
#      and modifications to a tracked file are `git add -u`'d into the commit index.
#   C. A pre-existing NON-ours pre-commit (e.g. husky, lefthook, hand-rolled) → installer refuses to
#      clobber it and returns 0 with a "leaving in place" note; the operator's hook survives.
#   D. A pre-existing pre-commit that carries OUR marker → installer refreshes it (idempotent).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Locate the two files under test in whichever layout we're in (template vs scaffolded workspace).
# assert.sh sits in <…>/govern/test/, so the pre-commit source is <…>/../../githooks/pre-commit
# (templates layout) or <…>/../../.githooks/pre-commit (workspace layout).
for _cand in "$DIR/../../githooks/pre-commit" "$DIR/../../../.githooks/pre-commit"; do
  [ -f "$_cand" ] && { HOOK_SRC="$(cd "$(dirname "$_cand")" && pwd)/$(basename "$_cand")"; break; }
done
for _cand in "$DIR/../../lib/githooks.sh" "$DIR/../../../scripts/lib/githooks.sh"; do
  [ -f "$_cand" ] && { LIB_GITHOOKS="$(cd "$(dirname "$_cand")" && pwd)/$(basename "$_cand")"; break; }
done
[ -n "${HOOK_SRC:-}" ]     || { echo "FATAL: cannot locate githooks/pre-commit"     >&2; exit 1; }
[ -n "${LIB_GITHOOKS:-}" ] || { echo "FATAL: cannot locate lib/githooks.sh"          >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Fake harness root: only needs .githooks/pre-commit + scripts/lib/workspace.sh at the expected paths.
mkdir -p "$T/.githooks" "$T/scripts/lib"
cp "$HOOK_SRC" "$T/.githooks/pre-commit"
chmod +x "$T/.githooks/pre-commit"

# Fake sub-repo: a git repo one level under the harness root, with one tracked file.
SUB="$T/alpha"
mkdir -p "$SUB"
( cd "$SUB" \
    && git init -q -b main \
    && git config user.email t@t \
    && git config user.name t \
    && printf 'orig\n' > tracked.txt \
    && git add tracked.txt \
    && git commit -q -m init )

write_workspace_sh() { # <cmd-string>
  cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export WSP_LINT_FIX_CMD="$1"
EOF
}

# ── Scenario A: no CMD → hook is a no-op ─────────────────────────────────────
write_workspace_sh ""
( cd "$SUB" && source "$LIB_GITHOOKS" && install_subrepo_pre_commit_hook "$T" "$SUB" >/dev/null )
assert_eq "$(test -x "$SUB/.git/hooks/pre-commit" && echo yes)" "yes" "installer wrote pre-commit into .git/hooks (fresh slot)"
# Actually run the hook: exit 0, no CMD invoked (no side effect).
outA="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 || echo "EXIT=$?" )"
if printf '%s' "$outA" | grep -qF "EXIT="; then
  assert_eq "exit-nonzero" "exit-0" "no-CMD hook exits 0"
else
  assert_eq "exit-0" "exit-0" "no-CMD hook exits 0"
fi
if printf '%s' "$outA" | grep -qF "running \$WSP_LINT_FIX_CMD"; then
  assert_eq "ran" "silent" "no-CMD hook does NOT try to run a command"
else
  assert_eq "silent" "silent" "no-CMD hook does NOT try to run a command"
fi

# ── Scenario B: CMD set → invoked; modified tracked file is re-staged ────────
# Sentinel: the fix command replaces tracked.txt with a known token and touches SENTINEL.
# Use a fixer script on disk to sidestep quoting hell in the here-doc.
FIXER="$T/fixer.sh"
cat > "$FIXER" <<EOF
#!/usr/bin/env bash
echo fixed > tracked.txt
touch "$T/SENTINEL-B"
EOF
chmod +x "$FIXER"
write_workspace_sh "bash '$FIXER'"
rm -f "$SUB/.git/hooks/pre-commit"
( cd "$SUB" && source "$LIB_GITHOOKS" && install_subrepo_pre_commit_hook "$T" "$SUB" >/dev/null )
# Simulate an in-progress commit that has staged the ORIGINAL content of tracked.txt.
( cd "$SUB" && printf 'orig\n' > tracked.txt && git add tracked.txt )
staged_before="$( cd "$SUB" && git diff --cached tracked.txt | grep -c '^+fixed$' || true )"
assert_eq "$staged_before" "0" "before-hook: staged content is the ORIGINAL, not 'fixed'"
outB="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 )"
assert_eq "$(test -f "$T/SENTINEL-B" && echo yes)" "yes" "hook actually invoked WSP_LINT_FIX_CMD"
assert_contains "$outB" "lint-fix ok — modified files re-staged." "hook logs success + re-stage line"
staged_after="$( cd "$SUB" && git diff --cached tracked.txt | grep -c '^+fixed$' || true )"
assert_eq "$staged_after" "1" "after-hook: 'fixed' content is re-staged (git add -u ran)"

# ── Scenario C: existing NON-ours pre-commit → installer refuses to clobber ──
rm -f "$SUB/.git/hooks/pre-commit"
cat > "$SUB/.git/hooks/pre-commit" <<'FOREIGN'
#!/usr/bin/env bash
# husky-style user hook — no wsp marker
exit 0
FOREIGN
chmod +x "$SUB/.git/hooks/pre-commit"
foreign_sha="$(shasum "$SUB/.git/hooks/pre-commit" | awk '{print $1}')"
outC="$( source "$LIB_GITHOOKS" && install_subrepo_pre_commit_hook "$T" "$SUB" 2>&1 )"
assert_contains "$outC" "existing pre-commit hook — leaving in place" "installer notes it's skipping an existing hook"
after_sha="$(shasum "$SUB/.git/hooks/pre-commit" | awk '{print $1}')"
assert_eq "$after_sha" "$foreign_sha" "operator/framework pre-commit hook is byte-preserved"

# ── Scenario D: existing OURS pre-commit → installer refreshes idempotently ──
# Overwrite the foreign one with our template, then flip one byte to simulate a stale copy.
cp "$T/.githooks/pre-commit" "$SUB/.git/hooks/pre-commit"
printf '\n# stale local edit\n' >> "$SUB/.git/hooks/pre-commit"
stale_sha="$(shasum "$SUB/.git/hooks/pre-commit" | awk '{print $1}')"
outD="$( source "$LIB_GITHOOKS" && install_subrepo_pre_commit_hook "$T" "$SUB" 2>&1 )"
assert_contains "$outD" "pre-commit hook →" "installer refreshes our own hook (idempotent)"
refresh_sha="$(shasum "$SUB/.git/hooks/pre-commit" | awk '{print $1}')"
canon_sha="$(shasum "$T/.githooks/pre-commit" | awk '{print $1}')"
if [ "$refresh_sha" = "$stale_sha" ]; then
  assert_eq "unchanged" "refreshed" "installer replaced a stale prior-installed hook"
else
  assert_eq "refreshed" "refreshed" "installer replaced a stale prior-installed hook"
fi
assert_eq "$refresh_sha" "$canon_sha" "refreshed hook matches the canonical source byte-for-byte"

assert_done
