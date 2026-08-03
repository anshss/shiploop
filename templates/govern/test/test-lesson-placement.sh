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

rm -f /tmp/bk-out.$$ /tmp/bk-log.$$
assert_done
