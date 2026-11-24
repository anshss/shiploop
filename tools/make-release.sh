#!/usr/bin/env bash
# make-release.sh: the release ceremony as one verified step instead of six hand-run ones.
#
# Closing a release by hand is a six-to-ten-step sequence (fetch, bump VERSION and both
# manifests, regenerate mechanism-hashes, write the CHANGELOG section, run the consistency
# and parity --pre checks, commit, tag, push, cut the GitHub release with a body that must
# equal the CHANGELOG section) and two of those steps are races against main's movement: a
# manifest regen against a stale origin fails the pull-merge-ref check, and a hand-pasted
# release body can omit lines the section carries and fail parity after the cut. Every one of
# those errors is mechanical, so this script owns the whole sequence:
#
#   preconditions: clean tree, on main, fetched and exactly at origin/main, <version>
#     strictly greater than VERSION, no v<version> tag or GitHub release already existing,
#     and a CHANGELOG.md section for <version> already present (the author owns the prose;
#     this script never writes it).
#   mutations: bump VERSION and both manifest versions, regenerate
#     templates/lib/mechanism-hashes.txt post-fetch.
#   verification: check-version-consistency.sh and check-release-parity.sh --pre both pass
#     BEFORE anything is committed; any refusal exits non-zero with nothing committed.
#   landing: commit "release: <version>, <headline>", tag v<version>, push main and the tag
#     in one push, create the GitHub release v<version> with the body extracted from the
#     CHANGELOG section using the exact functions check-release-parity.sh compares with
#     (tools/lib/release-text.sh), then run parity --post and, on a body mismatch only,
#     self-heal the release body from the section with bounded retries before reporting
#     success.
#
# --dry-run runs the preconditions and the full mutation + verification stage inside a
# throwaway local clone of HEAD and reports what the real run would do; the checked-out tree
# is not modified and nothing is committed, tagged, pushed or released.
#
# gh is a hard requirement, not a skip like the checkers: this script's landing path IS gh,
# and every gh call fails loud (no `|| true` anywhere on that path).
#
# Usage:
#   bash tools/make-release.sh <version> --headline "<commit headline>" [--dry-run]
#
# Knobs:
#   MAKE_RELEASE_POST_WAIT    seconds parity --post waits for a lagging release read
#                             (default 180; passed through as RELEASE_PARITY_POST_WAIT)
#   MAKE_RELEASE_POST_POLL    parity --post poll interval (default 20)
#   MAKE_RELEASE_HEAL_ATTEMPTS  self-heal retries after a body mismatch (default 3)
set -euo pipefail

usage() {
  echo "usage: bash tools/make-release.sh <version> --headline \"<commit headline>\" [--dry-run]" >&2
}

fail() {
  echo "::error::$1" >&2
  exit 1
}

VERSION_ARG=""
HEADLINE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --headline)
      [ $# -ge 2 ] || { usage; exit 2; }
      HEADLINE="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [ -z "$VERSION_ARG" ] || { usage; exit 2; }
      VERSION_ARG="${1#v}"
      ;;
  esac
  shift
done
if [ -z "$VERSION_ARG" ] || [ -z "$HEADLINE" ]; then
  usage
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/release-text.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/release-text.sh"

# ---------------------------------------------------------------------------
# Preconditions. All read-only, and all of them run for --dry-run too.
# ---------------------------------------------------------------------------
command -v gh >/dev/null 2>&1 \
  || fail "gh CLI not found on PATH; make-release.sh cuts a GitHub release and cannot proceed without it (https://cli.github.com)"
gh auth status >/dev/null 2>&1 \
  || fail "gh is not authenticated (run: gh auth login); make-release.sh cuts a GitHub release"

# The one permitted pending change is the CHANGELOG.md section for this release: release parity
# counts the CHANGELOG lines the RELEASE COMMIT itself adds, so the staged section must land
# inside that commit, never before it. Anything else pending refuses.
unrelated="$(git status --porcelain | grep -v ' CHANGELOG\.md$' || true)"
[ -z "$unrelated" ] \
  || fail "working tree has pending changes other than CHANGELOG.md; commit or remove them before a release"
[ -n "$(git status --porcelain -- CHANGELOG.md)" ] \
  || fail "no CHANGELOG.md modification staged; write the <version> section first, then rerun"

branch="$(git branch --show-current)"
[ "$branch" = "main" ] || fail "not on main (on '$branch'); a release lands on main"

# The fetch is what makes the staleness check trustworthy: without it HEAD can sit behind a
# main that moved (a merged train PR) and every later check runs against a stale origin.
git fetch origin main --tags --force --quiet || fail "git fetch origin main --tags failed; fix the remote before a release"

head_sha="$(git rev-parse HEAD)"
origin_sha="$(git rev-parse --verify -q origin/main^{commit})" \
  || fail "no origin/main after the fetch; the remote has no main branch"
if [ "$head_sha" != "$origin_sha" ]; then
  fail "stale origin: HEAD ($head_sha) is not origin/main ($origin_sha); pull or push to align with origin/main, then rerun (this is the race that once reddened main with a hand-run release)"
fi

cur_version="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[ -n "$cur_version" ] || fail "VERSION is empty or missing"
version_top="$(printf '%s\n%s\n' "$VERSION_ARG" "$cur_version" | sort -V | tail -n1)"
if [ "$version_top" != "$VERSION_ARG" ] || [ "$VERSION_ARG" = "$cur_version" ]; then
  fail "<version> ($VERSION_ARG) is not strictly greater than VERSION ($cur_version)"
fi

git rev-parse --verify -q "refs/tags/v$VERSION_ARG" >/dev/null \
  && fail "tag v$VERSION_ARG already exists; a version number is never reused, pick the next one"

section="$(changelog_section "$VERSION_ARG" CHANGELOG.md)"
norm_section="$(printf '%s\n' "$section" | normalize_release_text)"
[ -n "$norm_section" ] \
  || fail "CHANGELOG.md has no section for $VERSION_ARG; the author owns the prose, so write the '## $VERSION_ARG' section before running make-release.sh"

gh release view "v$VERSION_ARG" --json name >/dev/null 2>&1 \
  && fail "GitHub release v$VERSION_ARG already exists; refusing to touch it"

# ---------------------------------------------------------------------------
# Mutations: the release files this script owns. The CHANGELOG section is NOT one of them
# (precondition above); neither the commits' messages nor any other file is touched.
# ---------------------------------------------------------------------------
apply_mutations() {  # $1 = hub root to mutate in place
  local root="$1" f
  printf '%s\n' "$VERSION_ARG" > "$root/VERSION"
  for f in '.claude-plugin/plugin.json:.version' '.claude-plugin/marketplace.json:.plugins[0].version'; do
    jq --arg v "$VERSION_ARG" "${f#*:} = \$v" "$root/${f%%:*}" > "$root/${f%%:*}.tmp"
    mv "$root/${f%%:*}.tmp" "$root/${f%%:*}"
  done
  bash "$root/tools/gen-mechanism-hashes.sh" "$root" > "$root/templates/lib/mechanism-hashes.txt"
}

run_verifications() {  # $1 = hub root to verify; non-zero aborts the caller before any landing
  bash "$1/tools/check-version-consistency.sh" "$1"
  bash "$1/tools/check-release-parity.sh" --pre "$1"
}

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
printf '%s\n' "$norm_section" > "$body_file"

# ---------------------------------------------------------------------------
# --dry-run: same preconditions, mutations and verifications, but inside a throwaway
# local clone of HEAD, so the checked-out tree and every remote state stay untouched.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  dry_dir="$(mktemp -d)"
  trap 'rm -f "$body_file"; rm -rf "$dry_dir"' EXIT
  git clone --local --quiet "$ROOT" "$dry_dir"
  apply_mutations "$dry_dir"
  run_verifications "$dry_dir"
  echo "dry-run - preconditions, mutations and verifications passed in a throwaway clone of HEAD"
  echo "dry-run - the real run would: bump VERSION and both manifests, regenerate templates/lib/mechanism-hashes.txt, commit 'release: $VERSION_ARG, $HEADLINE', tag v$VERSION_ARG, push main and the tag, create GitHub release v$VERSION_ARG with the body extracted from CHANGELOG.md's section, then run parity --post with self-heal on a body mismatch"
  exit 0
fi

# ---------------------------------------------------------------------------
# Real run: mutate, verify, and only then land. set -e makes any verification refusal
# abort right here, with the working tree mutated but NOTHING committed, tagged or pushed;
# rerunning after fixing the failure is safe (the mutations are idempotent).
# ---------------------------------------------------------------------------
apply_mutations "$ROOT"
run_verifications "$ROOT"

git add VERSION .claude-plugin/plugin.json .claude-plugin/marketplace.json templates/lib/mechanism-hashes.txt CHANGELOG.md
git commit -m "release: $VERSION_ARG, $HEADLINE"
git tag "v$VERSION_ARG"
git push origin main "refs/tags/v$VERSION_ARG"
gh release create "v$VERSION_ARG" --verify-tag --title "v$VERSION_ARG" --notes-file "$body_file"

# ---------------------------------------------------------------------------
# Parity --post with self-heal. The tag and release only just landed, so the wait knobs are
# passed through to the checker (its own retry refetches tags between attempts). A body
# mismatch is the one failure this script can be the CAUSE of, so it is also the one it
# repairs: rewrite the release body from the same extracted section and retry, bounded.
# ---------------------------------------------------------------------------
post_wait="${MAKE_RELEASE_POST_WAIT:-180}"
post_poll="${MAKE_RELEASE_POST_POLL:-20}"
heal_attempts="${MAKE_RELEASE_HEAL_ATTEMPTS:-3}"
case "$post_wait" in ''|*[!0-9]*) post_wait=180 ;; esac
case "$post_poll" in ''|*[!0-9]*) post_poll=20 ;; esac
case "$heal_attempts" in ''|*[!0-9]*) heal_attempts=3 ;; esac

attempt=1
while :; do
  post_rc=0
  post_out="$(RELEASE_PARITY_POST_WAIT="$post_wait" RELEASE_PARITY_POST_POLL="$post_poll" \
    bash "$ROOT/tools/check-release-parity.sh" --post "$ROOT" 2>&1)" || post_rc=$?
  if [ "$post_rc" -eq 0 ]; then
    printf '%s\n' "$post_out"
    echo "ok - release $VERSION_ARG is fully landed: commit, tag v$VERSION_ARG, push, and release with a body parity accepts"
    exit 0
  fi
  if printf '%s' "$post_out" | grep -q "does not equal" && [ "$attempt" -lt "$heal_attempts" ]; then
    echo "note - release body mismatch on attempt $attempt; self-healing the body from CHANGELOG.md's section and retrying"
    gh release edit "v$VERSION_ARG" --notes-file "$body_file"
    sleep 3
    attempt=$((attempt + 1))
    continue
  fi
  printf '%s\n' "$post_out"
  fail "parity --post did not pass after the landing (attempt $attempt); inspect release v$VERSION_ARG by hand"
done
