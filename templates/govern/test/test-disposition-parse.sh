#!/usr/bin/env bash
# #87 — the Disposition field must be classified by its LEADING token only. A clarifying
# parenthetical that mentions another canonical token (e.g. keep-open _(NOT do-the-work)_)
# must NOT misfire. Pure unit test over the lib helpers + one apply-answers integration case.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
mk_ws_stub "$(mktemp -d)"  # hermetic workspace stub (independent of the live workspace.sh) — seed before common.sh is sourced
# shellcheck source=/dev/null
source "$DIR/../lib/common.sh"

# ── leading-token extraction ─────────────────────────────────────────────────────────────
assert_eq "$(govern::disposition_lead_token 'keep-open _(deliberately NOT do-the-work: see thread)_')" \
  "keep-open" "leading token ignores a _(...)_ parenthetical mentioning do-the-work"
assert_eq "$(govern::disposition_lead_token 'defer (not do-the-work)')" \
  "defer" "leading token ignores a plain (...) parenthetical"
assert_eq "$(govern::disposition_lead_token 'keep-open (not defer)')" \
  "keep-open" "leading token of keep-open with a defer parenthetical is keep-open"
assert_eq "$(govern::disposition_lead_token '  do-the-work  ')" \
  "do-the-work" "leading token strips surrounding whitespace"
assert_eq "$(govern::disposition_lead_token 'defer(x)')" \
  "defer" "leading token handles a paren attached with no space"

# ── disposition classification is anchored to the leading token (#87 core) ────────────────
norm() { govern::norm_disposition "$(govern::disposition_lead_token "$1")"; }
assert_eq "$(norm 'keep-open _(deliberately NOT do-the-work: parked on purpose)_')" \
  "keep-open" "#87: keep-open w/ do-the-work parenthetical classifies as keep-open (not do-the-work)"
assert_eq "$(norm 'defer (not do-the-work)')" "defer" "defer w/ do-the-work parenthetical → defer"
assert_eq "$(norm 'keep-open (not defer)')" "keep-open" "keep-open w/ defer parenthetical → keep-open"
assert_eq "$(norm 'do-the-work')" "do-the-work" "bare do-the-work still classifies as do-the-work"
assert_eq "$(norm 'defer')" "defer" "bare defer still classifies as defer"

# #121: `mitigated` is its own canonical token, distinct from defer/do-the-work/keep-open.
assert_eq "$(norm 'mitigated')" "mitigated" "bare mitigated classifies as mitigated"
assert_eq "$(norm 'mitigated _(harm already zero — accept current state)_')" "mitigated" \
  "mitigated w/ a clarifying parenthetical classifies as mitigated"
assert_eq "$(govern::norm_disposition 'accept current state')" "mitigated" \
  "free-text 'accept current state' canonicalizes to mitigated"
assert_eq "$(govern::norm_disposition 'harm already zero')" "mitigated" \
  "free-text 'harm already zero' canonicalizes to mitigated (not defer)"

# ── externalization review-gate tokens (approve-all | decide-later | move-back) ───────────
# Added LAST in norm_disposition so a generic answer that also names a canonical token wins there;
# apply-answers additionally kind-gates them, so they can't hijack the generic lifecycle.
assert_eq "$(norm 'approve-all')" "approve-all" "approve-all classifies as approve-all"
assert_eq "$(govern::norm_disposition 'file all')" "approve-all" "free-text 'file all' → approve-all"
assert_eq "$(norm 'decide-later')" "decide-later" "decide-later classifies as decide-later"
assert_eq "$(norm 'move-back:1,5')" "move-back" "move-back:1,5 (payload) classifies as move-back (payload parsed elsewhere)"
assert_eq "$(govern::norm_disposition 'move back 3 7')" "move-back" "free-text 'move back 3 7' → move-back"
# CRITICAL regression guard: adding those tokens must NOT reclassify the generic lifecycle tokens.
assert_eq "$(norm 'do-the-work')" "do-the-work" "generic do-the-work STILL classifies as do-the-work (not hijacked)"
assert_eq "$(norm 'defer')" "defer" "generic defer STILL classifies as defer"
assert_eq "$(norm 'mitigated')" "mitigated" "generic mitigated STILL classifies as mitigated"
assert_eq "$(norm 'keep-open')" "keep-open" "generic keep-open STILL classifies as keep-open"
# A do-the-work answer that also contains 'approve' in prose is NOT hijacked to approve-all.
assert_eq "$(govern::norm_disposition 'do the work, i approve')" "do-the-work" \
  "an answer naming both 'do the work' and 'approve' resolves to do-the-work (generic wins)"

# the unfilled Disposition placeholder is still recognized as not-yet-answered
ph='_(operator: do-the-work | defer | mitigated | keep-open)_'
govern::is_placeholder "$ph" && phflag=yes || phflag=no
assert_eq "$phflag" "yes" "the Disposition placeholder is treated as unanswered (not parsed as a token)"

# ── integration: apply-answers respects the leading token (#81 reproduction) ──────────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #81 — parked on purpose

**Severity:** Low.

body of eighty-one
---
EOF
printf '# Parked tickets\n\n---\n' > "$T/tickets-parked.md"

# #81 Disposition is keep-open but its parenthetical names do-the-work — the #81 bug.
cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

### #81 — keep this parked
- **Reason:** deliberately parked
- **Question:** un-park?
- **Options:** keep-open / do-the-work
- **Answer:** leave it parked for now
- **Disposition:** keep-open _(deliberately NOT do-the-work: parked on purpose)_
- **Make this a rule?:** _(operator)_

## Resolved
EOF
printf '# Governor preferences\n' > "$T/preferences.md"

out="$(env \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_TICKETS_PARKED_FILE="$T/tickets-parked.md" \
  GOVERN_ESCALATIONS_FILE="$T/escalations.md" \
  GOVERN_PREFERENCES_FILE="$T/preferences.md" \
  GOVERN_PENDING_FILE="$T/pending.json" \
  GOVERN_BOOKKEEP_LOCK="$T/bk.lock" \
  GOVERN_NO_PUSH=1 \
  bash "$DIR/../escalations-apply-answers.sh" 2>/dev/null)"

# keep-open ⇒ nothing actionable: #81 stays Open, ticket stays put, NOT un-parked.
assert_contains "$out" "nothing to apply" "#81 keep-open (w/ do-the-work parenthetical) is NOT acted on"
open_section="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$T/escalations.md")"
assert_eq "$(printf '%s' "$open_section" | grep -c '^### #81' || true)" "1" "#81 escalation stays under ## Open"
assert_eq "$(grep -c '^## #81' "$T/tickets.md" || true)" "1" "#81 ticket stays in tickets.md (not migrated)"
resolved_section="$(awk '/^## Resolved/{f=1} f' "$T/escalations.md")"
assert_eq "$(printf '%s' "$resolved_section" | grep -c '^### #81' || true)" "0" "#81 is NOT moved to ## Resolved"

assert_done
