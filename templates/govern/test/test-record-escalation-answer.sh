#!/usr/bin/env bash
# #N15 — record-escalation-answer.sh: the Bash-only (no Edit-tool) escalation round-trip. Pure
# sandbox: no auth, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RECORD="$DIR/../record-escalation-answer.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

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
- **Answer:** _(operator)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

## Resolved

### #5 — already closed
- **Reason:** old
- **Question:** n/a
- **Answer:** already answered
- **Disposition:** defer
- **Make this a rule?:** _(operator)_
EOF
( cd "$T" && git add escalations.md && git commit -q -m seed )

env_common=( GOVERN_ESCALATIONS_FILE="$T/escalations.md" GOVERN_NO_PUSH=1 )

# ── happy path: record an answer + disposition on an open entry ──────────────────────────
out="$(env "${env_common[@]}" bash "$RECORD" 8 --answer "yes, approach A" --disposition do-the-work)"
assert_contains "$out" "recorded #8: disposition=do-the-work" "records the disposition and reports it"
blk8="$(awk '/^### #8/{f=1} f{print} /^### #9/{exit}' "$T/escalations.md")"
assert_contains "$blk8" "Answer:** yes, approach A" "Answer field rewritten for #8"
assert_contains "$blk8" "Disposition:** do-the-work" "Disposition field rewritten for #8"

# ── --rule additionally rewrites the Make-this-a-rule field ──────────────────────────────
env "${env_common[@]}" bash "$RECORD" 9 --answer "not now" --disposition keep-open --rule "always wait a week" >/dev/null
blk9="$(awk '/^### #9/{f=1} f{print} /^## Resolved/{exit}' "$T/escalations.md")"
assert_contains "$blk9" "Answer:** not now" "Answer field rewritten for #9"
assert_contains "$blk9" "Disposition:** keep-open" "Disposition field rewritten for #9"
assert_contains "$blk9" "Make this a rule?:** always wait a week" "rule field rewritten for #9"

# #8 untouched by the #9 edit (each invocation only touches its own block)
blk8_after="$(awk '/^### #8/{f=1} f{print} /^### #9/{exit}' "$T/escalations.md")"
assert_contains "$blk8_after" "Answer:** yes, approach A" "#8 unaffected by the later #9 edit"

# ── idempotent re-run: correct a typo before the next governor run applies it ────────────
env "${env_common[@]}" bash "$RECORD" 8 --answer "actually, approach B" --disposition do-the-work >/dev/null
blk8_fixed="$(awk '/^### #8/{f=1} f{print} /^### #9/{exit}' "$T/escalations.md")"
assert_contains "$blk8_fixed" "Answer:** actually, approach B" "re-run overwrites a corrected answer (idempotent)"

# ── guardrails ────────────────────────────────────────────────────────────────────────────
rc=0; env "${env_common[@]}" bash "$RECORD" 5 --answer "reopen it" --disposition defer >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "refuses a ticket already under ## Resolved"

rc=0; env "${env_common[@]}" bash "$RECORD" 42 --answer "x" --disposition defer >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "refuses a ticket number with no entry at all"

rc=0; env "${env_common[@]}" bash "$RECORD" 8 --answer "x" --disposition not-a-real-token >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "refuses an unrecognized --disposition token"

rc=0; env "${env_common[@]}" bash "$RECORD" 8 --disposition do-the-work >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "refuses a missing --answer"

# ── commits the result (same CAS-safe path every escalations.md writer uses) ─────────────
commits="$(cd "$T" && git log --oneline | grep -c 'record answer for' || true)"
assert_eq "$commits" "3" "each successful invocation commits (2 first-time + 1 correction re-run)"

assert_done
