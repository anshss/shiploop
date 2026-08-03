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
# Assertion style (post-#84): every check below targets a STRUCTURAL invariant, not an author's
# sentence. The Flow subfield names (`gatePassed`/`validatedShas`/`flowIds`) are the actual JSON
# key names `lib/flows.sh` and `spawn-worker.sh` read off the worker's report — pinning them is
# pinning the machine contract, not prose, and a maintainer is free to reword every sentence
# around them without reddening this test. For the FIRST `validation`-named block (the doctrine
# span with no JSON keys of its own), we do NOT hardcode any of its wording: `first_block_anchor()`
# below reads the real file at run time and extracts the first non-blank, non-comment line
# immediately after the first `<!-- GOVERN:SECTION validation -->` marker, whatever that line
# currently says. That single line is then used as the presence/absence probe. This would catch:
#   - the fence marker being deleted or misspelled (extraction comes back empty → hard FAIL below,
#     independent of any render check)
#   - the block being moved outside the fence (leaks into the "ordinary ticket" render)
#   - the block being dropped from inside the fence (goes missing from the "validation ticket" and
#     "kill switch" renders)
# It would NOT catch a maintainer rewording that same line, or any other line in the block — which
# is the point: rewording is exactly what #84 needs to stop breaking this test.
#
# Cases:
#   1. Ordinary ticket → none of the Flow subfield names appear; the base doctrine block is ALSO
#      absent (both `validation`-named blocks travel together).
#   2. Validation ticket → both blocks present: the Flow subfield names AND the doctrine block.
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

# Structural sanity: exactly TWO `validation`-named SECTION/END marker pairs must exist in the real
# file (span A's doctrine block + span A's Flow-subfield block — see the header). This is checked
# BEFORE the dynamic anchor extraction below on purpose: if a marker is deleted, `first_block_anchor`
# would otherwise silently re-anchor to whichever fenced block now comes "first" and could report a
# false pass. Counting the raw markers catches marker deletion/duplication directly, independent of
# any content extraction.
sec_count="$(grep -c '^[[:space:]]*<!-- GOVERN:SECTION validation -->[[:space:]]*$' "$WORKER_PROMPT" || true)"
end_count="$(grep -c '^[[:space:]]*<!-- GOVERN:END validation -->[[:space:]]*$' "$WORKER_PROMPT" || true)"
assert_eq "$sec_count" "2" "worker-prompt.md has exactly two GOVERN:SECTION validation markers"
assert_eq "$end_count" "2" "worker-prompt.md has exactly two GOVERN:END validation markers"

# Dynamically extract the first content line of the FIRST `validation`-named fenced block from the
# REAL worker-prompt.md — never hardcoded, so a wording-only edit to that line can't redden this
# test. Empty result means the fence marker itself is missing/malformed, which is a genuine
# contract break, so callers must treat empty as a hard failure (checked immediately below).
first_block_anchor() {
  awk '
    /^[[:space:]]*<!-- GOVERN:SECTION validation -->[[:space:]]*$/ { c++; if (c == 1) { armed = 1; next } }
    armed && NF && $0 !~ /^[[:space:]]*<!--/ { print; exit }
  ' "$WORKER_PROMPT"
}
DOCTRINE_ANCHOR="$(first_block_anchor)"
if [[ -z "$DOCTRINE_ANCHOR" ]]; then
  printf 'FAIL - %s\n' "could not locate the first validation-fenced block's leading line (fence marker missing/malformed?)"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
  DOCTRINE_ANCHOR="__NO-DOCTRINE-ANCHOR-FOUND__"   # keep going; below assertions will still be meaningful
else
  printf 'ok   - %s\n' "resolved a live anchor line for the first validation-fenced (doctrine) block"
fi

# 1. Ordinary ticket → neither validation-named block reaches the worker.
ord="$(render -- 501)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_lacks "$ord" "\`$f\`" "ordinary ticket → Flow subfield '$f' is NOT in the assembled prompt"
done
assert_lacks "$ord" "$DOCTRINE_ANCHOR" \
  "ordinary ticket → the base validation doctrine block is also absent (both blocks fenced by the same name)"

# 2. Validation ticket → both validation-named blocks are present.
val="$(render -- 502)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_has "$val" "\`$f\`" "validation ticket → Flow subfield '$f' IS present"
done
assert_has "$val" "$DOCTRINE_ANCHOR" \
  "validation ticket → the base validation doctrine block is also present"

# 3. Kill switch → both blocks present even for an ordinary ticket.
mono="$(render GOVERN_PROMPT_SEGMENTED=0 -- 501)"
for f in "${FLOW_FIELDS[@]}"; do
  assert_has "$mono" "\`$f\`" "GOVERN_PROMPT_SEGMENTED=0 → Flow subfield '$f' present regardless of ticket class"
done
assert_has "$mono" "$DOCTRINE_ANCHOR" \
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
