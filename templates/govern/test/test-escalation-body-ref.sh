#!/usr/bin/env bash
# #331 regression in the escalation safety machinery:
#   escalations_open_ndjson used `/^### +#[0-9]+/` for entry headings, so ANY body line an operator
#       pasted that began `### #N` (a cross-ref in a multi-line Reason/Answer) was mis-parsed as a NEW
#       entry. The heading match now requires the `— ` title separator every writer emits, and the
#       emitted stream is jq-validated. Proof: a `### #42` body ref yields exactly ONE entry, valid JSON.
# Part (b) of the original regression covered the self-apply safety-rail knob list shared by
# govern-self-apply.sh and govern-improve-triage.sh. Both scripts, and the shared constant, were
# deleted with the self-improvement lane in 1.19.2, so there is nothing left to protect and the
# assertions went with them.
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

assert_done
