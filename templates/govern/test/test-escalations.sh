#!/usr/bin/env bash
# #62 — escalation lifecycle: emit-pending (driver→relay hand-off) + apply-answers (the feedback
# loop that un-parks / migrates-to-parked / grows preferences). Pure sandbox: no auth, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
EMIT="$DIR/../escalations-emit-pending.sh"
APPLY="$DIR/../escalations-apply-answers.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"  # hermetic workspace stub (independent of the live workspace.sh)
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #5 — keep-manual one

**Severity:** Low — minor.

body of five
---
## #6 — already acceptable

**Severity:** Low — harm already zero.

body of six
---
## #7 — needs retry

**Severity:** High — bad.

body of seven
---
## #9 — untouched

**Severity:** Medium — meh.

body of nine
---
EOF

cat > "$T/tickets-parked.md" <<'EOF'
# Parked tickets — governor will NOT pick these up

---
## #1 — already parked

**Severity:** Medium.

old parked body
---
EOF

# #5 deferred, #6 mitigated, #7 do-the-work + make-a-rule, #8 unanswered (placeholder), #9 keep-open
cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

### #5 — keep manual deploy
- **Reason:** needs a live prod secret
- **Question:** automate or keep manual?
- **Options:** automate / keep-manual
- **Answer:** keep it manual, defer indefinitely
- **Disposition:** defer
- **Make this a rule?:** _(operator)_

### #6 — billing harm already zero
- **Reason:** done-condition needs prod surgery but billing harm is already nil
- **Question:** accept current state or do prod surgery?
- **Options:** accept current state / prod stamp
- **Answer:** harm is zero, accept current state as resolved
- **Disposition:** mitigated
- **Make this a rule?:** _(operator)_

### #7 — retry after infra fix
- **Reason:** infra was down
- **Question:** retry now?
- **Options:** retry / wait
- **Answer:** yes, infra is back — redo it
- **Disposition:** do-the-work
- **Make this a rule?:** When infra outages park a ticket, retry it once the provider status page is green.

### #8 — still undecided
- **Reason:** ambiguous scope
- **Question:** which approach?
- **Options:** A / B
- **Answer:** _(operator)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

### #9 — leave it for now
- **Reason:** low priority
- **Question:** do now?
- **Answer:** not sure yet, leave it
- **Disposition:** keep-open
- **Make this a rule?:** _(operator)_

## Resolved
EOF

cp "$DIR/../../../governor/preferences.md" "$T/preferences.md" 2>/dev/null || printf '# Governor preferences\n' > "$T/preferences.md"

env_common=(
  GOVERN_TICKETS_FILE="$T/tickets.md"
  GOVERN_TICKETS_PARKED_FILE="$T/tickets-parked.md"
  GOVERN_ESCALATIONS_FILE="$T/escalations.md"
  GOVERN_PREFERENCES_FILE="$T/preferences.md"
  GOVERN_PENDING_FILE="$T/pending.json"
  GOVERN_BOOKKEEP_LOCK="$T/bk.lock"
  GOVERN_NO_PUSH=1
)

# ── emit-pending: only the genuinely unanswered entry (#8) should appear ──────────────────
cnt="$(env "${env_common[@]}" bash "$EMIT" run-test 2>/dev/null)"
assert_eq "$cnt" "1" "emit-pending counts only the unanswered open entry (#8)"
tickets_in_json="$(jq -r '.escalations | map(.ticket|tostring) | join(",")' "$T/pending.json")"
assert_eq "$tickets_in_json" "8" "pending.json lists exactly #8 (answered #5/#7/#9 excluded)"
assert_contains "$(jq -r '.escalations[0].question' "$T/pending.json")" "which approach" "pending entry carries the question for AskUserQuestion"

# notification fires when pending exist
noteflag="$T/notified"
env "${env_common[@]}" GOVERN_NOTIFY_CMD="cat > $noteflag" bash "$EMIT" run-test >/dev/null 2>&1
nf=no; [ -s "$noteflag" ] && nf=yes
assert_eq "$nf" "yes" "GOVERN_NOTIFY_CMD fires when pending escalations exist"

# ── apply-answers: act on the recorded answers ───────────────────────────────────────────
out="$(env "${env_common[@]}" bash "$APPLY" 2>/dev/null)"
assert_contains "$out" "un-parked 1, deferred 1, mitigated 1, rules added 1" "apply summary: 1 un-park (#7), 1 defer (#5), 1 mitigated (#6), 1 rule (#7)"

# #7 do-the-work → escalation Resolved, ticket STILL in tickets.md (selectable again)
assert_contains "$(grep -A50 '^## Resolved' "$T/escalations.md")" "#7" "#7 escalation moved under ## Resolved"
still7="$(grep -c '^## #7' "$T/tickets.md" || true)"
assert_eq "$still7" "1" "#7 ticket REMAINS in tickets.md (un-parked → governor retries)"

# #6 mitigated → ticket REMOVED from tickets.md, NOT parked, escalation Resolved with mitigated note (#121)
gone6="$(grep -c '^## #6' "$T/tickets.md" || true)"
assert_eq "$gone6" "0" "#6 ticket REMOVED from tickets.md (mitigated → closed)"
assert_eq "$(grep -c 'body of six' "$T/tickets-parked.md" || true)" "0" "#6 NOT parked (mitigated ≠ defer — not migrated to tickets-parked.md)"
assert_contains "$(grep -A80 '^## Resolved' "$T/escalations.md")" "resolved — mitigated" "#6 escalation resolved with a mitigated note"
mit_open="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$T/escalations.md")"
assert_eq "$(printf '%s' "$mit_open" | grep -c '^### #6' || true)" "0" "#6 cleared from ## Open"

# #5 defer → ticket moved OUT of tickets.md INTO tickets-parked.md, renumbered to parked max+1 (#2)
gone5="$(grep -c '^## #5' "$T/tickets.md" || true)"
assert_eq "$gone5" "0" "#5 ticket REMOVED from tickets.md (terminal disposition)"
assert_contains "$(cat "$T/tickets-parked.md")" "## #2 — keep-manual one" "#5 migrated to tickets-parked.md renumbered to #2 (parked max+1)"
assert_contains "$(cat "$T/tickets-parked.md")" "body of five" "migrated block keeps its body"
assert_contains "$(cat "$T/tickets-parked.md")" "auto-migrated from tickets.md" "migrated block stamped with provenance"
assert_contains "$(grep -A80 '^## Resolved' "$T/escalations.md")" "moved to tickets-parked.md as #2" "#5 escalation resolved with migration note"

# #5 + #7 cleared from ## Open; #8 + #9 remain open
open_section="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$T/escalations.md")"
assert_eq "$(printf '%s' "$open_section" | grep -c '^### #5' || true)" "0" "#5 cleared from ## Open"
assert_eq "$(printf '%s' "$open_section" | grep -c '^### #7' || true)" "0" "#7 cleared from ## Open"
assert_eq "$(printf '%s' "$open_section" | grep -c '^### #8' || true)" "1" "#8 (unanswered) stays in ## Open"
assert_eq "$(printf '%s' "$open_section" | grep -c '^### #9' || true)" "1" "#9 (keep-open) stays in ## Open"

# make-rule appended to preferences.md
assert_contains "$(cat "$T/preferences.md")" "provider status page is green" "operator rule appended to preferences.md"
assert_contains "$(cat "$T/preferences.md")" "(#7," "rule line is attributed to the source ticket"

# committed
commits="$(cd "$T" && git log --oneline | grep -c 'apply escalation answers' || true)"
assert_eq "$commits" "1" "apply commits the lifecycle changes"

# #9 ticket untouched (it was never escalated to a terminal disposition)
assert_eq "$(grep -c '^## #9' "$T/tickets.md" || true)" "1" "#9 ticket untouched in tickets.md"

# ── idempotency: a second apply finds nothing actionable ─────────────────────────────────
out2="$(env "${env_common[@]}" bash "$APPLY" 2>/dev/null)"
assert_contains "$out2" "nothing to apply" "second apply is a no-op (idempotent)"

assert_done
