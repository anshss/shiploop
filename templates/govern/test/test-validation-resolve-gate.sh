#!/usr/bin/env bash
# The BLOCKING validation gate in the Stop hook (ticket-sweep-reminder.sh, shiploop 1.19.2).
#
# The gate must fire on RESOLUTION WITHOUT A RECORD and on nothing else. The failure mode this
# guards is not a missed block, it is a FALSE block: the obvious session-blind implementation
# ("any open validation-shaped ticket with no evidence file") would refuse every session in a
# workspace that has an unvalidated validation ticket, forever, whether or not that session ever
# touched it. Assertion B below is the load-bearing one.
#
#   A. a validation-shaped block present in the base ref but ABSENT from the working tree, with no
#      .claude/shiploop/validation/ticket-<N>-*.md record, BLOCKS and names the ticket.
#   B. a validation-shaped block still PRESENT and merely unrecorded does NOT block.
#   C. removed AND recorded does NOT block.
#   D. GOVERN_VALIDATION_GATE=0 disables the block.
#   E. a removed NON-validation ticket does not block (the gate reads the block, not the number).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Hub checkout: templates/govern/test -> templates/hooks/. Scaffolded workspace:
# scripts/govern/test -> scripts/ (the hook is installed flat under scripts/).
HOOK_SRC="$DIR/../../hooks/ticket-sweep-reminder.sh"
[[ -f "$HOOK_SRC" ]] || HOOK_SRC="$DIR/../../ticket-sweep-reminder.sh"
[[ -f "$HOOK_SRC" ]] || { echo "SKIP: ticket-sweep-reminder.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/scripts/govern/lib" "$T/queue" "$T/.claude/shiploop/validation"
cp "$HOOK_SRC" "$T/scripts/ticket-sweep-reminder.sh"
cp "$DIR/../lib/common.sh" "$T/scripts/govern/lib/common.sh"
[[ -f "$DIR/../../lib/session-state.sh" ]] && cp "$DIR/../../lib/session-state.sh" "$T/scripts/lib/" 2>/dev/null

# Two tickets: one validation-shaped, one ordinary.
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #40 — VALIDATION: does cross-provider restore round-trip

**Severity:** High

Done when: a real restore is proven end to end.

---

## #41 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.
TIX
( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm init )

run_hook() { # -> stdout of the hook
  ( cd "$T" && printf '{"session_id":"s-%s","stop_hook_active":false,"cwd":"%s"}' "$1" "$T" \
      | bash "$T/scripts/ticket-sweep-reminder.sh" 2>/dev/null )
}
drop_block() { # <N>  remove a ## #N block from the WORKING TREE tickets.md
  awk -v n="$1" '
    $0 ~ "^## +#" n "([^0-9]|$)" { skip=1; next }
    skip && /^## +#/ { skip=0 }
    !skip { print }
  ' "$T/queue/tickets.md" > "$T/queue/.t" && mv "$T/queue/.t" "$T/queue/tickets.md"
}
restore_tree() { ( cd "$T" && git checkout -q -- queue/tickets.md ); rm -f "$T"/.claude/shiploop/validation/ticket-*.md; }

# ── B. merely-unrecorded open validation ticket must NOT block (the false-positive guard) ────────
outB="$(run_hook b)"
assert_not_contains "$outB" '"decision":"block"' \
  "B. an OPEN, unrecorded validation ticket does NOT block (session-blind false positive)"

# ── A. removed + unrecorded blocks, and names the ticket ─────────────────────────────────────────
drop_block 40
outA="$(run_hook a)"
assert_contains "$outA" '"decision":"block"' "A. removing a validation ticket with no record BLOCKS"
assert_contains "$outA" '#40' "A. the block names the ticket"
assert_contains "$outA" 'GOVERN_VALIDATION_GATE=0' "A. the block names its own escape hatch"

# ── D. kill switch disables it ───────────────────────────────────────────────────────────────────
outD="$( cd "$T" && printf '{"session_id":"s-d","stop_hook_active":false,"cwd":"%s"}' "$T" \
        | GOVERN_VALIDATION_GATE=0 bash "$T/scripts/ticket-sweep-reminder.sh" 2>/dev/null )"
assert_not_contains "$outD" 'VALIDATION RECORD REQUIRED' "D. GOVERN_VALIDATION_GATE=0 disables the block"

# ── C. removed but RECORDED does not block ───────────────────────────────────────────────────────
printf '# record\n' > "$T/.claude/shiploop/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md"
outC="$(run_hook c)"
assert_not_contains "$outC" 'VALIDATION RECORD REQUIRED' "C. a recorded validation does NOT block"
restore_tree

# ── E. removing a NON-validation ticket does not block ───────────────────────────────────────────
drop_block 41
outE="$(run_hook e)"
assert_not_contains "$outE" 'VALIDATION RECORD REQUIRED' "E. removing an ordinary ticket does NOT block"
restore_tree

assert_done
