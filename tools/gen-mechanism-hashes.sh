#!/usr/bin/env bash
# gen-mechanism-hashes.sh — regenerate templates/lib/mechanism-hashes.txt from git history.
#
# Hub-only maintenance tool (never installed into a workspace). Emits every content hash each
# mechanism script (the files component_core_scripts / component_worktrees / component_govern
# install) has EVER been shipped with, so mechanism_install can decide whether a workspace's copy
# is provably unedited (safe to upgrade) or carries local edits (kept, never overwritten).
#
# Usage:  bash tools/gen-mechanism-hashes.sh [hub-dir] > templates/lib/mechanism-hashes.txt
#
# Run it after ANY commit that changes a mechanism template. CI check `mechanism-hashes-current`
# fails when a currently-shipped mechanism file is absent from the manifest. The set of files comes
# from `scaffold.sh --list-mechanism-files`, the same map the installer uses.
set -uo pipefail

HUB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HUB" || { echo "cannot cd to $HUB" >&2; exit 1; }

cat <<'HEADER'
# Mechanism-script content-hash manifest — every version of each hash-tracked mechanism script
# shiploop has ever shipped.
#
# Format: <sha256>  <template-relative path>
#
# WHY: /shiploop:update used to `cp` mechanism scripts over the workspace's, silently dropping any
# local fix. mechanism_install in scaffold.sh now overwrites a file ONLY when its hash is recorded
# here (provably an unedited shipped version). Any other hash = locally edited = kept, with the hub
# version written beside it as <file>.shiploop-new. Byte-identity is the whole safety argument.
#
# GENERATED — do not hand-edit. Regenerate after any mechanism template change:
#     bash tools/gen-mechanism-hashes.sh > templates/lib/mechanism-hashes.txt
HEADER
echo

bash "$HUB/scaffold.sh" --list-mechanism-files | cut -f1 | sort -u | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  path="templates/$rel"
  printf '# -- %s --\n' "$rel"
  {
    git log --format='%H' --all --follow -- "$path" 2>/dev/null \
    | while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        git cat-file -e "$sha:$path" 2>/dev/null || continue
        git cat-file blob "$sha:$path" | shasum -a 256 | cut -d' ' -f1
      done
    # The working-tree copy too, so the manifest is right before the template change is committed.
    [ -f "$path" ] && shasum -a 256 "$path" | cut -d' ' -f1
  } | sort -u | while IFS= read -r h; do
    printf '%s  %s\n' "$h" "$rel"
  done
  echo
done
