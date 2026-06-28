#!/usr/bin/env bash
# Regression for ticket #41: two govern drivers may run concurrently on disjoint tickets.
# Safety rests on three primitives — this proves each:
#   1. the mkdir-mutex helpers (lock_try / lock_release + stale reclaim),
#   2. concurrent bookkeep doesn't lose a block-delete (the corruption the lock prevents),
#   3. the wiring is in place (bookkeep lock, run-loop claim + GOVERN_ALLOW_CONCURRENT).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
BK="$DIR/../govern-bookkeep.sh"
RL="$DIR/../run-loop.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GOVERN_WS_ROOT="$T"
# common.sh sources $WS_ROOT/scripts/lib/workspace.sh; seed a minimal one in the temp WS_ROOT.
mkdir -p "$T/scripts/lib"
cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
GITHUB_ORG="acme"
REPOS=(alpha)
GOVERN_MERGE_REPOS=(alpha)
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
source "$DIR/../lib/common.sh"   # pulls in govern::lock_* against the temp WS_ROOT

# ── 1. lock primitives ──
L="$T/governor/.locks/t1"
govern::lock_try "$L" && rc=0 || rc=1;        assert_eq "$rc" "0" "lock_try claims a free lock"
govern::lock_try "$L" && rc=0 || rc=1;        assert_eq "$rc" "1" "lock_try fails when held by a live holder"
govern::lock_release "$L"
govern::lock_try "$L" && rc=0 || rc=1;        assert_eq "$rc" "0" "lock_try re-claims after release"
# stale reclaim: backdate the lock's mtime well past the stale window
touch -t 202001010000 "$L"
govern::lock_try "$L" 60 && rc=0 || rc=1;     assert_eq "$rc" "0" "lock_try reclaims a STALE lock (crashed holder)"
govern::lock_release "$L"

# ── 2. concurrent bookkeep integrity ──
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/tickets.md" <<'EOF'
# Tickets

## #1 — alpha

**Severity:** High

body one
---

## #2 — beta

**Severity:** High

body two
---

## #3 — gamma

**Severity:** Low

body three
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md" 2>/dev/null || { mkdir -p "$T/governor"; printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"; }
( cd "$T" && git add -A && git commit -q -m init )

rpt() { printf '{"status":"resolved","pr":{"repo":"x","number":%s},"newTickets":[],"lessonPatch":null}' "$1"; }
# fire two bookkeeps at once, each resolving a different ticket — they MUST serialize on BK_LOCK.
# NOTE: GOVERN_TICKETS_FILE must sit on the CONSUMER side of the pipe — a prefix before `rpt N` would
# apply only to `rpt`, never to the `bash "$BK"` that actually reads it (the bug that made this test
# silently pass on the wrong file pre-queue-move). GOVERN_WS_ROOT is already exported above.
rpt 1 | GOVERN_TICKETS_FILE="$T/tickets.md" bash "$BK" 1 >/dev/null 2>&1 &
rpt 2 | GOVERN_TICKETS_FILE="$T/tickets.md" bash "$BK" 2 >/dev/null 2>&1 &
wait

heads="$(grep -oE '^## #[0-9]+' "$T/tickets.md" | tr '\n' ' ')"
assert_eq "$(grep -c '^## #1 ' "$T/tickets.md")" "0" "concurrent bookkeep: #1 block deleted"
assert_eq "$(grep -c '^## #2 ' "$T/tickets.md")" "0" "concurrent bookkeep: #2 block deleted (NOT clobbered)"
assert_eq "$(grep -c '^## #3 ' "$T/tickets.md")" "1" "concurrent bookkeep: #3 untouched"
assert_contains "$heads" "#3" "tickets.md still structurally intact after concurrent edits"

# ── 3. wiring assertions (so the safety can't silently regress) ──
assert_contains "$(cat "$BK")" "BK_LOCK" "bookkeep takes the serialization lock"
assert_contains "$(cat "$BK")" "lock_acquire" "bookkeep uses the mkdir-mutex helper"
assert_contains "$(cat "$RL")" "GOVERN_ALLOW_CONCURRENT" "run-loop has the concurrent opt-in"
assert_contains "$(cat "$RL")" "lock_try" "run-loop takes a per-ticket claim lock"

assert_done
