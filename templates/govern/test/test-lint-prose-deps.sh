#!/usr/bin/env bash
# #309 — non-blocking prose-dependency lint. Proves:
#   (A) govern::prose_dep_warnings flags a ticket that states a dep in PROSE ("Blocks #306",
#       "blocked by #N", "depends on #N") with NO bold **Depends on:**/**Blocks:** marker.
#   (B) a ticket carrying the canonical bold marker is SUPPRESSED (no warning), even if it also
#       mentions the dep in prose.
#   (C) lint-tickets.sh routes the warnings to stderr and keeps exit 0 (advisory, never blocks),
#       while a genuine duplicate heading still exits 1 (the warn pass never masks a real failure).
# Sandboxed: temp tickets.md, hermetic workspace stub; no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
LINT="$DIR/../lint-tickets.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT/ws"    # exports GOVERN_WS_ROOT so common.sh sources cleanly
source "$DIR/../lib/common.sh"

# Assertion: needle must NOT be present in haystack (assert.sh has no assert_absent).
assert_absent() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] WAS present but must be excluded\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# ── (A)+(B) helper-layer: prose flagged, marker suppressed ──
cat > "$ROOT/tickets.md" <<'EOF'
# Tickets
---
## #308 — the fix, prose-only edge (the #309 motivating case)
**Severity:** Low — Blocks #306, #307 in prose only, no marker.
body
---
## #320 — blocked-by prose, no marker
**Severity:** Low — this is blocked by #300 per the note.
body
---
## #400 — canonical marker present → suppressed
**Severity:** Low — also mentions it depends on #308 in prose, but declares the marker.
**Depends on:** #308
body
---
## #401 — no dependency language at all
**Severity:** Low — a clean, standalone ticket.
body
EOF

warns="$(govern::prose_dep_warnings "$ROOT/tickets.md")"
assert_contains "$warns" "#308: prose dependency" "A: prose 'Blocks #306' on #308 is flagged"
assert_contains "$warns" "#320: prose dependency" "A: prose 'blocked by #300' on #320 is flagged"
assert_absent "$warns" "#400" "B: #400 (has **Depends on:** marker) is NOT flagged despite prose"
assert_absent "$warns" "#401" "B: #401 (no dep language) is NOT flagged"

# ── (C) lint-tickets.sh: warnings on stderr, exit 0 (advisory) ──
set +e
out="$(bash "$LINT" "$ROOT/tickets.md" 2>"$ROOT/err.txt")"; rc=$?
set -e
assert_eq "$rc" "0" "C: prose warnings keep lint exit 0 (non-blocking)"
assert_eq "$out" "" "C: nothing on stdout (dup-heading channel) when there are no duplicates"
assert_contains "$(cat "$ROOT/err.txt")" "#308: prose dependency" "C: the warning is emitted to stderr"

# ── (C') a real duplicate heading STILL fails (warn pass never masks it) ──
cat > "$ROOT/dups.md" <<'EOF'
# Tickets
---
## #500 — first
**Severity:** Low — this ticket blocks #501 in prose.
body
---
## #500 — collided duplicate number
**Severity:** Low — y.
body
EOF
set +e
bash "$LINT" "$ROOT/dups.md" >/dev/null 2>"$ROOT/err2.txt"; rc2=$?
set -e
assert_eq "$rc2" "1" "C': a duplicate ## #N heading still exits 1 even alongside a prose warning"
assert_contains "$(cat "$ROOT/err2.txt")" "prose dependency" "C': the prose warning is ALSO surfaced on the dup run"

assert_done
