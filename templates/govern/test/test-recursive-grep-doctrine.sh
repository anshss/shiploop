#!/usr/bin/env bash
# Tripwire for the recursive-search doctrine in templates/governor/worker-prompt.md.
#
# The doctrine says a tree search from the workspace root must run `command grep -r`, never bare
# `grep`: Claude Code's injected `grep` shims `ugrep --ignore-files`, which honors the root
# .gitignore that excludes each sub-repo, so a plain grep silently returns clean while a match sits
# inside a sub-repo. That instruction is the fix for a failure that already bit twice in one
# session (a worker's sweep and the advisor's own file-list build both came back clean over a live
# match), so nothing verifies the doctrine survives an edit to the page, this test does.
#
# HUB-CONTEXT test: asserts on the hub's templates/, so it exits 77 outside a hub checkout and is
# listed in tools/hub-context-tests.txt, which is what makes CI actually run it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/assert.sh"

# assert.sh lives at <hub>/templates/govern/test/, so ../../.. is the hub root.
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/README.md" ] && [ -d "$HUB/templates/governor" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

PAGE="$HUB/templates/governor/worker-prompt.md"

# The instruction itself: the qualified recursive form must be on the page.
assert_contains "$(cat "$PAGE")" "command grep -r" \
  "doctrine: worker-prompt.md instructs \`command grep -r\` for workspace-root tree searches"

# The explanation must survive with the instruction: without the why, a reader "simplifies" the
# qualifier away as noise and the silent-clean failure comes straight back. (The needle keeps the
# leading backtick: a needle starting with `-` is parsed as a grep option, not a pattern.)
assert_contains "$(cat "$PAGE")" '`--ignore-files`' \
  "doctrine: the explanatory line naming ugrep's --ignore-files is still on the page"

# The tickets-index grep (the step most likely to be adapted into a tree search by its reader)
# must carry the qualifier too, not just the context-economy bullet.
assert_contains "$(cat "$PAGE")" "\`command grep '^## #' queue/tickets.md\`" \
  "doctrine: the queue/tickets.md index grep is a \`command grep\` call"

# No bare recursive grep instruction may return: any \`grep -r\` on the page that is not
# \`command grep -r\` reintroduces the silent-clean hazard this doctrine exists to close. The one
# legitimate exception is the explanatory line itself, which quotes the hazard ("a plain \`grep
# -r <pattern> .\`"); it is excluded so the guard guards call sites, not prose about the hazard.
bare="$(grep -n '`grep -r' "$PAGE" | grep -v 'command grep' | grep -v 'plain `grep -r' || true)"
assert_eq "$bare" "" "doctrine: no bare \`grep -r\` call site remains on the page"

# Non-vacuity: the matcher must actually be able to fail.
probe="$(mktemp -d)"; trap 'rm -rf "$probe"' EXIT
printf 'FIRST `grep `^## #` queue/tickets.md` here\n' > "$probe/p.md"
probe_bare="$(grep -n '`grep' "$probe/p.md" | grep -v 'command grep' || true)"
assert_contains "$probe_bare" "grep" \
  "doctrine: self-check, a bare index grep is really detected by the same matcher"

assert_done
