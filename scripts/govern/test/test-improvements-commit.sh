#!/usr/bin/env bash
# Ported from the harness #111 regression (scripts/govern/test/test-improvements-commit.sh) via #112,
# adapted to the single-driver meta-repo template baseline.
#
# The fix: the self-improvement step (govern-improve.sh) APPENDS to the tracked
# governor/improvements.md but must not leave it UNCOMMITTED. Its WRITER commits it via
# govern::commit_meta_to_main — exactly as govern-bookkeep.sh commits tickets.md. Left dirty, a
# tracked artifact makes a later `git pull --rebase` on the main checkout (e.g. govern-bookkeep.sh's
# pre-edit origin sync, step 0) abort with "cannot pull with rebase: You have unstaged changes" — a
# failure easily misread as a merge conflict that wedges the next run.
#
# Template-baseline delta vs. the harness original: the single-driver template has no run-start
# preflight-main.sh (see test-no-force-push.sh's header) — there is no preflight reconcile of `main`
# to self-heal or diagnose — so #111's preflight self-heal / diagnostic sub-tests (the harness
# original's cases C & D) have no counterpart here and are intentionally absent. The writer-commits-
# its-own-runtime-artifact fix (govern::commit_meta_to_main + govern-improve.sh) is what applies, so
# this test covers exactly that:
#   A. govern::commit_meta_to_main — the writer commits + publishes its tracked artifact to main.
#   B. govern::commit_meta_to_main is a no-op (no empty commit) when nothing changed.
# Real bare-origin + local-clone pairs; no network, no real harness repo.
#
# Run against the SCAFFOLDED scripts (a workspace produced by /shiploop:setup), not from templates/:
# it sources lib/common.sh, which sources scripts/lib/workspace.sh — present only in a real workspace.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# common.sh sources $GOVERN_WS_ROOT/scripts/lib/workspace.sh — present only in a real workspace.
# Seed a hermetic stub + GOVERN_WS_ROOT so the source succeeds in the template layout too (#255).
mk_ws_stub "$ROOT"
# shellcheck source=/dev/null
source "$DIR/../lib/common.sh"

# Build a fresh bare-origin + local-clone pair under $1 with a TRACKED governor/improvements.md.
setup() {
  local base="$1" origin="$1/origin.git" lc="$1/local"
  git init -q --bare "$origin"
  git init -q "$lc"
  ( cd "$lc"
    git config user.email t@t; git config user.name t
    git checkout -q -b main
    printf '# tickets\n' > tickets.md
    mkdir -p governor; printf '# improvements\n' > governor/improvements.md
    git add tickets.md governor/improvements.md; git commit -q -m init
    git remote add origin "$origin"
    git push -q -u origin main ) >/dev/null 2>&1
  printf '%s' "$lc"
}
# "<behind>/<ahead>" of local HEAD vs origin/main after a fresh fetch.
converged() { ( cd "$1"; git fetch -q origin main 2>/dev/null; git rev-list --left-right --count origin/main...HEAD | awk '{print $1"/"$2}' ); }

# ── A. govern::commit_meta_to_main: writer commits + publishes its dirty artifact ──
LA="$(setup "$ROOT/a")"
printf '\n## run-x proposal\n- run-loop.sh: do thing — because.\n' >> "$LA/governor/improvements.md"
assert_contains "$(cd "$LA"; git status --porcelain)" "governor/improvements.md" "A precondition: improvements.md is dirty"
govern::commit_meta_to_main "$LA" "governor/improvements.md" "chore(govern): notes (#111)"
assert_eq "$(cd "$LA"; git status --porcelain governor/improvements.md)" "" "A: working tree clean after commit"
assert_eq "$(converged "$LA")" "0/0" "A: local main == origin/main (committed + pushed)"
assert_contains "$(cd "$LA"; git log --oneline -1 origin/main)" "notes (#111)" "A: the commit landed on origin/main"

# ── B. govern::commit_meta_to_main is a no-op when nothing changed (no empty commit) ──
before_b="$(cd "$LA"; git rev-list --count HEAD)"
govern::commit_meta_to_main "$LA" "governor/improvements.md" "chore(govern): notes again (#111)"
assert_eq "$(cd "$LA"; git rev-list --count HEAD)" "$before_b" "B: no commit created when the artifact is unchanged"

assert_done
