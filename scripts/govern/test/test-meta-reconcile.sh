#!/usr/bin/env bash
# Regression for ticket #71: the run-start preflight must reconcile the meta checkout's local main
# with origin/main BEFORE the harness lane cuts any PR — auto-reconciling a stale/ahead/diverged
# local main, or HALTING with one clear message when it genuinely can't. Exercises preflight-main.sh
# against a real bare-origin + local-clone pair across every branch. No network, no real harness repo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
mk_ws_stub "$(mktemp -d)"   # hermetic workspace stub so preflight's common.sh loads (independent of live)
PF="$DIR/../preflight-main.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build a fresh bare-origin + local-clone pair under $1; print the local checkout path.
setup() {
  local base="$1"
  local origin="$base/origin.git"
  local lc="$base/local"
  git init -q --bare "$origin"
  git init -q "$lc"
  ( cd "$lc"
    git config user.email t@t; git config user.name t
    git checkout -q -b main
    printf '# tickets\n' > tickets.md
    git add tickets.md; git commit -q -m init
    git remote add origin "$origin"
    git push -q -u origin main ) >/dev/null 2>&1
  printf '%s' "$lc"
}
# Add a LOCAL-only (unpushed) commit — like a pre-existing #69 filing / bookkeep commit.
local_commit() { ( cd "$1"; printf '%s\n' "$2" >> notes.md; git add notes.md; git commit -q -m "$2" ) >/dev/null 2>&1; }
# Advance ORIGIN via a throwaway clone — like a squash-merged harness PR landing on origin/main.
origin_commit() {
  local l="$1" msg="$2" origin tmp; origin="$(cd "$l"; git remote get-url origin)"
  tmp="$(mktemp -d)"; git clone -q "$origin" "$tmp/c" >/dev/null 2>&1
  ( cd "$tmp/c"; git config user.email o@o; git config user.name o
    printf '%s\n' "$msg" >> origin-side.md; git add origin-side.md; git commit -q -m "$msg"
    git push -q origin main ) >/dev/null 2>&1
  rm -rf "$tmp"
}
# "<behind>/<ahead>" of local HEAD vs origin/main after a fresh fetch.
converged() { ( cd "$1"; git fetch -q origin main 2>/dev/null; git rev-list --left-right --count origin/main...HEAD | awk '{print $1"/"$2}' ); }
run() { OUT="$(bash "$PF" "$1" 2>&1)" && RC=0 || RC=$?; }   # sets OUT, RC

# ── A. ahead-only — the exact #71 trigger: one pre-existing UNPUSHED commit ──
LA="$(setup "$ROOT/a")"; local_commit "$LA" "unpushed-69-filing"
run "$LA"
assert_eq "$RC" "0" "A ahead-only: preflight reconciles (exit 0)"
assert_contains "$OUT" "published 1 unpushed" "A: published the unpushed meta commit"
assert_eq "$(converged "$LA")" "0/0" "A: local main == origin/main afterwards"

# ── B. diverged — local 1 ahead AND origin 1 ahead (the cascade root cause) ──
LB="$(setup "$ROOT/b")"; local_commit "$LB" "local-bookkeep-delete"; origin_commit "$LB" "squash-merge-harness19"
run "$LB"
assert_eq "$RC" "0" "B diverged: preflight rebases + pushes (exit 0)"
assert_contains "$OUT" "DIVERGED" "B: detected divergence"
assert_eq "$(converged "$LB")" "0/0" "B: converged after rebase+push"
log_b="$(cd "$LB"; git log --oneline origin/main)"
assert_contains "$log_b" "local-bookkeep-delete"   "B: local commit replayed onto origin/main"
assert_contains "$log_b" "squash-merge-harness19"  "B: origin's squash-merge preserved"

# ── C. behind-only — origin advanced, local untouched ──
LC="$(setup "$ROOT/c")"; origin_commit "$LC" "merge-landed-on-origin"
run "$LC"
assert_eq "$RC" "0" "C behind-only: fast-forwards (exit 0)"
assert_contains "$OUT" "fast-forwarded" "C: fast-forwarded to origin/main"
assert_eq "$(converged "$LC")" "0/0" "C: converged after ff-pull"

# ── D. in sync — clean base, no-op ──
LD="$(setup "$ROOT/d")"
run "$LD"
assert_eq "$RC" "0" "D in-sync: no-op (exit 0)"
assert_contains "$OUT" "clean base" "D: reported a clean base"

# ── E. unreconcilable — local & origin edit the SAME line → rebase conflict → exit 2 + clean repo ──
LE="$(setup "$ROOT/e")"
( cd "$LE"; printf 'LOCAL CHANGE\n' > tickets.md; git add tickets.md; git commit -q -m local-edit ) >/dev/null 2>&1
ORIGIN_E="$(cd "$LE"; git remote get-url origin)"; TMPE="$(mktemp -d)"; git clone -q "$ORIGIN_E" "$TMPE/c" >/dev/null 2>&1
( cd "$TMPE/c"; git config user.email o@o; git config user.name o
  printf 'ORIGIN CHANGE\n' > tickets.md; git add tickets.md; git commit -q -m origin-edit; git push -q origin main ) >/dev/null 2>&1
rm -rf "$TMPE"
run "$LE"
assert_eq "$RC" "2" "E rebase conflict: preflight refuses with non-zero (exit 2)"
assert_contains "$OUT" "auto-reconcile FAILED" "E: one clear halt message"
assert_eq "$(cd "$LE"; git rev-parse --abbrev-ref HEAD)" "main" "E: rebase aborted — left on main, not mid-rebase"

# ── F. no origin remote (the test/local-only repo shape) — skip cleanly ──
LF="$ROOT/f"; git init -q "$LF"; ( cd "$LF"; git config user.email t@t; git config user.name t; printf x > a; git add a; git commit -q -m i ) >/dev/null 2>&1
run "$LF"
assert_eq "$RC" "0" "F no-origin: skips cleanly (exit 0)"
assert_contains "$OUT" "no origin remote" "F: logged the skip reason"

# ── G. GOVERN_NO_PUSH=1 — push disabled → skip even when ahead ──
LG="$(setup "$ROOT/g")"; local_commit "$LG" "would-be-pushed"
OUT="$(GOVERN_NO_PUSH=1 bash "$PF" "$LG" 2>&1)" && RC=0 || RC=$?
assert_eq "$RC" "0" "G GOVERN_NO_PUSH=1: skips reconcile (exit 0)"
assert_contains "$OUT" "GOVERN_NO_PUSH=1" "G: logged the no-push skip"
assert_eq "$(converged "$LG")" "0/1" "G: local stays 1 ahead (no push happened)"

assert_done
