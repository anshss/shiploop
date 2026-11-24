#!/usr/bin/env bash
# A RENAMED path is INCONCLUSIVE, never stale: `git log -- <path>` only ever sees the DELETE side
# of a rename (pathspec limits the diff BEFORE rename pairing runs), so the gate used to call a
# ticket stale because `dir/setups/` was gone — when it had simply moved to `dir/pods/` and the
# defect was live at the new path. The gate now re-inspects the last touching commit's UNRESTRICTED
# diff with rename detection and downgrades any rename to an inconclusive verdict (exit 0).
# Negative control: a TRUE deletion (no rename on the last touching commit) still exits 10.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
GATE="$DIR/../staleness-gate.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
gitcfg() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; }

git init -q "$TMP"; gitcfg "$TMP"
mkdir -p "$TMP/alpha"
printf 'export const moved = 1\n' > "$TMP/alpha/setup.js"
printf 'export const gone = 1\n' > "$TMP/alpha/dead.js"
( cd "$TMP" && git add -A && git commit -q -m init ) >/dev/null 2>&1
# one true deletion, one rename, in SEPARATE commits so each path's last touching commit is unambiguous
git -C "$TMP" rm -q "$TMP/alpha/dead.js"
( cd "$TMP" && git commit -q -m "delete dead.js" ) >/dev/null 2>&1
git -C "$TMP" mv "$TMP/alpha/setup.js" "$TMP/alpha/pods.js"
( cd "$TMP" && git commit -q -m "rename setup.js to pods.js" ) >/dev/null 2>&1

T="$TMP/tickets.md"
cat > "$T" <<'EOF'
## #1 — its only path was RENAMED away
**Severity:** High
**Files:** `alpha/setup.js`
---
## #2 — its only path was truly deleted
**Severity:** High
**Files:** `alpha/dead.js`
---
EOF

run() { # <N> -> sets RC and OUT
  set +e
  OUT="$(GOVERN_STALENESS_GATE="${SG:-1}" GOVERN_TICKETS_FILE="$T" "$GATE" "$1" 2>/dev/null)"
  RC=$?
  set +e
}

# the renamed path: INCONCLUSIVE (exit 0), naming the rename — never STALE.
run 1
assert_eq "$RC" "0" "#1: a renamed path is inconclusive, NOT stale (was exit 10 before)"
assert_contains "$OUT" "RENAMED" "#1: the verdict names the rename evidence"
assert_contains "$OUT" "alpha/setup.js" "#1: the verdict names the renamed path"

# the truly-deleted path: still confidently stale (negative control).
run 2
assert_eq "$RC" "10" "#2: a true deletion still exits 10 (negative control)"
assert_contains "$OUT" "STALE #2" "#2: verdict still says STALE"

# the sweep is per-ticket: a ticket naming BOTH is inconclusive if ANY path was renamed
# (the delete evidence on the other path cannot outrank the rename).
cat >> "$T" <<'EOF'
## #3 — mixed: one path renamed, one deleted
**Severity:** High
**Files:** `alpha/setup.js`, `alpha/dead.js`
---
EOF
run 3
assert_eq "$RC" "0" "#3: a rename on ANY named path makes the whole verdict inconclusive"

assert_done
