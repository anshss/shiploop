#!/usr/bin/env bash
# file-ticket.sh had ZERO dedup before this — only collision-safe numbering and a heading-collision
# lint. That gap is exactly how two tickets can get filed for the identical root cause, needing a
# manual supervisor merge. This proves the cheap word-overlap flag:
#   1. a title overlapping an existing ticket's title is FILED (never blocked) with a
#      "possible duplicate of #M" marker prepended to its body.
#   2. an unrelated title is filed with no marker.
#   3. numbering / seq bumping is unaffected by the flag (still collision-safe).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
FILE_TICKET="$DIR/../file-ticket.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"

cat > "$T/tickets.md" <<'EOF'
# Tickets

## #900 — publish failed on v0.5.3 and v0.5.4 — release wrapper stuck at old version

**Severity:** High

body one

---
EOF

# 1. overlapping title → filed, flagged as a possible duplicate of #900.
got="$(printf 'Where: x\nObserved: publish keeps failing\nDone when: y\n' \
  | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "publish failed on v0.5.5 — wrapper stuck at old version" Low)"
assert_eq "$got" "901" "overlapping title still files normally (#901)"
assert_contains "$(cat "$T/tickets.md")" "possible duplicate of #900" "flagged as possible duplicate of #900"
assert_eq "$(grep -c '^## #901 —' "$T/tickets.md")" "1" "ticket #901 block appended despite the flag"

# 2. unrelated title → filed with NO marker.
got2="$(printf 'Where: y\nDone when: z\n' \
  | GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" bash "$FILE_TICKET" "unrelated layout regression in an unrelated panel" Low)"
assert_eq "$got2" "902" "unrelated title still files normally (#902)"
blk="$(awk '/^## #902 —/,/^---$/' "$T/tickets.md")"
if printf '%s' "$blk" | grep -q "possible duplicate"; then
  echo "FAIL - unrelated ticket #902 wrongly flagged"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - unrelated ticket #902 NOT flagged"
fi

assert_done
