#!/usr/bin/env bash
# Regression for #377: the OVERLAPPING-same-file half of the co-tenant-coexistence problem that #370's
# autostash could NOT auto-merge. When origin/main advances a govern SCRIPT that a co-tenant session is
# CONCURRENTLY editing (uncommitted WIP in the shared checkout — e.g. the flows feature's edits to
# spawn-worker.sh), bookkeep's `-c rebase.autoStash=true pull --rebase` rebases cleanly (it only replays
# OUR append-only meta diffs) but the autostash POP hits a real content conflict on that same file+region.
# git reports the pop conflict as a mere WARNING and STILL EXITS 0 ("Successfully rebased and updated"),
# leaving the SHARED index with UNMERGED entries and the autostash preserved. Before #377 the old
# `pull --rebase … || { rebase --abort; }` fallback never fired (rc 0) and `rebase --abort` was a no-op
# anyway, so the shared checkout was WEDGED: every later `git add`/`git commit` failed "you have unmerged
# files"; the resolved ticket's block-delete never committed and healthy tickets false-FAILED
# (incident 2026-07-17: a merged spawn-worker.sh change collided with co-tenant WIP → several tickets false-FAILED and got parked).
#
# The fix routes all three shared-checkout `pull --rebase` call sites through
# govern::pull_rebase_autostash, which detects the rc-0-but-unmerged wedge and recovers cleanly: local
# main IS already rebased onto origin/main, so it just resets the tracked tree back to the post-rebase
# HEAD and leaves the co-tenant WIP UNTOUCHED in the preserved stash for the co-tenant to reconcile
# (never hand-merging someone else's code). A GENUINE content conflict on a meta file (rebase itself
# fails, rc ≠ 0) still aborts + fails closed, unchanged.
#
# Part A — end-to-end through the REAL govern-bookkeep.sh: origin advances script.sh's line2 while a
# co-tenant holds conflicting uncommitted WIP on that SAME line2; local main is also diverged (one
# unpushed commit) to force the pre-edit sync (step 0) down the autostash rebase branch. Asserts the
# ticket-block push STILL lands on origin/main, the shared index is NOT wedged (a follow-up commit
# succeeds), and the co-tenant WIP is preserved (recoverable from the stash) — never lost or merged.
#
# Part B — direct unit proof of govern::pull_rebase_autostash at both decision points: (B1) an
# overlapping autostash-pop conflict returns 0 with a CLEAN index, local main synced to origin/main, and
# the co-tenant WIP safe in the stash; (B2) a genuine meta-file content conflict returns 1, aborts the
# rebase (leaves the checkout cleanly on main, not mid-rebase), and preserves the dirty co-tenant file.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
gitcfg() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; }
# Part B calls govern::pull_rebase_autostash DIRECTLY (in-process), so source common.sh once here.
# common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh" on load, so seed a stub first (#255);
# later per-part mk_ws_stub calls just re-point GOVERN_WS_ROOT — the function stays defined. Part A
# runs the REAL govern-bookkeep.sh as a subprocess (it sources common.sh itself), so this is inert
# for Part A. (Part A passes GOVERN_WS_ROOT explicitly to that subprocess.)
mk_ws_stub "$ROOT"
source "$DIR/../lib/common.sh"

# ═════════════════════════════════════════════════════════════════════════
# Part A — real govern-bookkeep.sh run: origin advances the SAME script line a co-tenant is editing
# ═════════════════════════════════════════════════════════════════════════
A="$ROOT/a"; mkdir -p "$A"
ORIGIN="$A/origin.git"; LC="$A/local"
git init -q --bare "$ORIGIN"
git init -q "$LC"; gitcfg "$LC"
mk_ws_stub "$LC"   # hermetic scripts/lib/workspace.sh stub (#255)
( cd "$LC"
  git checkout -q -b main
  printf '# Tickets\n\n## Open\n\n## #50 — overlap autostash-pop regression\n\n**Severity:** High\n\nbody\n\n---\n' > tickets.md
  # A tracked govern SCRIPT standing in for spawn-worker.sh — committed once so a LATER edit to its
  # line2 is a dirty-but-tracked modification that OVERLAPS an origin-side advance of the same line.
  printf 'script line1\nSHARED-BASE-LINE2\nscript line3\n' > spawn-worker.sh
  git add tickets.md spawn-worker.sh; git commit -q -m init
  git remote add origin "$ORIGIN"; git push -q -u origin main
) >/dev/null 2>&1

# origin-side advance of spawn-worker.sh's line2, from a second clone (e.g. #371 merging a change).
TMPA="$(mktemp -d)"; git clone -q "$ORIGIN" "$TMPA/c" >/dev/null 2>&1
( cd "$TMPA/c"; gitcfg .
  printf 'script line1\nORIGIN-ADVANCED-LINE2\nscript line3\n' > spawn-worker.sh
  git add spawn-worker.sh; git commit -q -m "origin advances spawn-worker.sh line2"; git push -q origin main ) >/dev/null 2>&1
rm -rf "$TMPA"

# One local-only unpushed commit so ff-only fails and step 0 takes the autostash rebase branch.
( cd "$LC"; printf 'earlier unpushed artifact\n' > local-artifact.md
  git add local-artifact.md; git commit -q -m "unpushed local commit (pre-existing divergence)" ) >/dev/null 2>&1

# Co-tenant dirties the SAME line2 of spawn-worker.sh — uncommitted, unstaged, conflicting with origin.
printf 'script line1\nCO-TENANT-WIP-LINE2\nscript line3\n' > "$LC/spawn-worker.sh"
WIP_CONTENT_BEFORE="$(cat "$LC/spawn-worker.sh")"
assert_contains "$(cd "$LC" && git status --porcelain)" " M spawn-worker.sh" "A precondition: spawn-worker.sh dirty (overlaps the origin advance) going into bookkeep"

report='{"status":"resolved","pr":{"repo":"alpha","number":50,"url":"u"},"newTickets":[]}'
set +e
out="$( cd "$LC" && printf '%s' "$report" \
  | GOVERN_WS_ROOT="$LC" GOVERN_TICKETS_FILE="$LC/tickets.md" bash "$BK" 50 2>&1 )"
rc=$?
set -e
assert_eq "$rc" "0" "A: bookkeep exits 0 despite the overlapping-same-file autostash-pop conflict"

# The shared index must NOT be wedged: no unmerged entries, and a follow-up commit must succeed.
unmerged="$(cd "$LC" && git ls-files --unmerged | wc -l | tr -d ' ')"
assert_eq "$unmerged" "0" "A: shared index has NO unmerged entries after bookkeep (not wedged)"
set +e
( cd "$LC" && printf 'probe\n' > probe.md && git add probe.md && git commit -q -m "post-bookkeep probe commit" ) >/dev/null 2>&1
probe_rc=$?
set -e
assert_eq "$probe_rc" "0" "A: a follow-up git add+commit succeeds (shared checkout is usable, not wedged)"

# The ticket-block delete must have actually LANDED on origin/main.
V="$A/verify"; git clone -q "$ORIGIN" "$V" >/dev/null 2>&1
printf '%s' "$(cat "$V/tickets.md")" | grep -q '## #50 ' && f=1 || f=0
assert_eq "$f" "0" "A: ticket #50 block deleted on origin/main (push succeeded despite the wedge scenario)"
assert_eq "$([[ -f "$V/local-artifact.md" ]] && echo yes || echo no)" "yes" "A: earlier unpushed commit reached origin (not lost)"

# The co-tenant WIP must be PRESERVED (MVP path: parked in the stash) — never lost or hand-merged.
assert_contains "$(cd "$LC" && git stash list)" "stash@{0}" "A: co-tenant WIP preserved in the stash (not discarded)"
assert_contains "$(cd "$LC" && git stash show -p stash@{0} 2>/dev/null)" "CO-TENANT-WIP-LINE2" "A: the stashed diff still holds the co-tenant's exact WIP line (recoverable byte-for-byte)"
# The governor must NOT have committed the co-tenant's version onto origin/main (never hand-merged it).
assert_contains "$(cat "$V/spawn-worker.sh")" "ORIGIN-ADVANCED-LINE2" "A: origin/main keeps its OWN spawn-worker.sh advance (co-tenant WIP was not merged/pushed)"
assert_not_contains() { grep -qF "$2" <<<"$1" && { printf 'FAIL - %s\n       [%s] unexpectedly found\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); } || printf 'ok   - %s\n' "$3"; }
assert_not_contains "$(cat "$V/spawn-worker.sh")" "CO-TENANT-WIP-LINE2" "A: co-tenant WIP never reached origin/main (governor did not commit someone else's code)"

# ═════════════════════════════════════════════════════════════════════════
# Part B — direct unit proof of govern::pull_rebase_autostash
# ═════════════════════════════════════════════════════════════════════════
# B1: overlapping autostash-pop conflict → returns 0, index CLEAN, local main == origin/main, WIP stashed.
B="$ROOT/b"; mkdir -p "$B"
BORIGIN="$B/origin.git"; BLC="$B/local"
git init -q --bare "$BORIGIN"; git init -q "$BLC"; gitcfg "$BLC"
mk_ws_stub "$BLC"
( cd "$BLC"; git checkout -q -b main
  printf 'l1\nBASE\nl3\n' > script.sh; printf 'tickets\n' > tickets.md
  git add -A; git commit -q -m init; git remote add origin "$BORIGIN"; git push -q -u origin main ) >/dev/null 2>&1
TMPB="$(mktemp -d)"; git clone -q "$BORIGIN" "$TMPB/c" >/dev/null 2>&1
( cd "$TMPB/c"; gitcfg .; printf 'l1\nORIGIN\nl3\n' > script.sh
  git add script.sh; git commit -q -m adv; git push -q origin main ) >/dev/null 2>&1
rm -rf "$TMPB"
( cd "$BLC"; printf 'e\n' > a.md; git add a.md; git commit -q -m "unpushed" ) >/dev/null 2>&1   # diverge
printf 'l1\nWIP\nl3\n' > "$BLC/script.sh"                                                        # overlapping dirty WIP

set +e
( cd "$BLC" && govern::pull_rebase_autostash "$BLC" ); b1_rc=$?
set -e
assert_eq "$b1_rc" "0" "B1: helper returns 0 on an overlapping autostash-pop conflict (recovered, synced)"
assert_eq "$(cd "$BLC" && git ls-files --unmerged | wc -l | tr -d ' ')" "0" "B1: index is CLEAN after recovery (no unmerged entries — not wedged)"
assert_eq "$(cd "$BLC" && git rev-parse HEAD~1)" "$(cd "$BLC" && git rev-parse origin/main)" "B1: local main is rebased ONTO origin/main (origin advance is an ancestor)"
assert_contains "$(cd "$BLC" && git stash list)" "stash@{0}" "B1: co-tenant WIP preserved in the stash"
assert_contains "$(cd "$BLC" && git stash show -p stash@{0} 2>/dev/null)" "WIP" "B1: the stashed diff holds the co-tenant WIP"
# Sanity: after recovery the checkout is usable — a fresh commit works.
set +e
( cd "$BLC" && printf 'x\n' >> tickets.md && git add tickets.md && git commit -q -m ok ) >/dev/null 2>&1; b1_commit_rc=$?
set -e
assert_eq "$b1_commit_rc" "0" "B1: a commit succeeds after recovery (checkout not wedged)"

# B2: genuine content conflict on a meta file (both sides edit the SAME line) → returns 1, aborts, WIP kept.
C="$ROOT/c"; mkdir -p "$C"
CORIGIN="$C/origin.git"; CLC="$C/local"
git init -q --bare "$CORIGIN"; git init -q "$CLC"; gitcfg "$CLC"
mk_ws_stub "$CLC"
( cd "$CLC"; git checkout -q -b main
  printf 'l1\nl2\nl3\n' > tickets.md; printf 'co-tenant\nunrelated\n' > context.md
  git add -A; git commit -q -m init; git remote add origin "$CORIGIN"; git push -q -u origin main ) >/dev/null 2>&1
TMPC="$(mktemp -d)"; git clone -q "$CORIGIN" "$TMPC/c" >/dev/null 2>&1
( cd "$TMPC/c"; gitcfg .; printf 'l1\nl2\nORIGIN-EDIT\n' > tickets.md
  git add tickets.md; git commit -q -m "origin edits tickets line3"; git push -q origin main ) >/dev/null 2>&1
rm -rf "$TMPC"
# A's OWN local edit to the SAME tickets.md line3 → a genuine, unresolvable content conflict.
( cd "$CLC"; printf 'l1\nl2\nLOCAL-EDIT\n' > tickets.md; git add tickets.md; git commit -q -m "local edits tickets line3" ) >/dev/null 2>&1
# Plus an unrelated dirty co-tenant file that must survive the abort.
printf 'co-tenant — dirtied\nunrelated\nextra\n' > "$CLC/context.md"
C_CTX_BEFORE="$(shasum "$CLC/context.md")"

set +e
( cd "$CLC" && govern::pull_rebase_autostash "$CLC" ); b2_rc=$?
set -e
assert_eq "$b2_rc" "1" "B2: helper returns 1 on a GENUINE meta-file content conflict (fail-closed, not masked)"
assert_eq "$(cd "$CLC" && git rev-parse --abbrev-ref HEAD)" "main" "B2: left cleanly on main after abort (not mid-rebase)"
assert_eq "$(cd "$CLC" && git ls-files --unmerged | wc -l | tr -d ' ')" "0" "B2: no unmerged entries after the aborted conflict"
assert_eq "$(shasum "$CLC/context.md")" "$C_CTX_BEFORE" "B2: unrelated dirty co-tenant file byte-identical after the aborted rebase"
assert_contains "$(cd "$CLC" && git status --porcelain context.md)" " M context.md" "B2: co-tenant file still dirty/uncommitted after abort (never touched)"

assert_done
