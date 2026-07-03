#!/usr/bin/env bash
# Regression for ticket #274: the CLASSIFIED promotion bridge (govern-improve-triage.sh).
#   A. A block with mixed proposals → the SAFE/additive ones are auto-filed as ONE ticket via
#      file-ticket.sh; the rail-touching / OPERATOR-DECISION ones are DEMONSTRABLY EXCLUDED (never
#      appear in the filed ticket) and the block is annotated AUTO-PROMOTED.
#   B. A rail-touching proposal is NOT auto-queued — an all-rail block files NO ticket and is
#      annotated AUTO-TRIAGE "no safe proposals" (the #274 "Done when" test).
#   C. Idempotent — re-running triage on an already-annotated block files nothing more.
#   D. run-id scoping — passing an OLDER block's run-id triages only that block, not the newest.
# Fully isolated: temp tickets.md / improvements.md, GOVERN_NO_PUSH, non-repo temp dir (file-ticket
# appends to disk + echoes the number; the annotation-commit is skipped for a non-default file).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
TRIAGE="$DIR/../govern-improve-triage.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# Hermetic workspace stub (seeds scripts/lib/workspace.sh so common.sh sources cleanly with NO real
# workspace present — the template convention); it exports GOVERN_WS_ROOT="$ROOT/ws".
mk_ws_stub "$ROOT/ws"; mkdir -p "$GOVERN_WS_ROOT/governor"
export GOVERN_NO_PUSH=1

# Assertion: needle must NOT be present in haystack.
assert_absent() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] WAS present but must be excluded\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# ── A + B. Mixed block: 2 safe promoted, 2 rail held ──
export GOVERN_TICKETS_FILE="$ROOT/tickets-A.md"; printf '# tickets\n' > "$GOVERN_TICKETS_FILE"
export GOVERN_TICKET_SEQ_FILE="$ROOT/seq-A"; printf '40\n' > "$GOVERN_TICKET_SEQ_FILE"
export GOVERN_IMPROVEMENTS_FILE="$ROOT/improvements-A.md"
cat > "$GOVERN_IMPROVEMENTS_FILE" <<'EOF'
# Governor self-improvement proposals

intro text here.

---

## 2026-07-02 13:00 — run run-AAA (resolved/parked/failed observed)

Some prose preamble.

- scripts/govern/run-loop.sh: emit a SENTINEL_SAFE_A consolidated summary block — pure aggregation, ergonomics.
- scripts/govern/spawn-worker.sh: SENTINEL_SAFE_B inject the timeout ceiling into the prompt — observability.
- scripts/govern/run-loop.sh: raise GOVERN_MAX_TICKETS to 30 SENTINEL_RAIL_A — throughput but changes a run bound.
- OPERATOR DECISION — auto-merge stale harness-owned PRs SENTINEL_RAIL_B: closes a known class, trade-off noted.
EOF

bash "$TRIAGE" run-AAA >/dev/null 2>&1 || true
tickets_A="$(cat "$GOVERN_TICKETS_FILE")"
impr_A="$(cat "$GOVERN_IMPROVEMENTS_FILE")"

assert_contains "$tickets_A" "Harness self-improvement" "A: a self-improvement ticket was filed"
assert_contains "$tickets_A" "SENTINEL_SAFE_A" "A: safe proposal #1 landed in the ticket"
assert_contains "$tickets_A" "SENTINEL_SAFE_B" "A: safe proposal #2 landed in the ticket"
assert_absent   "$tickets_A" "SENTINEL_RAIL_A" "B: GOVERN_MAX_TICKETS proposal NOT auto-queued (excluded)"
assert_absent   "$tickets_A" "SENTINEL_RAIL_B" "B: OPERATOR-DECISION/auto-merge proposal NOT auto-queued (excluded)"
assert_contains "$impr_A" "AUTO-PROMOTED" "A: block annotated AUTO-PROMOTED"
assert_contains "$impr_A" "2 safe proposal(s)" "A: annotation counts 2 safe promoted"
assert_contains "$impr_A" "2 rail-touching" "A: annotation counts 2 rail held"
# The rail bullets must remain in improvements.md (behind the human gate), not deleted.
assert_contains "$impr_A" "SENTINEL_RAIL_A" "B: rail proposal stays recorded in improvements.md"
assert_contains "$impr_A" "SENTINEL_RAIL_B" "B: OPERATOR-DECISION proposal stays recorded in improvements.md"

# ── C. Idempotency — re-run must file nothing more, annotate nothing more ──
before_c="$(grep -c 'Harness self-improvement' "$GOVERN_TICKETS_FILE")"
bash "$TRIAGE" run-AAA >/dev/null 2>&1 || true
after_c="$(grep -c 'Harness self-improvement' "$GOVERN_TICKETS_FILE")"
assert_eq "$after_c" "$before_c" "C: re-triage of an annotated block files no second ticket"
assert_eq "$(grep -c 'AUTO-PROMOTED' "$GOVERN_IMPROVEMENTS_FILE")" "1" "C: no duplicate annotation"

# ── B'. All-rail block: NO ticket filed, annotated AUTO-TRIAGE (the core #274 exclusion proof) ──
export GOVERN_TICKETS_FILE="$ROOT/tickets-B.md"; printf '# tickets\n' > "$GOVERN_TICKETS_FILE"
export GOVERN_TICKET_SEQ_FILE="$ROOT/seq-B"; printf '50\n' > "$GOVERN_TICKET_SEQ_FILE"
export GOVERN_IMPROVEMENTS_FILE="$ROOT/improvements-B.md"
cat > "$GOVERN_IMPROVEMENTS_FILE" <<'EOF'
# Governor self-improvement proposals

---

## 2026-07-02 14:00 — run run-BBB (resolved/parked/failed observed)

- scripts/govern/run-loop.sh: change the merge allowlist to add a repo SENTINEL_ONLY_RAIL — needs operator sign-off.
- OPERATOR DECISION — switch permission mode to bypassPermissions for frontend — trade-off.
EOF
bash "$TRIAGE" run-BBB >/dev/null 2>&1 || true
assert_eq "$(grep -c 'Harness self-improvement' "$GOVERN_TICKETS_FILE")" "0" "B': all-rail block files NO ticket"
assert_contains "$(cat "$GOVERN_IMPROVEMENTS_FILE")" "AUTO-TRIAGE" "B': all-rail block annotated AUTO-TRIAGE"
assert_contains "$(cat "$GOVERN_IMPROVEMENTS_FILE")" "no safe/additive proposals" "B': annotation states nothing safe to promote"

# ── D. run-id scoping: two blocks, triage only the OLDER one when its run-id is passed ──
export GOVERN_TICKETS_FILE="$ROOT/tickets-D.md"; printf '# tickets\n' > "$GOVERN_TICKETS_FILE"
export GOVERN_TICKET_SEQ_FILE="$ROOT/seq-D"; printf '60\n' > "$GOVERN_TICKET_SEQ_FILE"
export GOVERN_IMPROVEMENTS_FILE="$ROOT/improvements-D.md"
cat > "$GOVERN_IMPROVEMENTS_FILE" <<'EOF'
# Governor self-improvement proposals

---

## 2026-07-02 15:00 — run run-OLD (resolved/parked/failed observed)

- scripts/govern/await-ci.sh: SENTINEL_OLD_SAFE add a poll-timeout log — ergonomics.

## 2026-07-02 16:00 — run run-NEW (resolved/parked/failed observed)

- scripts/govern/merge-pr.sh: SENTINEL_NEW_SAFE dedup branch cleanup — ergonomics.
EOF
bash "$TRIAGE" run-OLD >/dev/null 2>&1 || true
tickets_D="$(cat "$GOVERN_TICKETS_FILE")"; impr_D="$(cat "$GOVERN_IMPROVEMENTS_FILE")"
assert_contains "$tickets_D" "SENTINEL_OLD_SAFE" "D: the targeted (older) run's safe proposal was promoted"
assert_absent   "$tickets_D" "SENTINEL_NEW_SAFE" "D: the newer block was NOT touched (run-id scoping)"
# Only the OLD block header should carry the annotation.
assert_contains "$impr_D" "run-OLD (resolved/parked/failed observed)"$'\n'"" "D: old header intact"
old_annotated="$(awk '/run-OLD/{f=1} /run-NEW/{f=0} f' <<<"$impr_D" | grep -c 'AUTO-PROMOTED' || true)"
new_annotated="$(awk '/run-NEW/{f=1} f' <<<"$impr_D" | grep -c 'AUTO-PROMOTED' || true)"
assert_eq "$old_annotated" "1" "D: OLD block annotated"
assert_eq "$new_annotated" "0" "D: NEW block left un-annotated"

assert_done
