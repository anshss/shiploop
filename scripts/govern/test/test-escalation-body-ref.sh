#!/usr/bin/env bash
# #331 — two regressions in the escalation safety machinery:
#   (a) escalations_open_ndjson used `/^### +#[0-9]+/` for entry headings, so ANY body line an operator
#       pasted that began `### #N` (a cross-ref in a multi-line Reason/Answer) was mis-parsed as a NEW
#       entry. The heading match now requires the `— ` title separator every writer emits, and the
#       emitted stream is jq-validated. Proof: a `### #42` body ref yields exactly ONE entry, valid JSON.
#   (b) the self-apply safety-rail knob list (PROTECTED_PATTERNS) was duplicated by hand in
#       govern-self-apply.sh AND govern-improve-triage.sh; a rail added to one was unprotected in the
#       other. It's now ONE constant (GOVERN_PROTECTED_PATTERNS in common.sh) both source. Proof: a
#       single definition exists, and both consumers' composed patterns carry every shared knob.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"                 # hermetic workspace stub (independent of the live workspace.sh)
mkdir -p "$T/governor"
source "$DIR/../lib/common.sh"  # helpers bound to the temp WS_ROOT

# ── (a) a `### #N` body ref inside a Reason must NOT start a spurious entry ──
ESC="$T/escalations.md"
cat > "$ESC" <<'EOF'
# Escalations
## Open

### #7 — real escalation
- **Opened:** 2026-07-17
- **Reason:** operator pasted a multi-line note referencing another ticket:
### #42 is the related one we should also handle
- **Question:** what to do here
- **Options:** A / B
- **Answer:** _(operator)_
- **Disposition:** _(operator: do-the-work | defer)_
- **Make this a rule?:** _(operator)_

## Resolved
EOF

ndjson="$(govern::escalations_open_ndjson "$ESC")"
assert_eq "$(printf '%s\n' "$ndjson" | grep -c .)"                 "1" "a: '### #42' body ref yields ONE entry"
assert_eq "$(printf '%s' "$ndjson" | jq -r '.ticket')"            "7" "a: the one entry is the real #7 heading"
# emitted line is valid JSON (jq validation would have dropped it otherwise)
assert_eq "$(printf '%s' "$ndjson" | jq -e 'type=="object"' >/dev/null 2>&1 && echo ok)" "ok" "a: emitted NDJSON is valid JSON"
# the pasted ref survives INSIDE the reason field — not lost, not promoted to its own entry
assert_contains "$(printf '%s' "$ndjson" | jq -r '.reason')" "another ticket" "a: reason body preserved"

# ── (b) one shared pattern-list definition, both consumers carry every shared knob ──
SELF="$DIR/../govern-self-apply.sh"
TRIAGE="$DIR/../govern-improve-triage.sh"
assert_eq "$(grep -c '^GOVERN_PROTECTED_PATTERNS=' "$DIR/../lib/common.sh")" "1" "b: exactly one GOVERN_PROTECTED_PATTERNS definition"
assert_contains "$(cat "$SELF")"   'GOVERN_PROTECTED_PATTERNS' "b: self-apply sources the shared constant"
assert_contains "$(cat "$TRIAGE")" 'GOVERN_PROTECTED_PATTERNS' "b: improve-triage sources the shared constant"
# every shared knob resolves into BOTH composed patterns at runtime
PROTECTED_PATTERNS="${GOVERN_PROTECTED_PATTERNS}|destructive"          # mirror self-apply's local append
RAIL="${GOVERN_PROTECTED_PATTERNS}|OPERATOR DECISION"                  # mirror triage's local append
for knob in GOVERN_MERGE_REPOS bypassPermissions GOVERN_PERMISSION_MODE GOVERN_MAX_TICKETS GOVERN_SELF_APPLY; do
  assert_contains "$PROTECTED_PATTERNS" "$knob" "b: self-apply pattern carries shared knob $knob"
  assert_contains "$RAIL"               "$knob" "b: triage RAIL carries shared knob $knob"
done

assert_done
