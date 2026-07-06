#!/usr/bin/env bash
# Regression for N6 — husky (and any framework that regenerates its hooks dir on install) silently
# wipes the attribution/pre-commit hooks the harness installs into a sub-repo, and nothing re-asserts
# or audits. Covers the two seams that fix ships:
#
#   1. templates/lib/githooks.sh:audit_subrepo_hooks  — the read-only doctor check that flags a
#      sub-repo whose resolved hook was stubbed/wiped (mismatch), missing (absent), or drifted
#      (pre-commit stale-ours), and reports `match` when intact.
#   2. install_subrepo_attribution_hook / install_subrepo_pre_commit_hook re-run — proves hook
#      SURVIVAL: after a husky regeneration WIPES our hook, re-running the installer restores it
#      byte-identical to .githooks/.
#
# HERMETIC by design (runs in CI with no network): husky's `prepare` on `npm install` just writes
# stub files into `.husky/_/`, so we simulate that regeneration deterministically (overwrite the
# resolved hook with a husky-style stub) and prove the re-assert wins. A companion REAL `npm install`
# husky cycle was run out-of-band during development for empirical confirmation (see the PR body).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Locate the lib + the two canonical hook sources in whichever layout we're in (template vs workspace).
for _cand in "$DIR/../../lib/githooks.sh" "$DIR/../../../scripts/lib/githooks.sh"; do
  [ -f "$_cand" ] && { LIB_GITHOOKS="$(cd "$(dirname "$_cand")" && pwd)/$(basename "$_cand")"; break; }
done
for _cand in "$DIR/../../githooks/prepare-commit-msg" "$DIR/../../../.githooks/prepare-commit-msg"; do
  [ -f "$_cand" ] && { ATTR_SRC="$(cd "$(dirname "$_cand")" && pwd)/$(basename "$_cand")"; break; }
done
for _cand in "$DIR/../../githooks/pre-commit" "$DIR/../../../.githooks/pre-commit"; do
  [ -f "$_cand" ] && { PC_SRC="$(cd "$(dirname "$_cand")" && pwd)/$(basename "$_cand")"; break; }
done
[ -n "${LIB_GITHOOKS:-}" ] || { echo "FATAL: cannot locate lib/githooks.sh" >&2; exit 1; }
[ -n "${ATTR_SRC:-}" ]     || { echo "FATAL: cannot locate githooks/prepare-commit-msg" >&2; exit 1; }
[ -n "${PC_SRC:-}" ]       || { echo "FATAL: cannot locate githooks/pre-commit" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Fake harness root: .githooks/{prepare-commit-msg,pre-commit} + a no-op workspace.sh (pre-commit
# installer is a no-op unless WSP_LINT_FIX_CMD is set; that's fine here — we only diff bytes).
mkdir -p "$T/.githooks" "$T/scripts/lib"
cp "$ATTR_SRC" "$T/.githooks/prepare-commit-msg"; chmod +x "$T/.githooks/prepare-commit-msg"
cp "$PC_SRC"   "$T/.githooks/pre-commit";        chmod +x "$T/.githooks/pre-commit"
cat > "$T/scripts/lib/workspace.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
export WSP_LINT_FIX_CMD=""
EOF

source "$LIB_GITHOOKS"

# Build a husky-style sub-repo: git repo with core.hooksPath = .husky/_ and a stub prepare-commit-msg
# there (what `husky` writes on `npm install`). Returns the repo path in $1.
mk_husky_subrepo() { # <path>
  local sub="$1"
  mkdir -p "$sub/.husky/_"
  ( cd "$sub" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name t \
      && git config core.hooksPath .husky/_ \
      && printf 'seed\n' > f.txt \
      && git add f.txt \
      && git commit -q -m init )
  # husky's regenerated stub — deliberately NOT our attribution hook.
  write_husky_stub "$sub"
}
write_husky_stub() { # <path> — (re)write the husky stub that a fresh `npm install`/husky prepare emits
  cat > "$1/.husky/_/prepare-commit-msg" <<'STUB'
#!/usr/bin/env sh
. "${0%/_/*}/h"
STUB
  chmod +x "$1/.husky/_/prepare-commit-msg"
}

# Read one field from audit_subrepo_hooks output.
audit_state() { # <root> <sub> <hookname>
  audit_subrepo_hooks "$1" "$2" | awk -v h="$3" '$1==h {print $2}'
}

# ── Scenario A: audit flags a STUBBED husky sub-repo (attribution hook wiped) ──
SUB="$T/console"; mk_husky_subrepo "$SUB"
assert_eq "$(audit_state "$T" "$SUB" prepare-commit-msg)" "mismatch" \
  "audit: husky-stubbed sub-repo → attribution hook 'mismatch' (the doctor flag)"

# ── Scenario B: installer targets the husky hooks dir, byte-identical to .githooks/ ──
install_subrepo_attribution_hook "$T" "$SUB" >/dev/null
assert_eq "$(test -f "$SUB/.husky/_/prepare-commit-msg" && echo yes)" "yes" \
  "installer wrote into the RESOLVED husky hooks dir (.husky/_), not .git/hooks"
if cmp -s "$T/.githooks/prepare-commit-msg" "$SUB/.husky/_/prepare-commit-msg"; then
  assert_eq "match" "match" "installed attribution hook is byte-identical to .githooks/prepare-commit-msg"
else
  assert_eq "differs" "match" "installed attribution hook is byte-identical to .githooks/prepare-commit-msg"
fi
assert_eq "$(audit_state "$T" "$SUB" prepare-commit-msg)" "match" \
  "audit: after install → attribution hook 'match'"

# ── Scenario C: SURVIVAL across a (simulated) husky regeneration ──
# Simulate `npm install` → husky `prepare` regenerating .husky/_/* (wipes our hook with its stub).
write_husky_stub "$SUB"
assert_eq "$(audit_state "$T" "$SUB" prepare-commit-msg)" "mismatch" \
  "post-regen: husky stub wiped our hook → audit 'mismatch' (the bug N6 fixes)"
# Re-assert (the fix: worktree/new.sh post-bootstrap + /update Phase 3b re-run the installer).
install_subrepo_attribution_hook "$T" "$SUB" >/dev/null
if cmp -s "$T/.githooks/prepare-commit-msg" "$SUB/.husky/_/prepare-commit-msg"; then
  assert_eq "restored" "restored" "re-assert after regen restores the attribution hook byte-identical"
else
  assert_eq "still-stubbed" "restored" "re-assert after regen restores the attribution hook byte-identical"
fi
assert_eq "$(audit_state "$T" "$SUB" prepare-commit-msg)" "match" \
  "post-re-assert: attribution hook survives → audit 'match'"

# ── Scenario D: audit distinguishes 'absent' from 'match' on a plain (non-husky) sub-repo ──
PLAIN="$T/backend"
mkdir -p "$PLAIN"
( cd "$PLAIN" && git init -q -b main && git config user.email t@t && git config user.name t \
    && printf 'x\n' > f.txt && git add f.txt && git commit -q -m init )
assert_eq "$(audit_state "$T" "$PLAIN" prepare-commit-msg)" "absent" \
  "audit: plain sub-repo with no hook → attribution 'absent'"
install_subrepo_attribution_hook "$T" "$PLAIN" >/dev/null
assert_eq "$(audit_state "$T" "$PLAIN" prepare-commit-msg)" "match" \
  "audit: plain sub-repo after install → 'match' (resolves .git/hooks correctly)"

# ── Scenario E: pre-commit — 'stale-ours' vs 'foreign' vs 'match' ──
install_subrepo_pre_commit_hook "$T" "$PLAIN" >/dev/null
assert_eq "$(audit_state "$T" "$PLAIN" pre-commit)" "match" \
  "audit: freshly installed pre-commit → 'match'"
# Drift OUR hook (keeps the marker line): audit → stale-ours (a re-install would refresh it).
printf '\n# stale local edit\n' >> "$PLAIN/.git/hooks/pre-commit"
assert_eq "$(audit_state "$T" "$PLAIN" pre-commit)" "stale-ours" \
  "audit: drifted OURS pre-commit (marker present) → 'stale-ours'"
# A FOREIGN pre-commit (no marker) is legitimately left alone → audit 'foreign', never a fault.
cat > "$PLAIN/.git/hooks/pre-commit" <<'FOREIGN'
#!/usr/bin/env bash
# operator/husky hook — no wsp marker
exit 0
FOREIGN
assert_eq "$(audit_state "$T" "$PLAIN" pre-commit)" "foreign" \
  "audit: foreign pre-commit (no marker) → 'foreign' (not a fault)"

assert_done
