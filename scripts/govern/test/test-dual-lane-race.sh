#!/usr/bin/env bash
# Regression for ticket #108: two concurrent govern drivers sharing one origin/main must not
# resurrect or re-process a ticket one of them already resolved+pushed. The bookkeep lock
# (govern/.locks/bookkeep) serializes writes WITHIN one driver but NOT the cross-driver git
# push/pull — so the guards live at the git level:
#   1. selector re-verify  — govern::ticket_present_on_origin: before spawning, confirm #N is still
#      on origin/main (a second driver may have resolved+deleted it AFTER our run-start preflight).
#   2. bookkeep pre-edit sync + push CAS loop — the block-delete is computed against the freshest
#      origin/main and re-applied (rebase) on every rejected push, so a stale-base commit can never
#      resurrect an already-deleted block on origin/main.
# Exercises both against a real bare-origin + local-clone pair. No network, no real harness repo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# WS_STUB: write a minimal scripts/lib/workspace.sh into CWD (a repo checkout). common.sh sources
# it under GOVERN_WS_ROOT=<checkout>; META_ROOT resolves to the checkout root from the file's path.
WS_STUB() {
  cat > scripts/lib/workspace.sh <<'WSEOF'
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="${META_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GITHUB_ORG="acme"
REPOS=(alpha)
GOVERN_MERGE_REPOS=(alpha)
wsp_is_merge_repo() { [ "$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "$GITHUB_ORG" "$1"; }
wsp_repo_localdir() { printf '%s/%s' "$META_ROOT" "$1"; }
WSEOF
}

# tickets.md body with the two blocks the race is about (#93 resolved by lane A, #99 by lane B).
TICKETS_BODY() {
  printf '# Tickets\n\n## Open\n\n'
  printf '## #93 — first ticket\n\n**Severity:** Medium\n\nbody 93\n\n---\n\n'
  printf '## #99 — second ticket\n\n**Severity:** Low\n\nbody 99\n\n---\n'
}

# Build a bare origin seeded with both ticket blocks; print the origin path.
setup_origin() {
  local base="$1" origin="$1/origin.git" seed="$1/seed"
  git init -q --bare "$origin"
  git init -q "$seed"
  ( cd "$seed"; git config user.email t@t; git config user.name t; git checkout -q -b main
    TICKETS_BODY > tickets.md
    # Seed a minimal workspace.sh so every clone has one: bookkeep/common.sh run under
    # GOVERN_WS_ROOT=<clone> and source <clone>/scripts/lib/workspace.sh (resolved per checkout).
    mkdir -p scripts/lib; WS_STUB
    git add tickets.md scripts/lib/workspace.sh; git commit -q -m init
    git remote add origin "$origin"; git push -q -u origin main ) >/dev/null 2>&1
  rm -rf "$seed"
  printf '%s' "$origin"
}
# Clone an origin into $2; print the clone path.
clone() { git clone -q "$1" "$2" >/dev/null 2>&1; ( cd "$2"; git config user.email d@d; git config user.name d ) >/dev/null 2>&1; printf '%s' "$2"; }
# origin's tickets.md (via a throwaway show against the bare repo).
origin_tickets() { git -C "$1" show main:tickets.md 2>/dev/null; }
# "<behind>/<ahead>" of clone HEAD vs origin/main after a fresh fetch.
converged() { ( cd "$1"; git fetch -q origin main 2>/dev/null; git rev-list --left-right --count origin/main...HEAD | awk '{print $1"/"$2}' ); }
# Run a bookkeep for ticket $2 in clone $1 with PR repo $3 (sub-repo unless "harness").
bookkeep() {
  local lc="$1" n="$2" repo="$3"
  local report; report="$(jq -nc --arg r "$repo" --argjson n "$n" '{status:"resolved",pr:{repo:$r,number:$n,url:"u"},newTickets:[]}')"
  GOVERN_WS_ROOT="$lc" GOVERN_TICKETS_FILE="$lc/tickets.md" \
    printf '%s' "$report" | GOVERN_WS_ROOT="$lc" GOVERN_TICKETS_FILE="$lc/tickets.md" bash "$BK" "$n" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Part 1 — govern::ticket_present_on_origin (the selector re-verify guard)
# ─────────────────────────────────────────────────────────────────────────────
O1="$(setup_origin "$ROOT/p1")"; L1="$(clone "$O1" "$ROOT/p1/lc")"
# Source common.sh scoped to this clone so the helper resolves TICKETS_FILE's basename.
( export GOVERN_WS_ROOT="$L1" GOVERN_TICKETS_FILE="$L1/tickets.md"
  source "$DIR/../lib/common.sh"

  govern::ticket_present_on_origin "$L1" 93 && r=0 || r=$?
  assert_eq "${r:-0}" "0" "present: #93 on origin/main → spawn (rc 0)"

  # A second driver resolves+deletes #99 on origin; our LOCAL clone is now stale (still lists #99).
  TMP="$ROOT/p1/c2"; git clone -q "$O1" "$TMP" >/dev/null 2>&1
  ( cd "$TMP"; git config user.email o@o; git config user.name o
    awk '/^## #99 /{g=1} g&&/^---[[:space:]]*$/{g=0;next} g{next} {print}' tickets.md > t && mv t tickets.md
    git commit -qam 'resolve #99'; git push -q origin main ) >/dev/null 2>&1
  # Local clone STILL has #99 in its working tree — the stale-selection window.
  grep -q '## #99 ' "$L1/tickets.md" || { echo "fixture broken: #99 should still be in stale local"; exit 1; }
  govern::ticket_present_on_origin "$L1" 99 && r=0 || r=$?
  assert_eq "${r:-0}" "1" "absent on origin (stale local still lists it) → skip (rc 1)"

  # #93 untouched on origin → still spawnable.
  govern::ticket_present_on_origin "$L1" 93 && r=0 || r=$?
  assert_eq "${r:-0}" "0" "untouched #93 still present → spawn (rc 0)"

  # Fail-open: GOVERN_NO_PUSH=1 → always present (never block selection on a no-verify env).
  GOVERN_NO_PUSH=1 govern::ticket_present_on_origin "$L1" 99 && r=0 || r=$?
  assert_eq "${r:-0}" "0" "GOVERN_NO_PUSH=1 → fail-open present (rc 0)"
)

# Fail-open: no origin remote (local-only test repo shape) → present.
LNR="$ROOT/p1/noremote"; git init -q "$LNR"
( cd "$LNR"; git config user.email t@t; git config user.name t; TICKETS_BODY > tickets.md; mkdir -p scripts/lib; WS_STUB; git add tickets.md scripts/lib/workspace.sh; git commit -q -m i ) >/dev/null 2>&1
( export GOVERN_WS_ROOT="$LNR" GOVERN_TICKETS_FILE="$LNR/tickets.md"; source "$DIR/../lib/common.sh"
  govern::ticket_present_on_origin "$LNR" 93 && r=0 || r=$?
  assert_eq "${r:-0}" "0" "no origin remote → fail-open present (rc 0)" )

# ─────────────────────────────────────────────────────────────────────────────
# Part 2 — bookkeep must not resurrect a concurrently-resolved block
# ─────────────────────────────────────────────────────────────────────────────
# Lane A resolves #93 first (sub-repo PR). Lane B then resolves #99 from a clone that is STALE
# (it predates A's #93 deletion). The pre-edit origin sync + push CAS loop must land both deletes
# with NEITHER block resurrected on origin/main.
O2="$(setup_origin "$ROOT/p2")"
LA="$(clone "$O2" "$ROOT/p2/laneA")"
LB="$(clone "$O2" "$ROOT/p2/laneB")"   # cloned at the same base — both still list #93 and #99

bookkeep "$LA" 93 "web"            # lane A: delete #93, push → origin loses #93
ot="$(origin_tickets "$O2")"
assert_contains "$ot" "## #99 " "A: #99 still open on origin after A resolves #93"
printf '%s' "$ot" | grep -q '## #93 ' && f=1 || f=0
assert_eq "$f" "0" "A: #93 deleted from origin/main"

# Lane B is stale (its working tree still has BOTH blocks). Resolve #99 from it.
grep -q '## #93 ' "$LB/tickets.md" || { echo "fixture: laneB should be stale with #93"; exit 1; }
bookkeep "$LB" 99 "alpha"   # lane B: pre-edit sync pulls A's delete, then deletes #99
ot="$(origin_tickets "$O2")"
printf '%s' "$ot" | grep -q '## #93 ' && f=1 || f=0
assert_eq "$f" "0" "B: #93 NOT resurrected on origin (stale-base bookkeep reconciled)"
printf '%s' "$ot" | grep -q '## #99 ' && f=1 || f=0
assert_eq "$f" "0" "B: #99 deleted from origin/main"
assert_eq "$(converged "$LB")" "0/0" "B: lane-B clone converged with origin/main"

# ─────────────────────────────────────────────────────────────────────────────
# Part 3 — push CAS loop lands the delete when origin advanced before our push
# ─────────────────────────────────────────────────────────────────────────────
# Origin advances (a third ticket #150 appended + #93 deleted by another lane) AFTER lane B cloned.
# Bookkeeping #99 from the stale clone must still land #99's delete via rebase-retry, without
# resurrecting #93 or clobbering #150.
O3="$(setup_origin "$ROOT/p3")"
LB3="$(clone "$O3" "$ROOT/p3/laneB")"
TMP3="$ROOT/p3/adv"; git clone -q "$O3" "$TMP3" >/dev/null 2>&1
( cd "$TMP3"; git config user.email o@o; git config user.name o
  awk '/^## #93 /{g=1} g&&/^---[[:space:]]*$/{g=0;next} g{next} {print}' tickets.md > t && mv t tickets.md
  printf '\n## #150 — later ticket\n\n**Severity:** High\n\nbody 150\n\n---\n' >> tickets.md
  git commit -qam 'advance origin'; git push -q origin main ) >/dev/null 2>&1

bookkeep "$LB3" 99 "web"           # first push rejected (origin moved) → rebase-retry lands it
ot="$(origin_tickets "$O3")"
printf '%s' "$ot" | grep -q '## #99 ' && f=1 || f=0
assert_eq "$f" "0" "CAS: #99 delete landed on origin despite the concurrent advance"
assert_contains "$ot" "## #150 " "CAS: concurrent #150 preserved (rebase, not clobber)"
printf '%s' "$ot" | grep -q '## #93 ' && f=1 || f=0
assert_eq "$f" "0" "CAS: #93 stays deleted (not resurrected by the stale base)"
assert_eq "$(converged "$LB3")" "0/0" "CAS: clone converged after rebase-retry push"

assert_done
