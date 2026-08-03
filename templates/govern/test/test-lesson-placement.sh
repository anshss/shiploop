#!/usr/bin/env bash
# Regression for the lesson placement gate (#83 Part 1): govern-bookkeep.sh must NOT trust a
# worker's claim that a lessonPatch belongs at root — it re-derives placement from the lesson TEXT
# via govern::lesson_placement (lib/common.sh) and redirects an unambiguously sub-repo-scoped lesson
# to that sub-repo's own CLAUDE.md instead of letting it accrete on the always-on root file. The
# decision is conservative BY DESIGN: it redirects ONLY when exactly one REPOS entry is referenced as
# a PATH, no other REPOS entry is mentioned at all, and no cross-cutting signal word (governor,
# workspace.sh, meta-repo, …) is present — every other shape stays at root.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # REPOS=(alpha web) per assert.sh's default merge-csv

mk_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets

## #9 — some fixed bug

**Severity:** Medium

body

---
EOF
}

( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
mk_tickets
printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
printf 'alpha/\nweb/\n' > "$T/.gitignore"   # sub-repos are independent checkouts, gitignored from the root (matches production)
( cd "$T" && git add -A && git commit -q -m init >/dev/null 2>&1 )

# Real sub-repo checkouts (independent git trees, exactly as a live workspace has them) so a
# redirect has somewhere real to land + commit into.
for r in alpha web; do
  mkdir -p "$T/$r"
  ( cd "$T/$r" && git init -q && git config user.email t@t && git config user.name t
    printf '# %s\n\nsub-repo-local conventions.\n' "$r" > CLAUDE.md
    git add -A && git commit -q -m init >/dev/null 2>&1 )
done

reset_all() {
  mk_tickets
  printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
  ( cd "$T" && git add -A && git commit -q -m reset >/dev/null 2>&1 || true )
  for r in alpha web; do
    printf '# %s\n\nsub-repo-local conventions.\n' "$r" > "$T/$r/CLAUDE.md"
    ( cd "$T/$r" && git add -A && git commit -q -m reset >/dev/null 2>&1 || true )
  done
}

run_bk() { # <report-json>
  printf '%s' "$1" | GOVERN_NO_PUSH=1 GOVERN_TICKETS_FILE="$T/tickets.md" bash "$BK" 9 >/tmp/bk-out.$$ 2>/tmp/bk-log.$$
}

# ── 1. unambiguous single-sub-repo lesson (a path, one repo, no cross-cutting word) → REDIRECTED ──
reset_all
lesson1='Always cd into alpha/src before running the migrator — alpha/scripts/migrate.sh assumes it.'
rpt1=$(jq -n --arg t "$lesson1" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt1"
assert_not_contains "$(cat "$T/CLAUDE.md")" "$lesson1" "unambiguous single-repo: root CLAUDE.md NOT touched"
assert_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson1" "unambiguous single-repo: lesson landed in alpha/CLAUDE.md"
assert_eq "$(cd "$T/alpha" && git status --porcelain CLAUDE.md | wc -l | tr -d ' ')" "0" "unambiguous single-repo: alpha/CLAUDE.md committed (not left dirty)"
assert_contains "$(cat /tmp/bk-log.$$)" "redirected root CLAUDE.md -> alpha/CLAUDE.md" "unambiguous single-repo: redirect logged"

# ── 2. cross-repo / harness signal alongside a sub-repo path → STAYS AT ROOT ──
reset_all
lesson2='The governor spawns a worker into alpha/scripts/build.sh as part of workspace.sh dispatch.'
rpt2=$(jq -n --arg t "$lesson2" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt2"
assert_contains "$(cat "$T/CLAUDE.md")" "$lesson2" "cross-cutting signal: lesson stayed in root CLAUDE.md"
assert_not_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson2" "cross-cutting signal: alpha/CLAUDE.md NOT touched"
assert_contains "$(cat /tmp/bk-log.$$)" "staying at root CLAUDE.md" "cross-cutting signal: stay-at-root logged"

# ── 3. two sub-repos referenced → STAYS AT ROOT ──
reset_all
lesson3='A change in alpha/api/routes.ts must ship together with the matching web/src/client.ts update.'
rpt3=$(jq -n --arg t "$lesson3" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt3"
assert_contains "$(cat "$T/CLAUDE.md")" "$lesson3" "two-sub-repo: lesson stayed in root CLAUDE.md"
assert_not_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson3" "two-sub-repo: alpha/CLAUDE.md NOT touched"
assert_not_contains "$(cat "$T/web/CLAUDE.md")" "$lesson3" "two-sub-repo: web/CLAUDE.md NOT touched"
assert_contains "$(cat /tmp/bk-log.$$)" "staying at root CLAUDE.md" "two-sub-repo: stay-at-root logged"

# ── 4. no sub-repo signal at all (generic rule) → STAYS AT ROOT (pre-existing behavior, unchanged) ──
reset_all
lesson4='Never run destructive git operations without confirming which checkout you are in first.'
rpt4=$(jq -n --arg t "$lesson4" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt4"
assert_contains "$(cat "$T/CLAUDE.md")" "$lesson4" "no-signal: lesson stayed in root CLAUDE.md"
assert_contains "$(cat /tmp/bk-log.$$)" "no sub-repo path signal" "no-signal: reason logged as no-signal"

# ── 5. lesson recommends itself be added to its OWN sub-repo's CLAUDE.md → STILL REDIRECTED ──
# A lesson naming "<repo>/CLAUDE.md" is ordinary self-referential phrasing ("put this rule in
# alpha/CLAUDE.md"), not a cross-cutting signal — only a BARE/root "CLAUDE.md" mention, or another
# repo's CLAUDE.md, should force root (govern::lesson_placement's self-reference scrub).
reset_all
lesson5='Document in alpha/CLAUDE.md that alpha/scripts/deploy.sh needs AWS_PROFILE set first.'
rpt5=$(jq -n --arg t "$lesson5" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt5"
assert_not_contains "$(cat "$T/CLAUDE.md")" "$lesson5" "self-reference: root CLAUDE.md NOT touched"
assert_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson5" "self-reference: lesson still redirected into alpha/CLAUDE.md"
assert_contains "$(cat /tmp/bk-log.$$)" "redirected root CLAUDE.md -> alpha/CLAUDE.md" "self-reference: redirect logged"

# ── 6. sub-repo push fails (e.g. branch protection / no credential / rejected) → FALLS BACK TO ROOT ──
# Give alpha a real-looking origin that can never be reached, and DON'T set GOVERN_NO_PUSH so the
# push actually gets attempted (and fails). The redirect must roll back alpha's working tree to
# clean AND still land the lesson in root CLAUDE.md — never silently lost.
reset_all
( cd "$T/alpha" && git remote add origin "file:///nonexistent/$$/alpha.git" )
lesson6='Always vendor the alpha/vendor/lockfile.json before running alpha/scripts/build.sh.'
rpt6=$(jq -n --arg t "$lesson6" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
printf '%s' "$rpt6" \
  | GOVERN_TICKETS_FILE="$T/tickets.md" bash "$BK" 9 >/tmp/bk-out.$$ 2>/tmp/bk-log.$$
assert_contains "$(cat "$T/CLAUDE.md")" "$lesson6" "push-fails: lesson FELL BACK to root CLAUDE.md"
assert_not_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson6" "push-fails: alpha/CLAUDE.md NOT left with the lesson"
assert_eq "$(cd "$T/alpha" && git status --porcelain | wc -l | tr -d ' ')" "0" "push-fails: alpha working tree left CLEAN (no dirty/half-applied edit)"
assert_contains "$(cat /tmp/bk-log.$$)" "falling BACK TO ROOT" "push-fails: fallback logged"
( cd "$T/alpha" && git remote remove origin )

# ── 7. sub-repo tree is DIRTY (unrelated uncommitted work) → redirect SKIPPED, root used, ──
#      the unrelated file is left exactly as it was (never written/committed/touched at all).
reset_all
printf 'unrelated in-progress edit — not part of this test\n' > "$T/alpha/scratch-wip.txt"
( cd "$T/alpha" && git add scratch-wip.txt )   # staged, uncommitted — mimics an operator mid-edit
lesson7='Remember to run alpha/scripts/lint.sh with --fix before committing.'
rpt7=$(jq -n --arg t "$lesson7" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
run_bk "$rpt7"
assert_contains "$(cat "$T/CLAUDE.md")" "$lesson7" "dirty-tree: lesson landed in root CLAUDE.md instead"
assert_not_contains "$(cat "$T/alpha/CLAUDE.md")" "$lesson7" "dirty-tree: alpha/CLAUDE.md NOT touched (redirect never attempted)"
assert_eq "$(cat "$T/alpha/scratch-wip.txt")" "unrelated in-progress edit — not part of this test" "dirty-tree: the unrelated uncommitted file is unmodified"
assert_contains "$(cd "$T/alpha" && git status --porcelain)" "scratch-wip.txt" "dirty-tree: the unrelated file is STILL staged exactly as it was (untouched)"
assert_contains "$(cat /tmp/bk-log.$$)" "DIRTY" "dirty-tree: skip reason logged"
( cd "$T/alpha" && git reset -q -- scratch-wip.txt && rm -f scratch-wip.txt )

rm -f /tmp/bk-out.$$ /tmp/bk-log.$$
assert_done
