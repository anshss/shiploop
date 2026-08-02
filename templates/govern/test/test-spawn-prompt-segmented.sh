#!/usr/bin/env bash
# Locks in the conditionally-assembled worker prompt.
#
# Why it exists: `templates/governor/worker-prompt.md` is sent to EVERY worker and re-read on EVERY
# turn of that worker's session, so a block that only ever applies to one ticket class is per-turn
# tax on every other ticket. The validation block alone measured 6,207 of 24,216 template bytes
# (25.6%) and applies only to validation/spike tickets. Blocks fenced by
# `<!-- GOVERN:SECTION <name> -->` … `<!-- GOVERN:END <name> -->` are kept only for a ticket of that
# class; marker lines and maintainer HTML comments are always stripped.
#
# The asymmetry this test guards: a worker that needed a section it did NOT receive fails its
# ticket, and a failed attempt is ~100% waste whose retry costs more than the original. So the
# cases below assert INCLUSION far more aggressively than exclusion — a validation ticket must get
# the block on every one of the classifier's tells, and the kill switch must restore the monolith.
#
# Cases:
#   1. Ordinary ticket → the validation block is ABSENT and the always-on body is intact.
#   2. Validation ticket (each of the classifier's tells) → the block IS present.
#   3. GOVERN_PROMPT_SEGMENTED=0 → the block is present even for an ordinary ticket (kill switch).
#   4. Maintainer HTML comments never reach the worker, in either mode.
#   5. The marker lines themselves never reach the worker.
#   6. A locality batch containing ONE validation ticket keeps the block for the whole group.
#   7. The ordinary-ticket prompt is measurably smaller than the validation one.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

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

## #503 — sweep the thing
**Type:** Validation spike
Done when: evidence from a real run.

---

## #504 — check the pause button
Observed: need to live-verify the control.
Done when: it works.

---

## #505 — confirm the deploy path
Observed: nobody knows whether this does actually work end to end.
Done when: someone says so.

---
EOF
printf 'DOCTRINE-SENTINEL\n' > "$TMP/governor/preferences.md"

# A miniature worker-prompt.md with the same marker contract as the real template.
cat > "$TMP/governor/worker-prompt.md" <<'EOF'
<!--
MAINTAINER-COMMENT-SENTINEL — a note about the template that no worker should ever receive.
Spanning two lines on purpose.
-->
ALWAYS-ON-HEAD-SENTINEL

## How to work
Do the thing. {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}

<!-- GOVERN:SECTION validation -->
## Validation tickets
VALIDATION-BLOCK-SENTINEL — run the real test.
<!-- GOVERN:END validation -->

## Output contract
ALWAYS-ON-TAIL-SENTINEL
EOF

# GOVERN_SPAWN_PRINT_PROMPT=1 dumps the fully assembled prompt and exits without spawning anything.
render() { # <env assignments...> -- <ticket> [co-batched tickets...]
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift   # drop the --
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs" \
      GOVERN_WORKER_MODEL="sonnet" \
      GOVERN_SPAWN_PRINT_PROMPT=1 \
      ${envs[@]+"${envs[@]}"} "$SPAWN" "$@"
}

has() { # <text> <needle> -> 0 if present
  printf '%s' "$1" | grep -qF -- "$2"
}
assert_has() { # <text> <needle> <label>
  if has "$1" "$2"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       missing: %s\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_lacks() { # <text> <needle> <label>
  if has "$1" "$2"; then printf 'FAIL - %s\n       unexpectedly present: %s\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# 1. Ordinary ticket → validation block dropped, always-on body intact.
ord="$(render -- 501)"
assert_lacks "$ord" "VALIDATION-BLOCK-SENTINEL" \
  "ordinary ticket → the validation section is NOT in the assembled prompt"
assert_has "$ord" "ALWAYS-ON-HEAD-SENTINEL" "ordinary ticket → always-on head survives"
assert_has "$ord" "ALWAYS-ON-TAIL-SENTINEL" "ordinary ticket → always-on tail survives"
assert_has "$ord" "DOCTRINE-SENTINEL"       "ordinary ticket → operator doctrine still appended"
assert_has "$ord" "an ordinary ticket"      "ordinary ticket → {{TICKET_BLOCK}} still substituted"

# 2. Every classifier tell must KEEP the block. This is the direction that costs a failed ticket
# when it regresses, so all four of govern::is_validation_ticket's tells are covered.
for n in 502 503 504 505; do
  v="$(render -- "$n")"
  assert_has "$v" "VALIDATION-BLOCK-SENTINEL" \
    "validation ticket #$n → the validation section IS present (fail-closed classifier)"
done

# 3. Kill switch → monolith, even for an ordinary ticket.
mono="$(render GOVERN_PROMPT_SEGMENTED=0 -- 501)"
assert_has "$mono" "VALIDATION-BLOCK-SENTINEL" \
  "GOVERN_PROMPT_SEGMENTED=0 → every section present regardless of ticket class"
assert_has "$mono" "ALWAYS-ON-HEAD-SENTINEL" \
  "GOVERN_PROMPT_SEGMENTED=0 → always-on body unaffected"

# 4. Maintainer comments never reach the worker — in either mode. A comment left in the prompt is
# re-sent on every turn of the worker's session for no benefit.
assert_lacks "$ord"  "MAINTAINER-COMMENT-SENTINEL" "ordinary → maintainer HTML comment stripped"
assert_lacks "$mono" "MAINTAINER-COMMENT-SENTINEL" "kill switch → maintainer HTML comment still stripped"

# 5. Marker lines themselves never reach the worker.
assert_lacks "$ord"  "GOVERN:SECTION" "ordinary → SECTION marker line stripped"
assert_lacks "$ord"  "GOVERN:END"     "ordinary → END marker line stripped"
assert_lacks "$mono" "GOVERN:SECTION" "kill switch → SECTION marker line stripped"
assert_lacks "$mono" "GOVERN:END"     "kill switch → END marker line stripped"

# 6. A locality batch whose group contains one validation ticket keeps the block for the WHOLE
# group — the classifier runs over the assembled block, not just the primary's.
batch="$(render -- 501 502)"
assert_has "$batch" "VALIDATION-BLOCK-SENTINEL" \
  "batch containing a validation ticket → the section is kept for the whole group"

# 7. The saving is real and the validation prompt is not shrunk.
ord_n=$(printf '%s' "$ord" | wc -c | tr -d ' ')
ord_mono_n=$(printf '%s' "$mono" | wc -c | tr -d ' ')
if [ "$ord_n" -lt "$ord_mono_n" ]; then
  printf 'ok   - %s (%s < %s bytes)\n' \
    "segmentation makes an ordinary ticket's prompt smaller than the monolith" "$ord_n" "$ord_mono_n"
else
  printf 'FAIL - %s (%s vs %s bytes)\n' \
    "segmentation must shrink an ordinary ticket's prompt" "$ord_n" "$ord_mono_n"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
# A validation ticket must pay NOTHING for segmentation existing: same ticket, both modes, same
# bytes. This is the assertion that would catch a section fence accidentally swallowing content.
val_n=$(printf '%s' "$(render -- 502)" | wc -c | tr -d ' ')
val_mono_n=$(printf '%s' "$(render GOVERN_PROMPT_SEGMENTED=0 -- 502)" | wc -c | tr -d ' ')
assert_eq "$val_n" "$val_mono_n" \
  "a validation ticket's prompt is byte-identical with segmentation on and off"

assert_done
