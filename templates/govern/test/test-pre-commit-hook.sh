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
#   E. Local seam: no .githooks/pre-commit.d directory (and an empty one) → commit passes unchanged.
#   F. Local seam: a passing script runs (and runs in name order), even with no lint-fix command.
#   G. Local seam: a failing script blocks the commit (non-zero) and is named; a non-executable
#      file in the directory is ignored.
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

# ── Seam scenarios: .githooks/pre-commit.d/ ──────────────────────────────────
write_workspace_sh ""
cp "$T/.githooks/pre-commit" "$SUB/.git/hooks/pre-commit"
SEAM="$T/.githooks/pre-commit.d"

# E. No directory, then an empty one: nothing changes, exit 0.
rm -rf "$SEAM"
rc=0; outE="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 )" || rc=$?
assert_eq "$rc" "0" "seam E: no pre-commit.d directory leaves the commit passing"
mkdir -p "$SEAM"
rc=0; outE="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 )" || rc=$?
assert_eq "$rc" "0" "seam E: an empty pre-commit.d directory leaves the commit passing"

# F. Passing scripts run, in name order, with no lint-fix command configured.
cat > "$SEAM/20-second" <<EOF
#!/usr/bin/env bash
echo second >> "$T/seam-order"
EOF
cat > "$SEAM/10-first" <<EOF
#!/usr/bin/env bash
echo first >> "$T/seam-order"
EOF
chmod +x "$SEAM/20-second" "$SEAM/10-first"
rm -f "$T/seam-order"
rc=0; outF="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 )" || rc=$?
assert_eq "$rc" "0" "seam F: passing seam scripts leave the commit passing"
assert_eq "$(tr '\n' ' ' < "$T/seam-order")" "first second " "seam F: scripts ran in name order"

# G. A failing script blocks and is named; a non-executable file is ignored (its sentinel never appears).
cat > "$SEAM/15-bad" <<'EOF'
#!/usr/bin/env bash
echo "product check says no"
exit 3
EOF
chmod +x "$SEAM/15-bad"
printf '#!/usr/bin/env bash\ntouch "%s/SENTINEL-NOEXEC"\n' "$T" > "$SEAM/05-noexec"
rm -f "$T/seam-order"
rc=0; outG="$( cd "$SUB" && bash .git/hooks/pre-commit 2>&1 )" || rc=$?
assert_eq "$rc" "1" "seam G: a failing seam script fails the commit"
assert_contains "$outG" "15-bad" "seam G: the failing file is named"
assert_eq "$(test -e "$T/SENTINEL-NOEXEC" && echo ran || echo skipped)" "skipped" "seam G: a non-executable file is ignored"
assert_eq "$(tr '\n' ' ' < "$T/seam-order")" "first " "seam G: scripts after the failure did not run"

assert_done
