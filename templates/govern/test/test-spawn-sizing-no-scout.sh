#!/usr/bin/env bash
# §5.2 — the scout no longer decides the TIER, and §5.7 — escalation fires exactly once per ticket.
#
# §5.2: the scout used to fold a cached `--verdict` into resolve_sizing and claim both axes. Measured
# over every verdict this workspace ever cached, 4 of 5 were opus/high and its HARD gate was a
# disjunction in which `testsCover==false` alone forced opus — a rubber stamp, not arbitrage. Tier now
# comes from exactly TWO knobs: the cheap floor GOVERN_WORKER_MODEL and the ceiling
# GOVERN_WORKER_ESCALATION_MODEL, reachable only via the retry rail. ABSENCE OF EVIDENCE ROUTES DOWN.
#
# §5.7: escalation was purely "a preserved worktree exists" — a boolean with no memory — so every
# in-run re-dispatch rail could independently re-buy the ceiling under a single failure count. A stamp
# in the preserved worktree now makes once-ness structural rather than emergent.
#
# Uses GOVERN_SPAWN_DRY_RUN=1 (pure observation, no worktree, no worker, no auth) except where the
# stamp has to be written, which requires the live path.
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

# ── §5.7 — escalation fires exactly once ────────────────────────────────────────────────────────
# A retry (preserved worktree) escalates to the ceiling exactly once; the SECOND retry holds the floor.
mkdir -p "$TMP/wt/ticket-102"
out5="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1)"
assert_eq "$(printf '%s' "$out5" | jq -r '.model')" "opus" \
  "first retry escalates to GOVERN_WORKER_ESCALATION_MODEL [§5.7]"

# The dry-run seam is pure observation — it must NOT have burned the escalation.
[[ -f "$TMP/wt/ticket-102/.governor-escalated" ]] && st=yes || st=no
assert_eq "$st" "no" "the dry-run seam never stamps state a later real dispatch reads"

# Now simulate the stamp a live escalated dispatch leaves behind.
: > "$TMP/wt/ticket-102/.governor-escalated"
out6="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1)"
assert_eq "$(printf '%s' "$out6" | jq -r '.model')" "sonnet" \
  "a SECOND escalation is refused — the ticket's one escalation is already spent [§5.7]"
assert_eq "$(printf '%s' "$out6" | jq -r '.retry_class')" "escalation-spent" \
  "the refusal is visible in the retry class, not silent"
out7="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1 GOVERN_ESCALATE_ONCE=0)"
assert_eq "$(printf '%s' "$out7" | jq -r '.model')" "opus" \
  "GOVERN_ESCALATE_ONCE=0 restores the previous unbounded-escalation behavior"
rm -f "$TMP/wt/ticket-102/.governor-escalated"

# A conflict-resolution re-dispatch is a merge job, not a re-bet: same tier, no escalation burned.
out8="$(dry 102 GOVERN_SPAWN_FORCE_RETRY=1 GOVERN_RESOLVE_CONFLICT="alpha#7")"
assert_eq "$(printf '%s' "$out8" | jq -r '.model')" "sonnet" \
  "a GOVERN_RESOLVE_CONFLICT re-dispatch does NOT buy the ceiling tier [§5.7]"
assert_eq "$(printf '%s' "$out8" | jq -r '.retry_class')" "ci" \
  "it is classified ci (non-model cause), the same pin GOVERN_FIX_CI already had"

# ── the stamp is actually written by the LIVE path ──────────────────────────────────────────────
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

env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$TMP/logs-live" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
    GOVERN_SPAWN_FORCE_RETRY=1 \
    "$SPAWN" 102 </dev/null >/dev/null 2>&1 || true
[[ -f "$TMP/wt/ticket-102/.governor-escalated" ]] && st2=yes || st2=no
assert_eq "$st2" "yes" "a LIVE escalated dispatch stamps the preserved worktree [§5.7]"

assert_done
