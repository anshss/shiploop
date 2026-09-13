#!/usr/bin/env bash
# Hermetic tests for wrap.sh's --greenfield mode (templates/lib/wrap.sh) — the
# mirror-image case of wrap-in-place: fresh mode found ZERO sub-repos, so setup
# materializes the first one itself instead of stopping and telling the operator
# to hand-run mkdir/git init.
#
# Covers:
#   - empty folder -> <N>/ with exactly one commit, root scaffold verifies
#   - loose entries -> only --move entries land in <N>/, the rest stay at root
#   - <N> already exists -> exit 4, nothing touched
#   - run inside a git repo -> refusal (exit 3)
#   - failure injection mid-move -> rollback restores byte-identical, <N> gone
#   - retained undo after a COMPLETED scaffold -> original layout restored, no <N>
#
# wrap.sh lives only in the hub/template checkout (a setup-time transform, not
# an installed workspace mechanism), so this test SKIPs when run from a
# scaffolded workspace where wrap.sh is absent — same convention as
# test-wrap-in-place.sh.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Resolve wrap.sh (template layout: templates/govern/test/ -> templates/lib/wrap.sh).
WRAP="$(cd "$DIR/../../lib" 2>/dev/null && pwd)/wrap.sh"
[ -f "$WRAP" ] || { echo "SKIP: wrap.sh not found (installed workspace, not the hub) — $WRAP" >&2; exit 77; }
# scaffold.sh at the hub root (templates/govern/test/ -> ../../../scaffold.sh).
SCAFFOLD="$(cd "$DIR/../../.." 2>/dev/null && pwd)/scaffold.sh"
[ -f "$SCAFFOLD" ] || { echo "SKIP: scaffold.sh not found at hub root — $SCAFFOLD" >&2; exit 77; }

# ── Fixtures ────────────────────────────────────────────────────────────────
# layout() / layout_no_wrap() mirror test-wrap-in-place.sh's byte-compare helpers.
layout() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort ); }
layout_no_wrap() { layout "$1" | grep -v '/\.wrap-'; }

GF_COMMON=(--pm npm --org acme --scaffold "$SCAFFOLD" --confirm-live-writer)

run_greenfield() { # <workspace> <name> [--move "..."] [extra args...]
  local ws="$1" name="$2"; shift 2
  /bin/bash "$WRAP" --greenfield --workspace-dir "$ws" --name "$name" "${GF_COMMON[@]}" "$@" --yes
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Empty folder
# ══════════════════════════════════════════════════════════════════════════════
echo "── 1. empty folder ──" >&2
T="$(mktemp -d)"
out="$(run_greenfield "$T" myapp 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. greenfield exits 0"
[ -d "$T/myapp/.git" ] && printf 'ok   - 1. myapp/ is a git repo\n' || { printf 'FAIL - 1. myapp/.git missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
n_commits="$(git -C "$T/myapp" rev-list --count HEAD 2>/dev/null || echo 0)"
assert_eq "$n_commits" "1" "1. exactly one commit in myapp/"
assert_eq "$(git -C "$T/myapp" status --porcelain)" "" "1. myapp/ clean after init"
[ -f "$T/scripts/lib/workspace.sh" ] && printf 'ok   - 1. root scaffold verifies\n' || { printf 'FAIL - 1. root scaffold missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ ! -f "$T/.wrap-undo.sh" ] && printf 'ok   - 1. undo script removed post-verify\n' || { printf 'FAIL - 1. undo script left behind\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
git -C "$T" check-ignore -q myapp && printf 'ok   - 1. subfolder gitignored at root\n' || { printf 'FAIL - 1. subfolder not gitignored\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ══════════════════════════════════════════════════════════════════════════════
# 2. Folder with loose entries — only --move entries land in <N>/
# ══════════════════════════════════════════════════════════════════════════════
echo "── 2. loose entries, selective --move ──" >&2
T="$(mktemp -d)"
mkdir -p "$T/layers"; printf 'a\n' > "$T/layers/a.txt"
printf 'spec\n' > "$T/design.md"
mkdir -p "$T/.specs"; printf 'reserved\n' > "$T/.specs/plan.md"   # reserved — never movable
out="$(run_greenfield "$T" myapp --move "layers design.md" 2>&1)"; rc=$?
assert_eq "$rc" "0" "2. greenfield exits 0"
[ -d "$T/myapp/layers" ] && [ -f "$T/myapp/design.md" ] && printf 'ok   - 2. selected entries landed in myapp/\n' || { printf 'FAIL - 2. selected entries missing from myapp/\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -d "$T/.specs" ] && [ ! -e "$T/myapp/.specs" ] && printf 'ok   - 2. reserved entry stayed at root, byte-identical\n' || { printf 'FAIL - 2. reserved entry moved or lost\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(cat "$T/.specs/plan.md")" "reserved" "2. reserved entry content untouched"
assert_eq "$(cat "$T/myapp/layers/a.txt")" "a" "2. moved entry content intact"

# ══════════════════════════════════════════════════════════════════════════════
# 3. <N> already exists → exit 4, nothing touched
# ══════════════════════════════════════════════════════════════════════════════
echo "── 3. name collision ──" >&2
T="$(mktemp -d)"; mkdir "$T/myapp"; touch "$T/other.txt"
BEFORE="$(layout "$T")"
out="$(run_greenfield "$T" myapp 2>&1)"; rc=$?
assert_eq "$rc" "4" "3. name collision → exit 4"
assert_contains "$out" "COLLISION" "3. reports a collision"
assert_eq "$(layout "$T")" "$BEFORE" "3. nothing touched on collision"

# ══════════════════════════════════════════════════════════════════════════════
# 4. Run inside a git repo → refusal (exit 3)
# ══════════════════════════════════════════════════════════════════════════════
echo "── 4. inside a git repo → refuse ──" >&2
T="$(mktemp -d)"; git init -q "$T"; git -C "$T" config user.email t@t; git -C "$T" config user.name t
out="$(run_greenfield "$T" myapp 2>&1)"; rc=$?
assert_eq "$rc" "3" "4. inside a git repo → refuse (3)"
assert_contains "$out" "REFUSE" "4. prints a refusal"

# ══════════════════════════════════════════════════════════════════════════════
# 5. Failure injection mid-move → rollback restores byte-identical, <N> gone
# ══════════════════════════════════════════════════════════════════════════════
echo "── 5. failure injection / trap rollback ──" >&2
for stage in moving pre-rename renamed scaffolding; do
  T="$(mktemp -d)"; touch "$T/loose.txt"; BEFORE="$(layout "$T")"
  out="$(WRAP_TEST_FAIL_AT="$stage" run_greenfield "$T" myapp --move "loose.txt" 2>&1)"; rc=$?
  assert_eq "$rc" "1" "5.$stage: nonzero exit on injected failure"
  assert_eq "$(layout_no_wrap "$T")" "$BEFORE" "5.$stage: layout restored byte-identical"
  [ -f "$T/.wrap-undo.sh" ] && printf 'ok   - 5.%s: .wrap-undo.sh retained on failure\n' "$stage" || { printf 'FAIL - 5.%s: undo not retained\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  [ ! -d "$T/myapp" ] && printf 'ok   - 5.%s: myapp/ gone after rollback\n' "$stage" || { printf 'FAIL - 5.%s: myapp/ left behind\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  [ ! -f "$T/.wrap-manifest" ] && printf 'ok   - 5.%s: stale manifest dropped (retained undo is a safe no-op)\n' "$stage" || { printf 'FAIL - 5.%s: stale manifest kept\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
  # The retained undo must be a safe no-op against the already-restored layout.
  ( cd "$T" && /bin/bash .wrap-undo.sh >/dev/null 2>&1 )
  [ -f "$T/loose.txt" ] && [ ! -d "$T/myapp" ] \
    && printf 'ok   - 5.%s: retained undo did not harm the restored layout\n' "$stage" \
    || { printf 'FAIL - 5.%s: retained undo damaged the restored layout\n' "$stage"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done

# ══════════════════════════════════════════════════════════════════════════════
# 6. Retained undo after a COMPLETED scaffold
# ══════════════════════════════════════════════════════════════════════════════
echo "── 6. undo after completed scaffold ──" >&2
T="$(mktemp -d)"; touch "$T/loose.txt"; BEFORE="$(layout "$T")"
out="$(run_greenfield "$T" myapp --move "loose.txt" --keep-undo 2>&1)"; rc=$?
assert_eq "$rc" "0" "6. greenfield scaffold ok (--keep-undo)"
[ -f "$T/.wrap-undo.sh" ] && printf 'ok   - 6. undo retained under --keep-undo\n' || { printf 'FAIL - 6. undo missing under --keep-undo\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
( cd "$T" && /bin/bash .wrap-undo.sh >/dev/null 2>&1 ); urc=$?
assert_eq "$urc" "0" "6. undo runs cleanly"
assert_eq "$(layout "$T")" "$BEFORE" "6. original layout fully restored"
[ ! -d "$T/scripts" ] && [ ! -f "$T/learnings.md" ] && printf 'ok   - 6. no scaffold residue\n' || { printf 'FAIL - 6. scaffold residue left\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ ! -d "$T/myapp" ] && printf 'ok   - 6. myapp/ gone after undo\n' || { printf 'FAIL - 6. myapp/ still present after undo\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ══════════════════════════════════════════════════════════════════════════════
# 7. --preflight (read-only) surfaces the loose-entries classification
# ══════════════════════════════════════════════════════════════════════════════
echo "── 7. --preflight (read-only) ──" >&2
T="$(mktemp -d)"; touch "$T/loose.txt"; mkdir -p "$T/.git-lookalike"
BEFORE="$(layout "$T")"
out="$(/bin/bash "$WRAP" --greenfield --preflight --workspace-dir "$T" --name myapp 2>&1)"; rc=$?
assert_eq "$rc" "0" "7a. preflight exits 0"
assert_contains "$out" "loose=loose.txt|movable" "7a. classifies a loose entry as movable"
assert_eq "$(layout "$T")" "$BEFORE" "7a. preflight moved nothing"
[ ! -f "$T/.wrap-undo.sh" ] && printf 'ok   - 7a. no undo script written by preflight\n' || { printf 'FAIL - 7a. undo script written by preflight\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# 7b. reserved name refused as <N>
out="$(/bin/bash "$WRAP" --greenfield --preflight --workspace-dir "$T" --name scripts 2>&1)"; rc=$?
assert_eq "$rc" "4" "7b. reserved name as <N> → exit 4"
assert_contains "$out" "workspace-owned path" "7b. names the collision reason"

assert_done
