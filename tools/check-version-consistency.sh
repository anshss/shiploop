#!/usr/bin/env bash
# check-version-consistency.sh: the four files that carry a release version must agree.
#
# VERSION is the single source of truth. Two full releases (1.10.0 -> 1.12.0) drifted
# silently while validate-manifests stayed green, because that job only checked the
# manifests were valid JSON with non-empty fields, never that their version MATCHED
# anything. It recurred cutting v1.18.1 (marketplace.json stuck at 1.18.0), caught only
# by a hand-check seconds before merge. This script closes that gap by asserting equality
# across all four:
#
#   VERSION                                    <- source of truth, never advanced here
#   .claude-plugin/plugin.json       .version
#   .claude-plugin/marketplace.json  .plugins[0].version
#   CHANGELOG.md                     the first "## <version>" heading
#
# The CHANGELOG check reads whatever token follows "## " on the first heading line, so an
# "## Unreleased" left at the top after a release fails loudly (it never equals VERSION)
# instead of silently passing.
#
# Usage:  bash tools/check-version-consistency.sh [ROOT]
#   ROOT defaults to this script's repo root; pass a path to check a different tree
#   (a temp copy, for local proof runs).
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

fail=0

for f in VERSION .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md; do
  if [ ! -f "$f" ]; then
    echo "::error::missing file: $f"
    exit 1
  fi
done

version="$(tr -d '[:space:]' < VERSION)"
if [ -z "$version" ]; then
  echo "::error::VERSION is empty"
  exit 1
fi

plugin_version="$(jq -r '.version // ""' .claude-plugin/plugin.json)"
market_version="$(jq -r '.plugins[0].version // ""' .claude-plugin/marketplace.json)"

changelog_heading="$(grep -m1 '^## ' CHANGELOG.md || true)"
if [ -z "$changelog_heading" ]; then
  echo "::error::CHANGELOG.md has no '## ' heading to check"
  exit 1
fi
changelog_version="$(printf '%s\n' "$changelog_heading" | sed -E 's/^## +([^ ]+).*/\1/')"

if [ "$plugin_version" != "$version" ]; then
  echo "::error::plugin.json version ($plugin_version) disagrees with VERSION ($version)"
  fail=1
fi

if [ "$market_version" != "$version" ]; then
  echo "::error::marketplace.json plugins[0].version ($market_version) disagrees with VERSION ($version)"
  fail=1
fi

if [ "$changelog_version" != "$version" ]; then
  echo "::error::CHANGELOG.md top heading ($changelog_version, from line: \"$changelog_heading\") disagrees with VERSION ($version)"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "ok - VERSION=$version matches plugin.json, marketplace.json, and CHANGELOG.md's top heading"
