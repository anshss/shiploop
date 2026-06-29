#!/usr/bin/env bash
# Ported from the harness #105 regression (scripts/govern/test/test-no-force-push.sh), adapted to the
# single-driver meta-repo template baseline: the governor's meta-repo `main` bookkeeping must push
# FAST-FORWARD-ONLY and must NEVER rewrite already-pushed history (no force-push, no `+refspec`, no
# `--force-with-lease`, no history rewrite of a shared branch).
#
# Why this is load-bearing: `tickets.md` (and any lesson/newTicket appends) live on `origin/main`, and
# an interactive operator session can commit meta files to the SAME `main` alongside a running
# governor. If a govern script ever force-pushed `main`, it would drop an already-pushed commit from
# origin; a concurrent operator's routine `git pull --rebase origin main` then replays those superseded
# commits as fresh duplicate SHAs. The defense is structural: the governor's only `main` push
# (govern-bookkeep.sh) is a plain `git push` (ff-only by git's default — a non-ff push is REJECTED,
# never forced), and on rejection it rebases its OWN append-only commit and retries — it never
# rewrites origin.
#
# This test LOCKS that invariant so a future edit that introduces a force-push to a shared branch
# fails here. It proves: (1) no govern mechanism script force-pushes anything; (2) the bookkeep
# main-push path uses a plain `git push origin HEAD:main` (no `+`/`--force`); (3) the rejection path
# rebases the local commit + retries rather than forcing.
#
# Template-baseline deltas vs. the harness original: the single-driver template has only ONE
# main-push path (govern-bookkeep.sh) — there is no preflight-main.sh, and escalations-apply-answers.sh
# commits locally and leaves the push to the operator (never pushes main itself), so those assertions
# are intentionally absent here. The harness's #105 operator-doctrine CLAUDE.md guidance is likewise
# not part of the generic template baseline.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
GOVERN_DIR="$(cd "$DIR/.." && pwd)"
GOVERN_LIB_DIR="$GOVERN_DIR/lib"
LIB_DIR="$(cd "$DIR/../../lib" && pwd)"

# ── 1. No govern mechanism script force-pushes a shared branch ──────────────────────────────────
# Scan the real mechanism scripts (scripts/govern/*.sh + scripts/govern/lib/*.sh + scripts/lib/*.sh).
# Deliberately EXCLUDE the test/ dir — these test files legitimately carry the forbidden patterns as
# string literals (this very file does). Match a `git push` that forces:
#   git push --force / -f / --force-with-lease   |   git push ... +<ref>  (forced refspec)
shopt -s nullglob
SCRIPTS=( "$GOVERN_DIR"/*.sh "$GOVERN_LIB_DIR"/*.sh "$LIB_DIR"/*.sh )
violations=""
for f in "${SCRIPTS[@]}"; do
  # strip comments so a comment that merely MENTIONS force-push doesn't trip the guard, then look
  # for a real `git push` carrying a force flag or a `+`-prefixed refspec.
  hit="$(sed 's/#.*$//' "$f" \
    | grep -nE 'git[[:space:]].*push([[:space:]].*)?(--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)|[[:space:]]\+[A-Za-z])' \
    || true)"
  if [[ -n "$hit" ]]; then violations+="$(basename "$f"): $hit"$'\n'; fi
done
assert_eq "$violations" "" "no govern mechanism script force-pushes (no --force / -f / --force-with-lease / +refspec)"

# Also assert no script rewrites a SHARED branch via filter-repo / filter-branch.
filter="$(grep -rnE 'filter-repo|filter-branch' "$GOVERN_DIR"/*.sh "$GOVERN_LIB_DIR"/*.sh "$LIB_DIR"/*.sh 2>/dev/null || true)"
assert_eq "$filter" "" "no govern script rewrites history with filter-repo / filter-branch"

# ── 2. The single main-push path uses a plain ff-only `git push origin HEAD:main` ────────────────
BOOKKEEP="$(cat "$GOVERN_DIR/govern-bookkeep.sh")"

assert_contains "$BOOKKEEP" "git push origin HEAD:main" "bookkeep pushes main via plain ff-only 'git push origin HEAD:main'"

# It carries no force flag on that push (belt-and-suspenders over the scan above).
forced="$(printf '%s\n' "$BOOKKEEP" | sed 's/#.*$//' | grep -E 'push.*HEAD:main' | grep -E '\-\-force|\+main' || true)"
assert_eq "$forced" "" "bookkeep: the main push carries no --force / +main"

# ── 3. On a REJECTED push the script reconciles its OWN commit (rebase-retry), never forces ──────
# The bookkeep retry loop must rebase + retry, not force. Prove it pulls --rebase between push
# attempts (so a lost race replays the local append-only commit onto origin, then re-pushes ff).
assert_contains "$BOOKKEEP" "pull --rebase origin main" "bookkeep rejection path rebases the local commit (no force) and retries"

assert_done
