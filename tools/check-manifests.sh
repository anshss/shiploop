#!/usr/bin/env bash
# check-manifests.sh — keep the "update pulls everything" channel honest.
#
# Two independent guards:
#
#   purge-manifest-complete   Every file deleted from templates/** in this diff (vs. the
#                             base branch) must have its INSTALLED path listed in
#                             templates/lib/purge.txt — otherwise scaffold.sh never removes
#                             the retired file from an already-scaffolded workspace and
#                             `/shiploop:update` silently leaves it behind.
#
#   seed-hashes-current       Every currently-shipped file under templates/seed/ (the set
#                             component_seeds fills-if-absent) must have its sha256 recorded
#                             in templates/lib/seed-hashes.txt — otherwise a hub improvement
#                             to a seed's content can never losslessly reach an existing
#                             workspace (component_seeds has nothing to match the old
#                             content against).
#
# Usage:  bash tools/check-manifests.sh
#
# Runnable locally with no args — diffs HEAD against the merge-base with origin/main (or
# origin/master), degrading gracefully (skip, not fail) when there's no reachable base ref
# (no `origin` remote, shallow clone with nothing fetched, etc). In CI, the workflow fetches
# `origin/main` first so the diff is always available for a PR.
set -euo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HUB"

fail=0

# ---------------------------------------------------------------------------
# Resolve the base commit to diff against. Prints the merge-base sha on stdout,
# or nothing if no usable base ref is reachable.
# ---------------------------------------------------------------------------
resolve_base_ref() {
  local ref=""
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    ref="origin/main"
  fi
  if [ -z "$ref" ] && git rev-parse --verify -q origin/master >/dev/null 2>&1; then
    ref="origin/master"
  fi
  if [ -z "$ref" ]; then
    printf ''
    return 0
  fi
  local base
  base="$(git merge-base "$ref" HEAD 2>/dev/null || true)"
  printf '%s' "$base"
  return 0
}

# ---------------------------------------------------------------------------
# Map a templates/** path to the workspace-relative installed path scaffold.sh
# writes it to. Mirrors scaffold.sh's component_* copy steps exactly — keep in
# sync if a component adds a new source directory.
# ---------------------------------------------------------------------------
map_installed_path() {
  local tpl="$1"
  local rel="${tpl#templates/}"
  local out=""
  case "$rel" in
    hooks/*.sh)
      out="scripts/$(basename "$rel")"
      ;;
    worktree/lib/*)
      out="scripts/worktree/lib/${rel#worktree/lib/}"
      ;;
    worktree/*)
      out="scripts/worktree/${rel#worktree/}"
      ;;
    govern/lib/*)
      out="scripts/govern/lib/${rel#govern/lib/}"
      ;;
    govern/*)
      out="scripts/govern/${rel#govern/}"
      ;;
    lib/*)
      out="scripts/lib/${rel#lib/}"
      ;;
    githooks/*)
      out=".githooks/${rel#githooks/}"
      ;;
    .claude/commands/*.md)
      out="$rel"
      ;;
    workflows/*.js)
      out=".claude/workflows/${rel#workflows/}"
      ;;
    skills/*/SKILL.md)
      out=".claude/$rel"
      ;;
    governor/*.md)
      out="$rel"
      ;;
    *.sh)
      case "$rel" in
        */*) out="" ;;   # nested .sh with no matching prefix above — unknown, not top-level
        *) out="scripts/$rel" ;;
      esac
      ;;
    *)
      out=""
      ;;
  esac
  printf '%s' "$out"
  return 0
}

# Does templates/lib/purge.txt list $installed, either verbatim or via a
# directory entry (a line ending in "/") that prefixes it?
purge_covers() {
  local installed="$1" purge_file="$2"
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac
    if [ "$line" = "$installed" ]; then
      return 0
    fi
    case "$line" in
      */)
        case "$installed" in
          "$line"*) return 0 ;;
        esac
        ;;
    esac
  done < "$purge_file"
  return 1
}

check_purge_manifest() {
  local purge_file="templates/lib/purge.txt"

  if [ -z "$BASE" ]; then
    echo "skip - purge-manifest-complete (no reachable base ref to diff against)"
    return 0
  fi
  if [ ! -f "$purge_file" ]; then
    echo "::error::purge-manifest-complete: missing $purge_file"
    fail=1
    return 0
  fi

  local deleted
  deleted="$(git diff --diff-filter=D --name-only "$BASE" HEAD -- templates 2>/dev/null || true)"

  if [ -z "$deleted" ]; then
    echo "ok - purge-manifest-complete (no templates/** deletions in this diff)"
    return 0
  fi

  local missing=()
  local tpl
  while IFS= read -r tpl; do
    [ -n "$tpl" ] || continue
    case "$tpl" in
      templates/govern/test/*) continue ;;   # hub-only, never installed
      templates/seed/*) continue ;;          # operator data, must never be purged
    esac
    local installed
    installed="$(map_installed_path "$tpl")"
    if [ -z "$installed" ]; then
      missing+=("$tpl  (no known installed-path mapping in tools/check-manifests.sh — extend map_installed_path or handle by hand)")
      continue
    fi
    if ! purge_covers "$installed" "$purge_file"; then
      missing+=("$tpl  ->  $installed")
    fi
  done <<< "$deleted"

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::purge-manifest-complete: deleted template(s) missing from $purge_file"
    local m
    for m in "${missing[@]}"; do
      echo "  MISSING: $m"
    done
    echo "Add the installed path(s) above to $purge_file so an already-scaffolded workspace sheds the retired file(s) on its next writer run (scaffold --component / /shiploop:update)."
    fail=1
    return 0
  fi

  echo "ok - purge-manifest-complete (${BASE:0:12} vs HEAD: all deletions accounted for in $purge_file)"
  return 0
}

check_seed_hashes() {
  local seed_dir="templates/seed"
  local hash_file="templates/lib/seed-hashes.txt"
  local seeds="CLAUDE.md CLAUDE-APPENDIX.md learnings.md tickets.md tickets-parked.md"

  if [ ! -f "$hash_file" ]; then
    echo "::error::seed-hashes-current: missing $hash_file"
    fail=1
    return 0
  fi

  local missing=()
  local seed
  for seed in $seeds; do
    local path="$seed_dir/$seed"
    [ -f "$path" ] || continue
    local sha
    sha="$(shasum -a 256 "$path" | cut -d' ' -f1)"
    if ! grep -qE "^${sha}[[:space:]]+${seed}\$" "$hash_file"; then
      missing+=("$seed  (sha256 $sha not recorded in $hash_file)")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::seed-hashes-current: current seed content missing from $hash_file"
    local m
    for m in "${missing[@]}"; do
      echo "  MISSING: $m"
    done
    echo "Run: bash tools/gen-seed-hashes.sh > $hash_file"
    fail=1
    return 0
  fi

  echo "ok - seed-hashes-current (every shipped seed's content hash is recorded)"
  return 0
}

main() {
  BASE="$(resolve_base_ref)"
  if [ -n "$BASE" ]; then
    echo "check-manifests: diffing templates/** deletions against merge-base $(git rev-parse --short "$BASE")"
  else
    echo "check-manifests: no reachable base ref (no origin/main or origin/master) — purge-manifest-complete will skip its deletion diff"
  fi
  echo
  echo "== purge-manifest-complete =="
  check_purge_manifest
  echo
  echo "== seed-hashes-current =="
  check_seed_hashes
  echo

  if [ "$fail" -ne 0 ]; then
    echo "check-manifests: FAILED — see ::error:: lines above"
    exit 1
  fi
  echo "check-manifests: all checks passed"
  return 0
}

main "$@"
