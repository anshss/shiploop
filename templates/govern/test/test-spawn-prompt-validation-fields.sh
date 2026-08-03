#!/usr/bin/env bash
# Locks in the SECOND `<!-- GOVERN:SECTION validation -->` fence around the Output-contract
# `validation` field rule (worker-prompt.md, incl. the Flow subfields gatePassed/measured/
# validatedShas/environment/flowIds).
#
# Why it exists (#83 Part 2, span A): that field rule sat AFTER the first
# `<!-- GOVERN:END validation -->` (the "RUN THE REAL TEST" doctrine block), so it was unfenced and
# always-on — sent to every worker even though only a validation/spike ticket can ever populate
# those fields. `prompt_apply_sections()` (spawn-worker.sh) keeps/drops a fenced block by NAME,
# per-occurrence, so a second block sharing the `validation` name is governed by the exact same
# `govern::is_validation_ticket` classifier as the first block with zero `spawn-worker.sh` changes.
#
# This test runs against the REAL `templates/governor/worker-prompt.md` (not a miniature stub) —
# span A is a real, named field list, and a stub could pass this test with a fence around fake
# sentinel text while the real file's fence was still off by a line.
#
# Cases:
#   1. Ordinary ticket → none of the Flow subfield names appear; the base "RUN THE REAL TEST"
#      block is ALSO absent (both `validation`-named blocks travel together).
#   2. Validation ticket → both blocks present: the Flow subfield names AND the RUN THE REAL TEST
#      doctrine.
#   3. Kill switch (GOVERN_PROMPT_SEGMENTED=0) → both blocks present even for an ordinary ticket.
#   4. The ordinary-ticket prompt is measurably smaller than before this fence existed — i.e. the
#      Flow-subfield span is not part of the always-on baseline any more.
#   5. The validation-ticket prompt is unaffected: segmented vs monolith render byte-identical.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
WORKER_PROMPT="$GOVERN_PROMPTS_DIR/worker-prompt.md"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor"

cat > "$TMP/tickets.md" <<'EOF'
## #501 — an ordinary ticket
**Severity:** Medium
Observed: a plain code-change ticket, no validation tells.
Done when: PR opens.

---

## #502 — VALIDATION: does the reaper actually sweep orphans
**Severity:** High
Done when: a PASS/FAIL table from an actual run.

---
EOF
printf 'DOCTRINE-SENTINEL\n' > "$TMP/governor/preferences.md"

render() { # <env assignments...> -- <ticket>
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift   # drop the --
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$WORKER_PROMPT" \
      GOVERN_LOG_ROOT="$TMP/logs" \
      GOVERN_WORKER_MODEL="sonnet" \
      GOVERN_SPAWN_PRINT_PROMPT=1 \
      ${envs[@]+"${envs[@]}"} "$SPAWN" "$@"
}

has() { printf '%s' "$1" | grep -qF -- "$2"; }
assert_has() {
  if has "$1" "$2"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       missing: %s\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_lacks() {
  if has "$1" "$2"; then printf 'FAIL - %s\n       unexpectedly present: %s\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

FLOW_FIELDS=("gatePassed" "validatedShas" "flowIds")

# 1. Ordinary ticket → neither validation-named block reaches the worker.
ord="$(render -- 501)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_lacks "$ord" "\`$f\`" "ordinary ticket → Flow subfield '$f' is NOT in the assembled prompt"
done
assert_lacks "$ord" "RUN THE REAL TEST" \
  "ordinary ticket → the base validation doctrine block is also absent (both blocks fenced by the same name)"

# 2. Validation ticket → both validation-named blocks are present.
val="$(render -- 502)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_has "$val" "\`$f\`" "validation ticket → Flow subfield '$f' IS present"
done
assert_has "$val" "RUN THE REAL TEST" \
  "validation ticket → the base validation doctrine block is also present"

# 3. Kill switch → both blocks present even for an ordinary ticket.
mono="$(render GOVERN_PROMPT_SEGMENTED=0 -- 501)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_has "$mono" "\`$f\`" "GOVERN_PROMPT_SEGMENTED=0 → Flow subfield '$f' present regardless of ticket class"
done
assert_has "$mono" "RUN THE REAL TEST" \
  "GOVERN_PROMPT_SEGMENTED=0 → base validation doctrine block present regardless of ticket class"

# 4. The ordinary-ticket prompt is smaller with the fence than the monolith (real saving, not
# just a shuffled always-on section).
ord_n=$(printf '%s' "$ord" | wc -c | tr -d ' ')
mono_n=$(printf '%s' "$mono" | wc -c | tr -d ' ')
if [ "$ord_n" -lt "$mono_n" ]; then
  printf 'ok   - %s (%s < %s bytes)\n' \
    "fencing span A shrinks an ordinary ticket's prompt vs the monolith" "$ord_n" "$mono_n"
else
  printf 'FAIL - %s (%s vs %s bytes)\n' \
    "fencing span A must shrink an ordinary ticket's prompt" "$ord_n" "$mono_n"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 5. A validation ticket pays nothing for the fence existing: same ticket, both modes, same bytes.
val_mono="$(render GOVERN_PROMPT_SEGMENTED=0 -- 502)"
assert_eq "$(printf '%s' "$val" | wc -c | tr -d ' ')" "$(printf '%s' "$val_mono" | wc -c | tr -d ' ')" \
  "a validation ticket's prompt is byte-identical with segmentation on and off"

assert_done
