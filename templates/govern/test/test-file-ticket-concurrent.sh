#!/usr/bin/env bash
# Regression for #240: a MANUAL filing via file-ticket.sh while a governor run is active must PERSIST
# (committed + pushed) and survive a concurrent driver's bookkeep rewriting/pushing tickets.md — never
# silently clobbered. The original bug: file-ticket.sh left the append UNCOMMITTED, so a running
# driver's bookkeep rewrote tickets.md on its own base and the appended entries were LOST with no error.
#
# The fix holds the bookkeep lock across allocate→append→commit→push, syncs onto origin/main before
# appending, and CAS-pushes its append-only commit with rebase-retry (exactly like govern-bookkeep).
# Exercised against a real bare-origin + two clones (one driver lane, one manual filer):
#   S1  pre-edit-sync path — driver's bookkeep already landed on origin before the filing runs.
#   S2  CAS-rebase path    — origin advances (driver's delete lands) DURING the filing, between its
#                            pre-edit sync and its push, forced deterministically via a pre-push hook.
#   S3  core invariant     — the filing NEVER leaves an uncommitted append (the #240 root cause),
#                            and the legacy GOVERN_FILE_TICKET_NO_COMMIT=1 opt-out still appends-only.
# Hermetic + generic; no network, no real harness repo.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
FILE_TICKET="$DIR/../file-ticket.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

TICKETS_BODY() {
  printf '# Tickets\n\n'
  printf '## #93 — first ticket\n\n**Severity:** Medium\n\nbody 93\n\n---\n\n'
  printf '## #99 — second ticket\n\n**Severity:** Low\n\nbody 99\n\n---\n'
}

# Seed a clone's hermetic workspace.sh stub (file-ticket/bookkeep source it via common.sh; without it
# they'd read the LIVE workspace config). Generic: org acme, alpha auto-merge + web frontend.
seed_ws_stub() { # <clone-dir>
  mkdir -p "$1/scripts/lib"
  cat > "$1/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$1}"
GITHUB_ORG="acme"
REPOS=(alpha web)
GOVERN_MERGE_REPOS=(alpha)
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
}

# Bare origin seeded with both ticket blocks + a seq high-water mark of 99. Prints the origin path.
setup_origin() {
  local origin="$1/origin.git" seed="$1/seed"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main   # so clones check out `main`, not `master`
  git init -q "$seed"
  ( cd "$seed"; git config user.email t@t; git config user.name t; git checkout -q -b main
    mkdir -p governor; printf '99\n' > governor/.ticket-seq
    TICKETS_BODY > tickets.md; git add -A; git commit -q -m init
    git remote add origin "$origin"; git push -q -u origin main ) >/dev/null 2>&1
  rm -rf "$seed"
  printf '%s' "$origin"
}
clone() {
  git clone -q "$1" "$2" >/dev/null 2>&1
  ( cd "$2"; git config user.email d@d; git config user.name d ) >/dev/null 2>&1
  seed_ws_stub "$2"
  # Locally ignore the hermetic stub so it never shows as a dirty/untracked file in the filer's tree
  # (the #240 invariant asserts the working tree is clean after a filing — only tickets.md/seq move).
  printf 'scripts/\n' > "$2/.git/info/exclude"
  printf '%s' "$2"
}
origin_tickets() { git -C "$1" show main:tickets.md 2>/dev/null; }
dirty_count() { git -C "$1" status --porcelain 2>/dev/null | grep -c . | tr -d ' '; }

file_ticket() { # clone title  -> prints allocated number ; commits + CAS-pushes
  local lc="$1" t="$2"
  printf 'Where: x\nObserved: y\nDone when: z\n' \
    | GOVERN_WS_ROOT="$lc" GOVERN_TICKETS_FILE="$lc/tickets.md" bash "$FILE_TICKET" "$t" Low 2>/dev/null
}
bookkeep_push() {   # clone N  -> delete #N, commit, push to origin
  local lc="$1" n="$2"
  jq -nc --argjson n "$n" '{status:"resolved",pr:{repo:"web",number:$n,url:"u"},newTickets:[]}' \
    | GOVERN_WS_ROOT="$lc" GOVERN_TICKETS_FILE="$lc/tickets.md" bash "$BK" "$n" >/dev/null 2>&1
}
bookkeep_local() {  # clone N  -> delete #N, commit LOCALLY only (a hook publishes it later)
  local lc="$1" n="$2"
  jq -nc --argjson n "$n" '{status:"resolved",pr:{repo:"web",number:$n,url:"u"},newTickets:[]}' \
    | GOVERN_WS_ROOT="$lc" GOVERN_TICKETS_FILE="$lc/tickets.md" GOVERN_NO_PUSH=1 bash "$BK" "$n" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# S1 — pre-edit-sync path: the driver's bookkeep already pushed before the filing runs.
# ─────────────────────────────────────────────────────────────────────────────
O1="$(setup_origin "$ROOT/s1")"
LDRV="$(clone "$O1" "$ROOT/s1/driver")"
LFIL="$(clone "$O1" "$ROOT/s1/filer")"   # cloned at the same base — stale once the driver pushes

bookkeep_push "$LDRV" 93                  # concurrent driver: resolve #93, push → origin loses #93
num="$(file_ticket "$LFIL" "manual DX bug")"
assert_eq "$num" "100" "S1: manual filing allocated #100 off the seq high-water (99)"

ot="$(origin_tickets "$O1")"
assert_contains "$ot" "## #100 — manual DX bug" "S1: manual ticket #100 PERSISTED on origin/main"
assert_contains "$ot" "## #99 " "S1: pre-existing #99 still on origin"
grep -q '## #93 ' <<<"$ot" && f=1 || f=0
assert_eq "$f" "0" "S1: driver's #93 deletion preserved (manual append did not resurrect it)"
assert_eq "$(dirty_count "$LFIL")" "0" "S1: filer working tree clean — append committed, never left uncommitted"

# ─────────────────────────────────────────────────────────────────────────────
# S2 — CAS-rebase path: origin advances DURING the filing (after its pre-edit sync, before its push).
# ─────────────────────────────────────────────────────────────────────────────
O2="$(setup_origin "$ROOT/s2")"
LD2="$(clone "$O2" "$ROOT/s2/driver")"
LF2="$(clone "$O2" "$ROOT/s2/filer")"

bookkeep_local "$LD2" 93                  # driver resolves #93 and commits LOCALLY (not pushed yet)

# Pre-push hook on the FILER: on its first push, publish the driver's #93-delete to origin (so the
# filer's push is rejected non-ff → forces the rebase-retry CAS loop), then no-op on the retry.
hk="$LF2/.git/hooks"; mkdir -p "$hk"
cat > "$hk/pre-push" <<HOOK
#!/usr/bin/env bash
flag="$ROOT/s2/.raced"
[ -e "\$flag" ] && exit 0
touch "\$flag"
git -C "$LD2" push -q origin main >/dev/null 2>&1 || true
exit 0
HOOK
chmod +x "$hk/pre-push"

num2="$(file_ticket "$LF2" "manual during active run")"
assert_eq "$num2" "100" "S2: manual filing allocated #100"
assert_eq "$([ -e "$ROOT/s2/.raced" ] && echo y || echo n)" "y" "S2: pre-push hook fired — origin DID advance mid-filing (race window exercised)"

ot2="$(origin_tickets "$O2")"
assert_contains "$ot2" "## #100 — manual during active run" "S2: manual ticket SURVIVED the CAS-rebase race"
assert_contains "$ot2" "## #99 " "S2: #99 still present on origin"
grep -q '## #93 ' <<<"$ot2" && f=1 || f=0
assert_eq "$f" "0" "S2: driver's #93 delete (landed in the race window) preserved, not clobbered"
assert_eq "$(dirty_count "$LF2")" "0" "S2: filer working tree clean after the rebase-retry"

# ─────────────────────────────────────────────────────────────────────────────
# S3 — core invariant + legacy opt-out.
# ─────────────────────────────────────────────────────────────────────────────
O3="$(setup_origin "$ROOT/s3")"
LF3="$(clone "$O3" "$ROOT/s3/filer")"

# Default: a single filing with no concurrency still commits + pushes (never leaves an append).
num3="$(file_ticket "$LF3" "lonely filing")"
assert_eq "$num3" "100" "S3: default filing allocated #100"
assert_eq "$(dirty_count "$LF3")" "0" "S3: default filing leaves NO uncommitted append (the #240 root cause)"
assert_contains "$(origin_tickets "$O3")" "## #100 — lonely filing" "S3: default filing pushed to origin"

# Opt-out: GOVERN_FILE_TICKET_NO_COMMIT=1 keeps the legacy append-only behavior (uncommitted).
num4="$(printf 'b\n' | GOVERN_FILE_TICKET_NO_COMMIT=1 GOVERN_WS_ROOT="$LF3" GOVERN_TICKETS_FILE="$LF3/tickets.md" bash "$FILE_TICKET" "composed filing" Low 2>/dev/null)"
assert_eq "$num4" "101" "S3: opt-out filing allocated #101 (numbering still collision-safe)"
assert_contains "$(cat "$LF3/tickets.md")" "## #101 — composed filing" "S3: opt-out appended the block to the working tree"
gt0=$(dirty_count "$LF3"); [[ "$gt0" -ge 1 ]] && f=1 || f=0
assert_eq "$f" "1" "S3: opt-out left the append UNCOMMITTED for the caller to stage (legacy contract)"

assert_done
