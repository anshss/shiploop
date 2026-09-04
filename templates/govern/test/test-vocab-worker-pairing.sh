#!/usr/bin/env bash
# Pairing tripwire for the README Glossary's claim about the docs.
#
# README's Glossary asserts "Every page pairs a term with its definition on its first prose use".
# That is a claim ABOUT the documentation, made INSIDE the documentation, and nothing verified it:
# v1.18.1 shipped the sentence while four pages introduced "worker" with no definition anywhere near
# it. A docs claim the docs do not satisfy is the same defect species as an unsourced number, so it
# gets the same treatment: make the claim true, then guard it.
#
# The rule: on every page below, the FIRST prose mention of "worker" must carry the definition
# appositive. Prose means outside fenced code blocks and outside HTML tags (an <img alt="..."> is not
# where a reader learns a term).
#
# Deliberately lane-neutral: the appositive is "single-ticket session", never "headless
# single-ticket session". A worker has ONE definition and TWO lanes, and the interactive lane is not
# headless. Baking "headless" into the noun would contradict .claude/agents/worker.md.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/assert.sh"

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/README.md" ] && [ -d "$HUB/commands" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

DEFN="single-ticket session"

PAGES="README.md SKILL.md commands/flows.md commands/setup.md commands/update.md commands/statusline.md"

for page in $PAGES; do
  f="$HUB/$page"
  if [ ! -f "$f" ]; then
    assert_eq "missing" "present" "pairing: $page exists"
    continue
  fi

  # Strip fenced code blocks, then HTML tags (kills <img alt="...a worker..."> and friends).
  first="$(awk '
      /^[[:space:]]*```/ { infence = !infence; next }
      infence { next }
      { line = $0
        while (match(line, /<[^>]*>/)) { line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH) }
        print line }
    ' "$f" | grep -inE '\bworkers?\b' | head -1)"

  if [ -z "$first" ]; then
    # A page that never says "worker" in prose has nothing to pair. Not a failure.
    printf 'ok   - pairing: %s never mentions a worker in prose\n' "$page"
    continue
  fi

  case "$first" in
    *"$DEFN"*)
      printf 'ok   - pairing: %s defines the noun on first prose use\n' "$page" ;;
    *)
      printf 'FAIL - pairing: %s introduces "worker" with no definition on first prose use\n' "$page"
      printf '       %s\n' "$first"
      printf '       the first prose mention must carry the appositive "%s"\n' "$DEFN"
      ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  esac
done

# The Glossary sentence this test exists to keep honest must still be there. If someone deletes the
# claim instead of satisfying it, this test would otherwise go green over nothing.
glossary_claim="$(grep -c "first prose use" "$HUB/README.md" 2>/dev/null || echo 0)"
assert_eq "$([ "$glossary_claim" -ge 1 ] && echo present || echo missing)" "present" \
  "pairing: the README Glossary still makes the first-prose-use claim this test guards"

# Non-vacuity: the matcher must actually be able to fail.
probe="$(mktemp -d)"; trap 'rm -rf "$probe"' EXIT
printf 'a bare worker mention with no definition\n' > "$probe/p.md"
probe_first="$(awk '/^[[:space:]]*```/ { infence = !infence; next } infence { next } { print }' "$probe/p.md" \
  | grep -inE '\bworkers?\b' | head -1)"
assert_not_contains "$probe_first" "$DEFN" \
  "pairing: self-check, an undefined first mention really is detected as undefined"

assert_done
