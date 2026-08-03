#!/usr/bin/env bash
# gen-seed-hashes.sh — regenerate templates/lib/seed-hashes.txt from git history.
#
# Hub-only maintenance tool (never installed into a workspace). Emits every content
# hash each seed file has EVER been shipped with, so component_seeds can decide
# whether a workspace's copy is provably unedited and therefore losslessly upgradable.
#
# Usage:  bash tools/gen-seed-hashes.sh [hub-dir] > templates/lib/seed-hashes.txt
#
# Run it after ANY commit that changes templates/seed/*. CI check `seed-hashes-current`
# fails when the currently-shipped seeds are absent from the manifest.
set -uo pipefail

HUB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HUB" || { echo "cannot cd to $HUB" >&2; exit 1; }

SEEDS="CLAUDE.md CLAUDE-APPENDIX.md learnings.md tickets.md tickets-parked.md"

cat <<'HEADER'
# Seed content-hash manifest — every version of each seed file shiploop has ever shipped.
#
# Format: <sha256>  <seed-filename>
#
# WHY: component_seeds is fill-if-absent, so a hub improvement to a seed's CONTENT (a
# trim, a corrected rule) only ever reached brand-new installs. Overwriting an existing
# seed outright is unacceptable — a workspace's CLAUDE.md accumulates every promoted
# lesson and queue/tickets.md is live backlog.
#
# This manifest makes a LOSSLESS upgrade decidable: if a workspace's seed hashes to a
# version recorded here, the operator provably never edited it, so replacing it with the
# current seed destroys nothing. Any other hash = customized = left untouched, silently.
# Byte-identity is the whole safety argument — never heuristic, never a merge.
#
# GENERATED — do not hand-edit. Regenerate after any templates/seed/* change:
#     bash tools/gen-seed-hashes.sh > templates/lib/seed-hashes.txt
HEADER
echo

for seed in $SEEDS; do
  printf '# -- %s --\n' "$seed"
  git log --format='%H' --all --follow -- "templates/seed/$seed" 2>/dev/null \
  | while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      git cat-file -e "$sha:templates/seed/$seed" 2>/dev/null || continue
      printf '%s  %s\n' \
        "$(git cat-file blob "$sha:templates/seed/$seed" | shasum -a 256 | cut -d' ' -f1)" \
        "$seed"
    done | sort -u
  echo
done
