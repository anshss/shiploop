#!/usr/bin/env bash
# §5.2: the scout no longer decides the TIER, and the retry rail no longer decides it either.
#
# §5.2: the scout used to fold a cached `--verdict` into resolve_sizing and claim both axes. Measured
# over every verdict this workspace ever cached, 4 of 5 were opus/high and its HARD gate was a
# disjunction in which `testsCover==false` alone forced opus — a rubber stamp, not arbitrage. Tier now
# comes from ONE knob, the cheap floor GOVERN_WORKER_MODEL. ABSENCE OF EVIDENCE ROUTES DOWN.
#
# The §5.7 half of this file used to lock in "escalation fires exactly once per ticket", enforced by a
# `.governor-escalated` stamp in the preserved worktree. AUTOMATIC ESCALATION IS REMOVED, so there is
# no spend left to bound: the stamp, GOVERN_ESCALATE_ONCE and the escalation-spent class are all gone
# with it, and those cases are replaced below by their successors: a retry HOLDS the floor, and a
# capability-classed failure surfaces a re-specification request to the operator instead.
#
# Uses GOVERN_SPAWN_DRY_RUN=1 (pure observation, no worktree, no worker, no auth) except where the
# escalation entry has to be written, which requires the live path.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #101 — a ticket the scout would once have sized opus
**Severity:** Medium
Observed: no test covers this area, which was the single condition that used to force opus.
Done when: PR opens.

---

## #102 — plain ticket
**Severity:** Medium
Observed: bare ticket.
Done when: PR opens.
EOF
printf 'DOC\n' > "$TMP/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# A scout cache that, under the OLD scorer, measured a ticket no test covers — the exact shape that
# used to trip the hard gate straight to opus/high. It must now change nothing.
mkdir -p "$TMP/logs/ticket-101"
cat > "$TMP/logs/ticket-101/scout.json" <<'EOF'
{"ticket":101,"scope":{"files":9,"repos":2,"testsCover":false,"precedent":false,"changeKind":"cross-cutting","fixDirection":"vague"},"verdict":{"model":"opus","effort":"high","scopeClass":"hard"},"scoutModel":"haiku","ts":1}
EOF

dry() { # <ticket> [extra env...]
  local n="$1"; shift
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs" \
      GOVERN_SPAWN_DRY_RUN=1 \
      "$@" \
      "$SPAWN" "$n"
}

# ── §5.2 ────────────────────────────────────────────────────────────────────────────────────────
# 1. Even with GOVERN_SCOUT=1 and a cached opus/high verdict sitting right there, the tier is the floor.
out1="$(dry 101 GOVERN_SCOUT=1)"
assert_eq "$(printf '%s' "$out1" | jq -r '.model')" "sonnet" \
  "a cached opus verdict no longer raises the tier — the floor GOVERN_WORKER_MODEL decides [§5.2]"
assert_eq "$(printf '%s' "$out1" | jq -r '.model_source')" "GOVERN_WORKER_MODEL" \
  "the sizing decision attributes itself to the floor knob, never to the scout"
assert_not_contains "$out1" "scout" "no dispatch field is sourced from the scout any more"

# 2. Absence of evidence routes DOWN, not up: a ticket with NO scout cache at all is identical.
out2="$(dry 102 GOVERN_SCOUT=1)"
assert_eq "$(printf '%s' "$out2" | jq -r '.model')" "sonnet" \
  "no scout cache → the floor, not the ceiling (absence of evidence routes DOWN) [§5.2]"
assert_eq "$(printf '%s' "$out1" | jq -r '.model')" "$(printf '%s' "$out2" | jq -r '.model')" \
  "a ticket WITH a cached verdict and one WITHOUT now size identically"

# 3. The floor is the only first-attempt knob, and it is honoured.
out3="$(dry 101 GOVERN_SCOUT=1 GOVERN_WORKER_MODEL=haiku)"
assert_eq "$(printf '%s' "$out3" | jq -r '.model')" "haiku" \
  "GOVERN_WORKER_MODEL is the single first-attempt tier knob"

# 4. The retired verdict field is gone from the dry-run observation seam entirely.
assert_eq "$(printf '%s' "$out1" | jq -r 'has("scope_class")')" "false" \
  "scope_class is removed — nothing consumed it but the retired verdict path"

# ── the retry rail HOLDS the tier (automatic escalation removed) ────────────────────────────────
mkdir -p "$TMP/wt/ticket-102"
out5="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1)"
assert_eq "$(printf '%s' "$out5" | jq -r '.model')" "sonnet" \
  "a retry holds the floor tier: no failure class buys GOVERN_WORKER_ESCALATION_MODEL"
assert_eq "$(printf '%s' "$out5" | jq -r '.respec_requested')" "true" \
  "an unrecognized failure signature surfaces a re-specification request instead of spending"

# The stamp that used to bound escalation is gone, and nothing recreates it.
[[ -f "$TMP/wt/ticket-102/.governor-escalated" ]] && st=yes || st=no
assert_eq "$st" "no" "no .governor-escalated stamp is written any more; the mechanism it bounded is gone"
assert_not_contains "$(cat "$SPAWN")" "GOVERN_ESCALATE_ONCE:-1" \
  "GOVERN_ESCALATE_ONCE is removed, not left reading state nothing writes"

# A conflict-resolution re-dispatch is a merge job, not a re-bet: same tier, and NOT a capability
# failure, so it must not file a re-specification request against an already-solved ticket.
out8="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1 GOVERN_RESOLVE_CONFLICT="alpha#7")"
assert_eq "$(printf '%s' "$out8" | jq -r '.model')" "sonnet" \
  "a GOVERN_RESOLVE_CONFLICT re-dispatch keeps the floor tier [§5.7]"
assert_eq "$(printf '%s' "$out8" | jq -r '.retry_class')" "ci" \
  "it is classified ci (non-model cause), the same pin GOVERN_FIX_CI already had"
assert_eq "$(printf '%s' "$out8" | jq -r '.respec_requested')" "false" \
  "and it does NOT ask the operator to re-specify a ticket that was already solved"

# ── the re-specification request is filed by the LIVE path ──────────────────────────────────────
cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"
cat > "$TMP/fake-claude.sh" <<'EOF'
#!/usr/bin/env bash
report='{"status":"failed","pr":null,"lessonPatch":null,"newTickets":[],"crossRefs":{},"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

live() { # [extra env...] -> runs the LIVE spawn path for #102 against a fresh escalations file
  printf '# Escalations\n\n## Open\n' > "$TMP/governor/escalations.md"
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_ESCALATIONS_FILE="$TMP/governor/escalations.md" \
      GOVERN_LOG_ROOT="$TMP/logs-live" \
      GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
      GOVERN_SPAWN_FORCE_RETRY=1 \
      "$@" "$SPAWN" 102 </dev/null >/dev/null 2>&1 || true
}

live
assert_contains "$(cat "$TMP/governor/escalations.md")" "re-specification needed: the last attempt failed on capability" \
  "a LIVE capability-classed retry files a re-specification request under ## Open"
assert_contains "$(cat "$TMP/governor/escalations.md")" "**Kind:** respec" \
  "the entry is tagged Kind: respec so the lane is identifiable"
assert_contains "$(cat "$TMP/governor/escalations.md")" "Automatic tier escalation is removed" \
  "the entry states WHY it is a re-specification request rather than an escalation"

# Dedupe: a ticket that keeps failing files ONE request, not one per attempt.
before="$(grep -c '^### #102' "$TMP/governor/escalations.md")"
env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_ESCALATIONS_FILE="$TMP/governor/escalations.md" \
    GOVERN_LOG_ROOT="$TMP/logs-live" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
    GOVERN_SPAWN_FORCE_RETRY=1 \
    "$SPAWN" 102 </dev/null >/dev/null 2>&1 || true
assert_eq "$(grep -c '^### #102' "$TMP/governor/escalations.md")" "$before" \
  "a second failing attempt does NOT file a duplicate; an open entry already asks the question"

# Kill switch: the filing can be turned off without resurrecting the tier purchase.
live GOVERN_RESPEC_ON_CAPABILITY_FAIL=0
assert_not_contains "$(cat "$TMP/governor/escalations.md")" "### #102" \
  "GOVERN_RESPEC_ON_CAPABILITY_FAIL=0 suppresses the filing"

# The dry-run seam is pure observation: it must never write the entry the live path writes.
printf '# Escalations\n\n## Open\n' > "$TMP/governor/escalations.md"
GOVERN_ESCALATIONS_FILE="$TMP/governor/escalations.md" dry 102 GOVERN_SPAWN_FORCE_RETRY=1 >/dev/null
assert_not_contains "$(cat "$TMP/governor/escalations.md")" "### #102" \
  "the dry-run seam never files an escalation; it only observes"

assert_done
