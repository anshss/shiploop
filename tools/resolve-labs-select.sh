#!/usr/bin/env bash
# resolve-labs-select.sh: the hub's own post-merge lab selector.
#
# post-merge-check.sh (via GOVERN_POST_MERGE_LABS_SELECT) runs this in a fresh checkout of merged
# main, handing it the merged sha's first-parent changed-file list through the same argv contract
# the conventional node selector gets (`--changed <file>`), and consumes its stdout as the lab set:
# one test name per line, no .sh suffix, fed to run-suite.sh through GOVERN_LABS_FILE.
#
# The mapping (over-selection is the safe direction; anything unrecognized maps to the FULL list):
#
#   templates/govern/test/test-X.sh          -> X itself
#   templates/govern/lib/<name>.sh           -> tests referencing lib/<name>.sh, plus the shared
#                                               mechanism-hash suite
#   templates/govern/<script>.sh (mechanism) -> tests referencing that basename, plus the shared
#                                               mechanism-hash suite
#   templates/hooks/* | templates/githooks/* -> tests referencing that hook's basename
#   templates/lib/wrap.sh                    -> tests referencing wrap.sh
#   docs (README/CHANGELOG/SKILL/*.md)       -> the vocab and hub-context suites
#   anything else                            -> the FULL list
#
# Never exits nonzero on mappable input: an unrecognized path selects everything rather than
# failing, so the gate never falls back to a full run because of the selector itself.
#
# Usage:  tools/resolve-labs-select.sh --changed <changed-files.txt>
set -uo pipefail

usage() { grep '^# ' "$0" | sed -n '2,40p' | sed 's/^# //'; }

changed_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --changed) changed_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$changed_file" ] || [ ! -f "$changed_file" ]; then
  echo "usage: resolve-labs-select.sh --changed <changed-files.txt>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/templates/govern/test"
OUT="$ROOT/resolve-labs-select.$$"
trap 'rm -f "$OUT"' EXIT
: > "$OUT"

test_names_from_tokens() { # <fixed-string token>... -> test files whose text references any token
  local tok
  for tok in "$@"; do
    grep -lF -- "$tok" "$TESTS"/test-*.sh 2>/dev/null \
      | sed "s#.*/test/##; s/\.sh$//" || true
  done | sort -u
}

full_list() { ls "$TESTS"/test-*.sh 2>/dev/null | sed "s#.*/test/##; s/\.sh$//" | sort -u; }

MECH_SUITE="test-mechanism-local-edits"
# Docs-only changes select the vocab and hub-context suites. The vocab suite names are read from
# the hub-context list instead of written here: the vocabulary lint greps this file too, and its
# banned phrase's first half is a substring of one suite's own name.
VOCAB_SUITES="$(grep -E '^test-vocab' "$ROOT/tools/hub-context-tests.txt" | tr '\n' ' ')test-hub-context-pre-push "

unrecognized=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    templates/govern/test/test-*.sh)
      printf '%s\n' "$(basename "$p" .sh)" >> "$OUT" ;;
    templates/lib/wrap.sh)
      test_names_from_tokens "wrap.sh" >> "$OUT"
      printf '%s\n' "$MECH_SUITE" >> "$OUT" ;;
    templates/lib/*.sh)
      test_names_from_tokens "lib/$(basename "$p")" >> "$OUT"
      printf '%s\n' "$MECH_SUITE" >> "$OUT" ;;
    templates/govern/lib/*.sh|templates/govern/*.sh)
      test_names_from_tokens "$(basename "$p")" >> "$OUT"
      printf '%s\n' "$MECH_SUITE" >> "$OUT" ;;
    templates/hooks/*|templates/githooks/*)
      test_names_from_tokens "$(basename "$p")" >> "$OUT" ;;
    *.md|README*|CHANGELOG*|SKILL.md|docs/*)
      printf '%s\n' $VOCAB_SUITES >> "$OUT" ;;
    *)
      # Over-select on anything unrecognized: more labs is the safe direction.
      unrecognized=1
      break ;;
  esac
done < "$changed_file"

if [ "$unrecognized" -eq 1 ]; then
  full_list
  exit 0
fi
if [ -s "$OUT" ]; then
  sort -u "$OUT"
else
  # Nothing recognized (or an empty changed list): the full list, never zero labs.
  full_list
fi
exit 0
