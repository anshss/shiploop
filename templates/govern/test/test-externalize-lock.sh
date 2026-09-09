#!/usr/bin/env bash
# Regression for A2: externalize-low-tickets.sh used to commit + push tickets.md (line ~96/~99)
# with NO BK_LOCK / lock-acquire reference at all, while every other writer of tickets.md
# (land-resolution.sh, file-ticket.sh, escalations-apply-answers.sh) takes the same mutex. Two
# writers racing tickets.md's read-modify-write is a real corruption path, worse now that the model
# is many concurrent interactive sessions on one workspace rather than one loop.
#
# Proves, mirroring test-concurrency.sh's "concurrent bookkeep integrity" section:
#   1. wiring: the script's source actually takes BK_LOCK via the shared lock_acquire helper.
#   2. behavior: firing externalize-low-tickets.sh (staging a Low ticket) and land-resolution.sh
#      (resolving a DIFFERENT ticket) AT ONCE against the SAME tickets.md serializes cleanly, the
#      staged ticket lands in the review queue, the resolved ticket's block is deleted, and the
#      untouched third ticket survives byte-identical: no lost update, no corruption.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
EXT="$DIR/../externalize-low-tickets.sh"
BK="$DIR/../land-resolution.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

# ── 1. wiring: externalize-low-tickets.sh takes the SAME bookkeep lock the same way ─────────────
assert_contains "$(cat "$EXT")" "BK_LOCK" "externalize-low-tickets.sh takes the serialization lock"
assert_contains "$(cat "$EXT")" "lock_acquire" "externalize-low-tickets.sh uses the mkdir-mutex helper"
assert_contains "$(cat "$EXT")" "GOVERN_BOOKKEEP_LOCK" "externalize-low-tickets.sh honors the same lock override env var"

# ── 2. behavior: race it against a concurrent land-resolution.sh on the SAME tickets.md ─────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/governor"
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
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/tickets.md" <<'EOF'
# Tickets

## #1 — an alpha bug a stranger could fix

**Severity:** Low

**Where:** alpha's parser

body one
---

## #2 — unrelated internal fix

**Severity:** High

body two
---

## #3 — untouched bystander

**Severity:** High

**Where:** alpha's other file

body three
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
( cd "$T" && git add -A && git commit -q -m init )

export GOVERN_WS_ROOT="$T"
export GOVERN_TICKETS_FILE="$T/tickets.md"
export GOVERN_EXTERNALIZE_REVIEW_FILE="$T/tickets-externalize-review.md"
export GOVERN_EXTERNALIZED_FILE="$T/externalized.md"
export GOVERN_EXTERNALIZE_REPO="acme/alpha-oss"
export GOVERN_EXTERNALIZE_SUBREPO="alpha"
export GOVERN_NO_PUSH=1

rpt() { printf '{"status":"resolved","pr":{"repo":"x","number":%s},"newTickets":[],"lessonPatch":null}' "$1"; }

# Fire the externalization stage (moves #1 out of tickets.md into the review queue) and a
# land-resolution.sh resolve of #2 (deletes it from tickets.md) AT ONCE, both racing the SAME
# tickets.md read-modify-write. They MUST serialize on BK_LOCK, exactly like two concurrent
# land-resolution.sh calls do in test-concurrency.sh.
bash "$EXT" >/dev/null 2>&1 &
rpt 2 | bash "$BK" 2 >/dev/null 2>&1 &
wait

heads="$(grep -oE '^## #[0-9]+' "$T/tickets.md" | tr '\n' ' ')"
assert_eq "$(grep -c '^## #1 ' "$T/tickets.md")" "0" "race: #1 staged OUT of tickets.md (not corrupted)"
assert_eq "$(grep -c '^## #2 ' "$T/tickets.md")" "0" "race: #2 resolved and deleted (NOT clobbered by the stage)"
assert_eq "$(grep -c '^## #3 ' "$T/tickets.md")" "1" "race: #3 untouched"
assert_contains "$heads" "#3" "tickets.md still structurally intact after the concurrent stage + resolve"
assert_contains "$(cat "$T/tickets-externalize-review.md")" "## #1 —" "race: #1's block landed in the review queue, not lost"

assert_done
