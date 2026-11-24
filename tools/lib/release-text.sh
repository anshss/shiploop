#!/usr/bin/env bash
# release-text.sh: the shared CHANGELOG-section extraction and release-body trim rule.
#
# Sourced by tools/check-release-parity.sh (which compares a release body against its
# CHANGELOG.md section) and tools/make-release.sh (which CUTS that body from the section), so
# the rule the writer uses and the rule the checker uses are the same code, and the two can
# never drift. This file only defines functions; sourcing it runs nothing.
#
# The heading -> version token rule is check-version-consistency.sh's, character for character
# (its `changelog_version=` line): whatever whitespace-delimited word follows "## ". Keeping
# one expression means a CHANGELOG heading style all three scripts must agree on can never
# drift between them.
heading_version() { printf '%s\n' "$1" | sed -E 's/^## +([^ ]+).*/\1/'; }

changelog_section() {  # content strictly between "## <ver>" and the next "## " heading
  local ver="$1" file="$2"
  local line
  local in_section=0
  while IFS= read -r line; do
    case "$line" in
      '## '*)
        if [ "$in_section" -eq 1 ]; then
          break
        fi
        if [ "$(heading_version "$line")" = "$ver" ]; then
          in_section=1
        fi
        continue
        ;;
    esac
    [ "$in_section" -eq 1 ] && printf '%s\n' "$line"
  done < "$file"
  return 0
}

# Drops any "## " heading line (a hand-cut release body sometimes repeats the version's own
# heading, with its own cut date rather than the CHANGELOG's bump date, e.g. v1.19.4's real
# release body dates its own heading the day it was cut, which is not always the day the
# CHANGELOG entry was written, so heading lines are structure and not content on either side
# of this comparison), trims
# trailing whitespace per line, then trims leading/trailing blank lines.
normalize_release_text() {
  awk '
    /^## / { next }
    { sub(/[[:space:]]+$/, ""); lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] == "") s++
      e = n; while (e >= s && lines[e] == "") e--
      for (i = s; i <= e; i++) print lines[i]
    }
  '
}
