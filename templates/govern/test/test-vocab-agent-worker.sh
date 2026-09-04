#!/usr/bin/env bash
# Vocabulary lint: the phrase "Agent worker" is BANNED across the hub's prose surfaces.
#
# Why a mechanical check and not a review note: the hub used "worker" in two senses at once.
# One sense is the trim, single-ticket session (two lanes: interactive
# `Agent(subagent_type: "worker")`, autonomous spawn-worker.sh). The other, in three files,
# meant a stock Agent-tool child. A model told to "delegate to an `Agent` worker" then spawns
# a full-fat subagent while believing it complies with the worker doctrine, so the collision
# routed real spend the wrong way. The platform's own noun for an Agent-tool child that is not
# subagent_type "worker" is **subagent**; that is the word to use.
#
# The scan is the hub's own tree (commands/, templates/, README.md, SKILL.md, and skills/ if
# present), so this is a HUB-CONTEXT test: it exits 77 outside a hub checkout and is listed in
# tools/hub-context-tests.txt, which is what makes CI actually run it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# assert.sh lives at <hub>/templates/govern/test/, so ../../.. is the hub root.
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/README.md" ] && [ -d "$HUB/templates" ] && [ -d "$HUB/commands" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

# The banned phrase, in one place. `.{0,3}` catches "Agent worker", "Agent-worker",
# "Agentworker", "Agent's worker" and the plurals; grep is line-oriented, so a legitimate
# multi-line construct (a pasteable `Agent(` call whose `subagent_type: "worker"` sits on the
# next line) can never trip it.
PATTERN='Agent.{0,3}workers?'
SELF="$(basename "${BASH_SOURCE[0]}")"

targets=(commands templates README.md SKILL.md)
[ -d "$HUB/skills" ] && targets+=(skills)

hits="$(cd "$HUB" && grep -rInE -i --exclude="$SELF" --exclude-dir=.git "$PATTERN" "${targets[@]}" 2>/dev/null)"

if [ -z "$hits" ]; then
  printf 'ok   - vocab: no /%s/i in %s\n' "$PATTERN" "${targets[*]}"
else
  printf 'FAIL - vocab: the phrase "Agent worker" is banned (say "subagent", or route it to a worker)\n'
  printf '%s\n' "$hits" | sed 's/^/       /'
  ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi

# Self-check: the scan must actually be capable of failing. A typo in the pattern or an empty
# target list would otherwise report a permanently green lint over nothing.
probe="$(mktemp -d)"; trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/commands"
printf 'dispatch an Agent worker per surface\n' > "$probe/commands/decoy.md"
printf 'README\n' > "$probe/README.md"
printf 'SKILL\n' > "$probe/SKILL.md"
mkdir -p "$probe/templates"
probe_hits="$(cd "$probe" && grep -rInE -i --exclude="$SELF" --exclude-dir=.git "$PATTERN" commands templates README.md SKILL.md 2>/dev/null)"
assert_contains "$probe_hits" "commands/decoy.md" "self-check: the pattern really does catch a planted 'Agent worker'"

assert_done
