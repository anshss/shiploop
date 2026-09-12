#!/usr/bin/env bash
# A PR-shaped escalation (the auto-merge guard refused a PR, waiting for a human to
# merge it by hand) must reconcile against the PR's ACTUAL state, even with no operator answer —
# a 2026-09-08 entry for shiploop#159 was still printing three days after that PR merged.
#
#   A. unanswered, references a MERGED PR                -> auto-resolved, cleared from pending.json
#   B. unanswered, references a CLOSED PR                 -> auto-resolved, same as A
#   C. unanswered, references a still-OPEN PR             -> untouched, still prints
#   D. unanswered, references NO PR at all                -> untouched (unrelated to this mechanism)
#   E. gh is UNAVAILABLE (query fails)                    -> FAIL-CLOSED: untouched, still prints —
#      a stale banner is a smaller harm than a silently swallowed escalation
#   F. ALREADY answered (do-the-work) + happens to reference a merged PR -> the operator's own
#      answer drives it (existing disposition path), not the reconcile pass
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
EMIT="$DIR/../escalations-emit-pending.sh"
APPLY="$DIR/../escalations-apply-answers.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #50 — A: merged PR

body of fifty
---
## #51 — B: closed PR

body of fifty-one
---
## #52 — C: still-open PR

body of fifty-two
---
## #53 — D: no PR referenced

body of fifty-three
---
## #54 — F: answered AND references a merged PR

body of fifty-four
---
EOF
printf '# Parked tickets\n' > "$T/tickets-parked.md"

cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

### #50 — PR alpha#159 was NOT auto-merged: the three-factor safety guard refused it
- **Opened:** 2026-09-08
- **Reason:** PR alpha#159 was NOT auto-merged: the three-factor safety guard (own gh author + governor branch pattern + non-fork) refused it.
- **Question:** review alpha#159 as a human and merge it via gh/web if trusted, or close it
- **Options:**
- **Answer:** _(operator)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

### #51 — PR alpha#160 was NOT auto-merged
- **Opened:** 2026-09-08
- **Reason:** PR alpha#160 was NOT auto-merged: same guard refusal.
- **Question:** review alpha#160 as a human
- **Options:**
- **Answer:** _(operator)_
- **Disposition:** _(operator)_
- **Make this a rule?:** _(operator)_

### #52 — PR alpha#161 was NOT auto-merged
- **Opened:** 2026-09-08
- **Reason:** PR alpha#161 was NOT auto-merged: same guard refusal.
- **Question:** review alpha#161 as a human
- **Options:**
- **Answer:** _(operator)_
- **Disposition:** _(operator)_
- **Make this a rule?:** _(operator)_

### #53 — unrelated ambiguous scope
- **Opened:** 2026-09-08
- **Reason:** ambiguous scope, no PR involved
- **Question:** which approach?
- **Options:**
- **Answer:** _(operator)_
- **Disposition:** _(operator)_
- **Make this a rule?:** _(operator)_

### #54 — PR alpha#162 was NOT auto-merged
- **Opened:** 2026-09-08
- **Reason:** PR alpha#162 was NOT auto-merged: same guard refusal.
- **Question:** review alpha#162 as a human
- **Options:**
- **Answer:** do the work
- **Disposition:** do-the-work
- **Make this a rule?:** _(operator)_

## Resolved
EOF

printf '# Governor preferences\n' > "$T/preferences.md"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh called: $*" >> "$GH_CALLS_LOG"
case "$*" in
  *"pr view 159"*) [[ "${GH_UNAVAILABLE:-0}" == "1" ]] && exit 1; echo MERGED ;;
  *"pr view 160"*) echo CLOSED ;;
  *"pr view 161"*) echo OPEN ;;
  *"pr view 162"*) echo MERGED ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export GH_CALLS_LOG="$T/gh-calls.log"

env_common=(
  GOVERN_TICKETS_FILE="$T/tickets.md"
  GOVERN_TICKETS_PARKED_FILE="$T/tickets-parked.md"
  GOVERN_ESCALATIONS_FILE="$T/escalations.md"
  GOVERN_PREFERENCES_FILE="$T/preferences.md"
  GOVERN_PENDING_FILE="$T/pending.json"
  GOVERN_BOOKKEEP_LOCK="$T/bk.lock"
  GOVERN_NO_PUSH=1
)

out="$(env "${env_common[@]}" bash "$APPLY" 2>/dev/null)"
assert_contains "$out" "reconciled 2" "reconcile count is 2 (A merged, B closed — F is answered, handled separately)"

resolved="$(awk '/^## Resolved/{f=1;next} f' "$T/escalations.md")"
open="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$T/escalations.md")"

# ── A. merged PR -> auto-resolved ────────────────────────────────────────────────────────────
assert_contains "$resolved" "#50" "A: #50 (merged PR) moved to ## Resolved"
assert_not_contains "$open" "### #50" "A: #50 cleared from ## Open"
assert_contains "$resolved" "auto-resolved" "A: resolution note says auto-resolved"

# ── B. closed PR -> auto-resolved ────────────────────────────────────────────────────────────
assert_contains "$resolved" "#51" "B: #51 (closed PR) moved to ## Resolved"
assert_not_contains "$open" "### #51" "B: #51 cleared from ## Open"

# ── C. still-open PR -> untouched ────────────────────────────────────────────────────────────
assert_contains "$open" "### #52" "C: #52 (PR still open) stays in ## Open"
assert_not_contains "$resolved" "#52" "C: #52 never moved to ## Resolved"

# ── D. no PR reference -> untouched by THIS mechanism ────────────────────────────────────────
assert_contains "$open" "### #53" "D: #53 (no PR referenced) stays in ## Open"

# ── F. already-answered do-the-work, also references a merged PR -> the ANSWER drives it ────
assert_contains "$resolved" "#54" "F: #54 resolved via its own do-the-work answer"
assert_contains "$resolved" "un-parked" "F: #54's resolution note is the do-the-work un-park note, not auto-resolved"
still54="$(grep -c '^## #54' "$T/tickets.md" || true)"
assert_eq "$still54" "1" "F: #54 ticket REMAINS in tickets.md (do-the-work → retry), unaffected by reconcile"

# ── pending.json reflects reality: only #52 and #53 remain ───────────────────────────────────
env "${env_common[@]}" bash "$EMIT" run-test >/dev/null 2>&1
pending_tickets="$(jq -r '.escalations | map(.ticket) | sort | join(",")' "$T/pending.json")"
assert_eq "$pending_tickets" "52,53" "pending.json lists only the genuinely-still-open #52/#53"

# ── E. gh unavailable for #50-shaped entry -> FAIL-CLOSED, stays open, no live call assumed ──
: > "$T/escalations.md"
cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

### #60 — PR alpha#159 was NOT auto-merged
- **Opened:** 2026-09-08
- **Reason:** PR alpha#159 was NOT auto-merged: same guard refusal.
- **Question:** review alpha#159 as a human
- **Options:**
- **Answer:** _(operator)_
- **Disposition:** _(operator)_
- **Make this a rule?:** _(operator)_

## Resolved
EOF
cat >> "$T/tickets.md" <<'EOF'
## #60 — E: gh unavailable

body of sixty
---
EOF
out2="$(env "${env_common[@]}" GH_UNAVAILABLE=1 bash "$APPLY" 2>/dev/null)"
# Nothing else is answered either, so a gh failure here means the reconcile pass acted on
# NOTHING and the script takes the existing early-exit no-op path — never a false "reconciled".
assert_contains "$out2" "nothing to apply" "E: gh failure reconciles nothing (early-exit no-op, not a false reconcile)"
open2="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$T/escalations.md")"
assert_contains "$open2" "### #60" "E: gh-unavailable entry is left EXACTLY as-is, still open (fail-closed)"

assert_done
