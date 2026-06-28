#!/usr/bin/env bash
# Regression for #252: an autonomous validation's evidence must be promoted into the git-tracked sink
# + a greppable pointer, and a dangling ref must fail a check. Hermetic + generic (org acme). Proves:
#   (1) bookkeep on a PASS (validation.ranLiveTest=true + evidence) WRITES + commits
#       .claude/context/validation/ticket-<N>-<slug>.md and records a pointer in ticket-history.jsonl;
#   (2) bookkeep does NOT promote when ranLiveTest!=true or evidence is empty (ordinary tickets);
#   (3) bookkeep NEVER clobbers a pre-existing (hand-authored) summary, but still records the pointer;
#   (4) lint-validation-refs.sh exits 0 when every ref resolves, 1 (naming the file) when one dangles,
#       and IGNORES doc globs/placeholders (`ticket-<N>-*.md`);
#   (5) wiring: the Stop hook runs lint-validation-refs.sh; bookkeep routes the promotion.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"
VLINT="$DIR/../lint-validation-refs.sh"
# Stop hook lives at templates/hooks/ (installs to scripts/ at scaffold time).
SWEEP="$DIR/../../hooks/ticket-sweep-reminder.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T"     # keep this fixture's tickets.md at the sandbox root
mkdir -p "$T/governor" "$T/.claude/context/validation"
source "$DIR/../lib/common.sh"   # helpers bound to the temp WS_ROOT
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

mk_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets

## #40 — VALIDATION: does cross-provider restore round-trip

**Severity:** Medium

body

---

## #41 — ordinary code fix

**Severity:** Low

body

---
EOF
( cd "$T" && git add -A && git commit -q -m tickets >/dev/null 2>&1 ); }

HIST="$T/governor/ticket-history.jsonl"

# ── 1. PASS validation → promote summary + record pointer ──
mk_tickets; : > "$HIST"
rpt='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"https://x/99"},"newTickets":[],"lessonPatch":null,"validation":{"required":true,"ranLiveTest":true,"evidence":"deploy 3045 → snapshot snap_x → restore on api; sha256 byte-identical — PASS"}}'
GOVERN_NO_PUSH=1 GOVERN_HISTORY_FILE="$HIST" GOVERN_TICKETS_FILE="$T/tickets.md" \
  printf '%s' "$rpt" | bash "$BK" 40 >/dev/null 2>&1
vfile="$T/.claude/context/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md"
assert_eq "$(test -f "$vfile" && echo y || echo n)" "y" "promote: validation summary written at ticket-40-<slug>.md"
assert_contains "$(cat "$vfile" 2>/dev/null)" "byte-identical — PASS" "promote: summary carries validation.evidence verdict"
assert_contains "$(cat "$vfile" 2>/dev/null)" "alpha#99" "promote: summary lists the PR"
# committed in the resolve commit (not left dirty)
assert_eq "$(cd "$T" && git status --porcelain .claude/context/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md | wc -l | tr -d ' ')" "0" "promote: summary committed, working tree clean"
assert_contains "$(cd "$T" && git log -1 --name-only --format= 2>/dev/null)" "ticket-40-validation-does-cross-provider-restore-round-trip.md" "promote: summary is part of the resolve commit"
# pointer recorded
ptr="$(grep '"validationDoc"' "$HIST" 2>/dev/null || true)"
assert_contains "$ptr" "\"ticket\":40" "pointer: history entry names ticket 40"
assert_contains "$ptr" ".claude/context/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md" "pointer: history entry records the validationDoc path"
assert_contains "$ptr" "\"repo\":\"alpha\"" "pointer: history entry records the PR repo"
assert_contains "$ptr" "\"number\":99" "pointer: history entry records the PR number"
assert_contains "$ptr" "validation-evidence" "pointer: history entry tagged kind=validation-evidence (greppable)"

# ── 2. ordinary ticket (no live test) → NO promotion, NO pointer ──
mk_tickets; : > "$HIST"
GOVERN_NO_PUSH=1 GOVERN_HISTORY_FILE="$HIST" GOVERN_TICKETS_FILE="$T/tickets.md" \
  printf '{"status":"resolved","pr":{"repo":"api","number":7},"newTickets":[],"lessonPatch":null,"validation":null}' | bash "$BK" 41 >/dev/null 2>&1
assert_eq "$(ls "$T/.claude/context/validation"/ticket-41-* 2>/dev/null | wc -l | tr -d ' ')" "0" "no-promote: ordinary ticket writes no validation summary"
assert_eq "$(grep '"ticket":41' "$HIST" 2>/dev/null | wc -l | tr -d ' ')" "0" "no-promote: ordinary ticket writes no pointer"

# ── 3. pre-existing hand-authored summary is NOT clobbered, pointer still recorded ──
mk_tickets; : > "$HIST"
hand="$T/.claude/context/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md"
printf 'HAND-AUTHORED — do not overwrite\n' > "$hand"
( cd "$T" && git add -A && git commit -q -m hand >/dev/null 2>&1 )
GOVERN_NO_PUSH=1 GOVERN_HISTORY_FILE="$HIST" GOVERN_TICKETS_FILE="$T/tickets.md" \
  printf '%s' "$rpt" | bash "$BK" 40 >/dev/null 2>&1
assert_eq "$(cat "$hand")" "HAND-AUTHORED — do not overwrite" "no-clobber: existing summary left untouched"
assert_contains "$(grep '"validationDoc"' "$HIST" 2>/dev/null || true)" "ticket-40-validation-does-cross-provider-restore-round-trip.md" "no-clobber: pointer still recorded for the existing summary"

# ── 4. lint-validation-refs.sh: clean / dangling / glob-ignored ──
L="$(mktemp -d)"; mkdir -p "$L/.claude/context/validation"
cat > "$L/CLAUDE.md" <<'EOF'
- Evidence: `.claude/context/validation/ticket-11-x.md`
- Glob placeholder must NOT match: `.claude/context/validation/ticket-<N>-*.md`
EOF
echo ok > "$L/.claude/context/validation/ticket-11-x.md"
bash "$VLINT" "$L" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "lint: all refs resolve (and glob placeholder ignored) → exit 0"
# now add a dangling ref
cat > "$L/.claude/context/features.md" <<'EOF'
- Validation evidence: `.claude/context/validation/ticket-99-gone.md`
EOF
out="$(bash "$VLINT" "$L" 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "lint: a dangling ref → exit 1"
assert_contains "$out" "ticket-99-gone.md" "lint: names the missing summary"
assert_contains "$out" "features.md" "lint: names the citing source file"
rm -rf "$L"

# ── 5. wiring ──
assert_contains "$(cat "$SWEEP")" "lint-validation-refs.sh" "Stop hook runs the dangling-validation-ref lint"
assert_contains "$(cat "$BK")" ".claude/context/validation" "bookkeep promotes into the committed validation sink"
assert_contains "$(cat "$BK")" "validationDoc" "bookkeep records the greppable evidence pointer"

assert_done
