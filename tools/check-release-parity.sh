#!/usr/bin/env bash
# check-release-parity.sh: a tag is not a release, and a version bump is not a tag, unless
# something says so.
#
# v1.18.4 was tagged and pushed with no GitHub Release ever cut for it, and nothing noticed
# until an operator read the releases page by eye. Separately, a bench PR bumped VERSION to
# 1.18.5 and merged with the tag+release cut only later, again caught by hand. Two directions
# of the same gap: a tag with no release, and a version with no tag.
#
# A third gap surfaced withdrawing v1.19.0 (`gh release delete v1.19.0 --cleanup-tag`, manifests
# rolled back to 1.18.5): `gh release delete --cleanup-tag` erases every trace of a burned
# version number, so nothing durable remembers it was ever handed out. Anyone who installed it
# from the marketplace holds a version string main no longer claims, so the next real cut must
# still be >= that number or those installs never see an update. BURNED-VERSIONS.txt is that
# durable record; this script is the only thing that reads it.
#
# Two modes, one script, so the version-compare and CHANGELOG-section logic is asserted once:
#
#   --pre   (pull_request, no repo-state assumptions beyond the checked-out branch): guards
#           the version this PR is ABOUT to ship.
#             - VERSION must be >= the highest published, non-draft release tag, and STRICTLY
#               GREATER than every BURNED-VERSIONS.txt entry.
#               The >= on the published side is deliberate and is the ONE place this script
#               departs from queue #64's proposed "fails when VERSION <= the highest published
#               tag". A release here is cut AFTER merge (CLAUDE.md rule 10), so main's VERSION
#               equals the newest release for most of its life: verified 2026-09-12, VERSION
#               was 1.19.4 and the newest published release was v1.19.4. A literal <= test
#               would therefore red EVERY pull request that is not itself a version bump,
#               which is a gate nobody can keep green. >= still catches every failure the
#               ticket names (a rollback below a shipped version, and any reuse of a burned
#               number), because no version above main's can already be published.
#             - CHANGELOG.unreleased.md must not exist with non-whitespace content. That ad
#               hoc parking convention (commit d648211) either stays empty or is removed, and
#               never silently carries notes past a release cut.
#
#   --post  (push to main, and a daily schedule so a merge that lands with a red run isn't the
#           only chance to catch it): guards what main ALREADY claims to have shipped.
#             (a) every v* tag reachable from main, at or above the oldest published
#                 release, has a published non-draft release (see the floor comment in
#                 check_post; RELEASE_PARITY_TAG_FLOOR overrides it, which is how the test
#                 pins it away from whatever the live releases page happens to say)
#             (b) VERSION on main has a matching v<VERSION> tag reachable from main
#             (c) that release's body equals the CHANGELOG.md section for that version and
#                 nothing else (trimmed). Same class of bug as v1.12.0's release body
#                 absorbing a stale "## Unreleased" block, generalized past that one incident
#
# All GitHub reads go through `gh`, authenticated via the workflow's GITHUB_TOKEN
# (`gh release list --json tagName,isDraft`, `gh release view <tag> --json body`). Never
# auto-publishes anything: release notes stay hand-curated, and this only fails loudly. Exits 0
# with a "skip -" line (not a failure) when `gh` is missing or unauthenticated, so a local dev
# run with no GitHub creds is never a false red.
#
# Usage:
#   bash tools/check-release-parity.sh --pre  [ROOT]
#   bash tools/check-release-parity.sh --post [ROOT]
#   ROOT defaults to this script's repo root; pass a path to check a fixture tree instead
#   (tools/test/test-release-parity.sh does exactly that, against a stubbed `gh`).
set -euo pipefail

usage() {
  echo "usage: bash tools/check-release-parity.sh --pre|--post [ROOT]" >&2
}

MODE="${1:-}"
case "$MODE" in
  --pre|--post) ;;
  *) usage; exit 2 ;;
esac
shift

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

BURNED_FILE="BURNED-VERSIONS.txt"
UNRELEASED_FILE="CHANGELOG.unreleased.md"
CHANGELOG_FILE="CHANGELOG.md"

# ---------------------------------------------------------------------------
# gh availability guard: never a false red on a machine with no GitHub creds.
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "skip - gh CLI not found on PATH; release-parity checks need it (https://cli.github.com)"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "skip - gh is not authenticated (run: gh auth login); release-parity checks need it"
  exit 0
fi

# ---------------------------------------------------------------------------
# Version compare (dotted numeric, via `sort -V`; no 'v' prefix assumed either side).
# ---------------------------------------------------------------------------
version_key() { printf '%s' "${1#v}"; }

version_gt() {  # true (0) if $1 > $2
  local a b top
  a="$(version_key "$1")"
  b="$(version_key "$2")"
  [ "$a" = "$b" ] && return 1
  top="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [ "$top" = "$a" ] && [ "$a" != "$b" ]
}

version_le() { ! version_gt "$1" "$2"; }  # true (0) if $1 <= $2
version_lt() { version_gt "$2" "$1"; }   # true (0) if $1 < $2

max_version() {
  local v top=""
  for v in "$@"; do
    v="$(version_key "$v")"
    [ -z "$v" ] && continue
    if [ -z "$top" ] || version_gt "$v" "$top"; then
      top="$v"
    fi
  done
  printf '%s' "$top"
}

# ---------------------------------------------------------------------------
# GitHub reads.
# ---------------------------------------------------------------------------
published_release_tags() {
  gh release list --json tagName,isDraft -L 1000 2>/dev/null \
    | jq -r '.[] | select(.isDraft == false) | .tagName'
}

release_body() {
  gh release view "$1" --json body -q .body 2>/dev/null || true
}

burned_versions() {
  [ -f "$BURNED_FILE" ] || return 0
  awk 'NF && $1 !~ /^#/ { print $1 }' "$BURNED_FILE"
}

# ---------------------------------------------------------------------------
# CHANGELOG.md section extraction, reusing check-version-consistency.sh's own
# heading-token match (whatever whitespace-delimited word follows "## ") rather than a
# second regex for the same idea.
# ---------------------------------------------------------------------------
# The heading -> version token rule is check-version-consistency.sh's, character for
# character (its `changelog_version=` line): whatever whitespace-delimited word follows
# "## ". Keeping one expression means a CHANGELOG heading style both scripts must agree on
# can never drift between them.
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

# ---------------------------------------------------------------------------
# --pre
# ---------------------------------------------------------------------------
check_pre() {
  local fail=0 version
  version="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
  if [ -z "$version" ]; then
    echo "::error::VERSION is empty or missing"
    return 1
  fi

  local pub_tags=() burned=()
  mapfile -t pub_tags < <(published_release_tags)
  mapfile -t burned < <(burned_versions)

  local highest_pub highest_burned
  highest_pub="$(max_version "${pub_tags[@]:-}")"
  highest_burned="$(max_version "${burned[@]:-}")"

  if [ -n "$highest_pub" ] && version_lt "$version" "$highest_pub"; then
    echo "::error::VERSION ($version) is BELOW the highest published release ($highest_pub); a merged rollback would strand every install already on $highest_pub"
    fail=1
  else
    echo "ok - VERSION ($version) is at or above the highest published release (${highest_pub:-none})"
  fi

  if [ -n "$highest_burned" ] && version_le "$version" "$highest_burned"; then
    echo "::error::VERSION ($version) is <= the highest withdrawn version in $BURNED_FILE ($highest_burned); that number was already handed out, so the next cut has to land above it"
    fail=1
  else
    echo "ok - VERSION ($version) is above every withdrawn version in $BURNED_FILE (${highest_burned:-none})"
  fi

  if [ -f "$UNRELEASED_FILE" ] && grep -q '[^[:space:]]' "$UNRELEASED_FILE" 2>/dev/null; then
    echo "::error::$UNRELEASED_FILE exists with content; fold it into a version section in CHANGELOG.md or delete it before merge"
    fail=1
  else
    echo "ok - $UNRELEASED_FILE is absent or empty"
  fi

  return "$fail"
}

# ---------------------------------------------------------------------------
# --post
# ---------------------------------------------------------------------------
resolve_main_ref() {
  if git rev-parse --verify -q refs/heads/main >/dev/null 2>&1; then
    printf 'main'
  elif git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main'
  else
    printf 'HEAD'
  fi
}

check_post() {
  local fail=0 main_ref version expect_tag found=0
  main_ref="$(resolve_main_ref)"

  local merged_tags=() pub_tags=()
  mapfile -t merged_tags < <(git tag --merged "$main_ref" --list 'v*' 2>/dev/null | sort -V)
  mapfile -t pub_tags < <(published_release_tags)

  local published_list
  published_list="$(printf '%s\n' "${pub_tags[@]:-}")"

  local t
  # Floor: a tag OLDER than this project's first-ever published release predates the
  # release convention itself and was never going to have one. Verified 2026-09-12 against
  # anshss/shiploop: the oldest published release is v1.6.0, and v1.0.0 v1.1.0 v1.2.0
  # v1.2.1 v1.3.0 v1.4.0 v1.4.1 v1.4.2 are eight tags from before that with no release and
  # no CHANGELOG section to backfill one from. Without a floor this check is red on main
  # forever over eight tags nobody is going to publish retroactively, and a permanently red
  # gate is a gate nobody reads.
  #
  # Deriving the floor rather than hardcoding it means it never needs maintenance, at one
  # cost worth naming: deleting the oldest release would raise the floor and stop checking
  # the tags just above it. That is a deliberate, destructive act on the releases page, not
  # a drift, which is why the auto-derived version wins over a constant that rots silently.
  local floor="${RELEASE_PARITY_TAG_FLOOR:-}"
  if [ -z "$floor" ]; then
    floor="$(printf '%s\n' "${pub_tags[@]:-}" | sed 's/^v//' | grep . | sort -V | head -n1)"
  fi

  local offenders=()
  local skipped_below_floor=0
  for t in "${merged_tags[@]:-}"; do
    if [ -n "$floor" ] && version_lt "$t" "$floor"; then
      skipped_below_floor=$((skipped_below_floor + 1))
      continue
    fi
    printf '%s\n' "$published_list" | grep -qxF "$t" || offenders+=("$t")
  done
  if [ "$skipped_below_floor" -gt 0 ]; then
    echo "note - $skipped_below_floor tag(s) below the oldest published release (v$floor) predate the release convention and are not checked"
  fi
  if [ "${#offenders[@]}" -gt 0 ]; then
    echo "::error::tag(s) reachable from $main_ref with no published, non-draft release: ${offenders[*]}"
    fail=1
  else
    echo "ok - every v* tag reachable from $main_ref at or above v$floor ($(( ${#merged_tags[@]} - skipped_below_floor )) of ${#merged_tags[@]} tag(s)) has a published release"
  fi

  version="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
  expect_tag="v$version"
  for t in "${merged_tags[@]:-}"; do
    [ "$t" = "$expect_tag" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "::error::VERSION ($version) has no matching tag $expect_tag reachable from $main_ref"
    fail=1
  else
    echo "ok - VERSION ($version) has a matching tag $expect_tag reachable from $main_ref"
  fi

  if [ "$found" -eq 1 ]; then
    local body section norm_body norm_section
    body="$(release_body "$expect_tag")"
    section="$(changelog_section "$version" "$CHANGELOG_FILE")"
    norm_body="$(printf '%s\n' "$body" | normalize_release_text)"
    norm_section="$(printf '%s\n' "$section" | normalize_release_text)"
    if [ "$norm_body" != "$norm_section" ]; then
      echo "::error::release $expect_tag's body does not equal CHANGELOG.md's $version section (trimmed, heading lines ignored)"
      fail=1
    else
      echo "ok - release $expect_tag's body equals CHANGELOG.md's $version section"
    fi
  fi

  return "$fail"
}

# `check_pre; rc=$?` would never reach the assignment: under `set -e` a function returning
# non-zero aborts the script, and the ::error:: summary below would be lost. `|| rc=$?` is
# the exempt form.
rc=0
if [ "$MODE" = "--pre" ]; then
  check_pre || rc=$?
else
  check_post || rc=$?
fi

if [ "$rc" -ne 0 ]; then
  echo "::error::release-parity $MODE checks failed"
  exit 1
fi
echo "ok - release-parity $MODE checks passed"
