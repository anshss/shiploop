#!/usr/bin/env bash
# Regression for tools/check-release-parity.sh.
#
# Runs the real script against small fixture git repos with a stubbed `gh` earlier on PATH
# (no network, no credentials). Registration mirrors how tools/check-version-consistency.sh
# and tools/check-manifests.sh are asserted: a hub-only tools/ script run directly as a CI
# step (see the `release-parity` job in .github/workflows/ci.yml), not routed through
# tools/hub-context-tests.txt, because that file's resolution is hardwired to
# `templates/govern/test/$name.sh` (the fleet-template mechanism), which does not apply to a
# script that only exists in the hub's own tools/.
#
# Usage: bash tools/test/test-release-parity.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "$DIR/.." && pwd)/check-release-parity.sh"
# Resolved once, as an absolute path: scenario 9 below runs the tool with PATH cleared of
# everything (including `gh`), so `env ... bash ...` must not need a PATH lookup for `bash`
# itself.
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ASSERT_FAILS=0
assert_eq() {  # actual expected label
  if [ "$1" = "$2" ]; then
    printf 'ok   - %s\n' "$3"
  else
    printf 'FAIL - %s (expected %s, got %s)\n' "$3" "$2" "$1"
    ASSERT_FAILS=$((ASSERT_FAILS + 1))
  fi
}
assert_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) printf 'ok   - %s\n' "$3" ;;
    *)
      printf 'FAIL - %s (expected output to contain %q)\n%s\n' "$3" "$2" "$1"
      ASSERT_FAILS=$((ASSERT_FAILS + 1))
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Stubbed `gh`: replays canned JSON from env vars the caller sets per invocation (via `env
# VAR=... bash "$TOOL" ...`, never `export`, so nothing leaks between scenarios).
# ---------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  [ "${STUB_GH_AUTH_OK:-1}" = "1" ] && exit 0 || exit 1
fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${STUB_RELEASE_LIST_JSON:-[]}"
  exit 0
fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then
  tag="${3:-}"
  var="STUB_BODY_$(printf '%s' "$tag" | tr -c 'A-Za-z0-9' '_')"
  printf '%s' "${!var:-}"
  exit 0
fi
echo "gh-stub: unhandled invocation: $*" >&2
exit 9
GHSTUB
chmod +x "$STUB_BIN/gh"
STUBBED_PATH="$STUB_BIN:$PATH"

EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$EMPTY_BIN"

# ---------------------------------------------------------------------------
# Fixture builder: a throwaway git repo with VERSION/CHANGELOG.md (and optionally
# BURNED-VERSIONS.txt / CHANGELOG.unreleased.md), one commit, tags on that commit. Tags don't
# need to be historically accurate to exercise the ancestry/version-compare logic, only
# reachable from main.
mk_fixture() {  # name  version  changelog_body  [burned_body]  [unreleased_body]
  local name="$1" version="$2" changelog="$3" burned="${4:-}" unreleased="${5:-}"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '%s' "$version" > "$dir/VERSION"
  printf '%s' "$changelog" > "$dir/CHANGELOG.md"
  if [ -n "$burned" ]; then
    printf '%s' "$burned" > "$dir/BURNED-VERSIONS.txt"
  fi
  if [ -n "$unreleased" ]; then
    printf '%s' "$unreleased" > "$dir/CHANGELOG.unreleased.md"
  fi
  ( cd "$dir" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name t \
      && git add -A \
      && git commit -q -m init )
  printf '%s' "$dir"
}
tag_head() { ( cd "$1" && git tag "$2" ); }  # dir tag

# RELEASE_PARITY_TAG_FLOOR is pinned to 0.0.0 for every scenario: unpinned, --post derives
# the floor from the stub's own release list, so a fixture's expected offender could fall
# below it and the scenario would pass for the wrong reason. Scenario 10 is the one that
# sets it deliberately.
run_tool() {  # mode dir path_mode(stubbed|empty) [EXTRA_ENV...]
  local mode="$1" dir="$2" path_mode="$3"; shift 3
  local path="$STUBBED_PATH"
  [ "$path_mode" = "empty" ] && path="$EMPTY_BIN"
  env PATH="$path" RELEASE_PARITY_TAG_FLOOR="${RELEASE_PARITY_TAG_FLOOR:-0.0.0}" \
    "$@" "$BASH_BIN" "$TOOL" "$mode" "$dir" 2>&1
}

CHANGELOG_2AND1='# Changelog

## 2.0.0 — 2026-01-02

content A

## 1.0.0 — 2026-01-01

content B
'
CHANGELOG_2ONLY='# Changelog

## 2.0.0 — 2026-01-02

content A
'

# ── 1. tag reachable from main with no published release → --post fails ───────────────────
d="$(mk_fixture f1-tag-no-release 2.0.0 "$CHANGELOG_2AND1")"
tag_head "$d" v1.0.0; tag_head "$d" v2.0.0
out="$(run_tool --post "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "1" "1. tag with no release → exit 1"
assert_contains "$out" "v2.0.0" "1. offending tag named"
assert_contains "$out" "no published" "1. reason names 'no published'"

# ── 2. VERSION with no matching tag → --post fails ─────────────────────────────────────────
d="$(mk_fixture f2-version-no-tag 3.0.0 "$CHANGELOG_2AND1")"
tag_head "$d" v1.0.0
out="$(run_tool --post "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "1" "2. VERSION with no matching tag → exit 1"
assert_contains "$out" "v3.0.0" "2. missing tag named"
assert_contains "$out" "no matching tag" "2. reason names 'no matching tag'"

# ── 3. VERSION equal to a burned version → --pre fails ─────────────────────────────────────
d="$(mk_fixture f3-burned 1.19.0 "$CHANGELOG_2AND1" "1.19.0 2026-09-08 withdrawn: test fixture")"
out="$(run_tool --pre "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.10.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "1" "3. VERSION equal to a burned version → exit 1"
assert_contains "$out" "1.19.0" "3. burned version named"

# ── 4. VERSION below the highest published release → --pre fails ──────────────────────────
d="$(mk_fixture f4-below-published 1.5.0 "$CHANGELOG_2AND1")"
out="$(run_tool --pre "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.18.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "1" "4. VERSION below highest published → exit 1"
assert_contains "$out" "1.18.0" "4. highest published version named"

# ── 5. release body carries an extra block the CHANGELOG section doesn't have → --post fails
d="$(mk_fixture f5-extra-block 2.0.0 "$CHANGELOG_2ONLY")"
tag_head "$d" v2.0.0
out="$(run_tool --post "$d" stubbed \
  STUB_RELEASE_LIST_JSON='[{"tagName":"v2.0.0","isDraft":false}]' \
  STUB_BODY_v2_0_0=$'content A\n\n## Unreleased\n\nsome leftover draft notes\n')"
rc=$?
assert_eq "$rc" "1" "5. body carrying an extra block → exit 1"
assert_contains "$out" "does not equal" "5. reason names body/CHANGELOG mismatch"

# ── 6. non-empty CHANGELOG.unreleased.md → --pre fails ─────────────────────────────────────
d="$(mk_fixture f6-unreleased 2.0.0 "$CHANGELOG_2AND1" "" "pending notes not yet folded in")"
out="$(run_tool --pre "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "1" "6. non-empty CHANGELOG.unreleased.md → exit 1"
assert_contains "$out" "CHANGELOG.unreleased.md" "6. names the offending file"

# ── 7. all-consistent fixture passes, both directions ──────────────────────────────────────
# 7a. --pre: VERSION is a still-unreleased bump above everything published/burned.
d="$(mk_fixture f7-consistent-pre 2.0.0 "$CHANGELOG_2AND1")"
out="$(run_tool --pre "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "0" "7a. consistent --pre fixture → exit 0"
assert_contains "$out" "passed" "7a. reports a pass"

# 7b. --post: VERSION already shipped, tagged, released, body matches its own section exactly.
d="$(mk_fixture f7-consistent-post 2.0.0 "$CHANGELOG_2AND1")"
tag_head "$d" v1.0.0; tag_head "$d" v2.0.0
out="$(run_tool --post "$d" stubbed \
  STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false},{"tagName":"v2.0.0","isDraft":false}]' \
  STUB_BODY_v2_0_0=$'content A\n')"
rc=$?
assert_eq "$rc" "0" "7b. consistent --post fixture → exit 0"
assert_contains "$out" "passed" "7b. reports a pass"

# 7c. --pre on an ordinary PR that does not bump anything: VERSION equals the newest
# published release, which is where main sits for most of its life (a release is cut AFTER
# merge). This is the case that makes the >= rule load-bearing: under queue #64's literal
# "fails when VERSION <= the highest published tag" this fixture, and therefore every
# non-bumping pull request, would be red.
d="$(mk_fixture f7-consistent-pre-nobump 2.0.0 "$CHANGELOG_2AND1")"
out="$(run_tool --pre "$d" stubbed STUB_RELEASE_LIST_JSON='[{"tagName":"v1.0.0","isDraft":false},{"tagName":"v2.0.0","isDraft":false}]')"
rc=$?
assert_eq "$rc" "0" "7c. VERSION equal to the newest published release → exit 0"
assert_contains "$out" "at or above" "7c. reports VERSION at or above the newest release"

# ── 8. gh unauthenticated → skip, exit 0 (never a false red with no GitHub creds) ──────────
d="$(mk_fixture f8-unauth 2.0.0 "$CHANGELOG_2AND1")"
out="$(run_tool --pre "$d" stubbed STUB_GH_AUTH_OK=0)"
rc=$?
assert_eq "$rc" "0" "8. gh unauthenticated → exit 0"
assert_contains "$out" "skip" "8. prints a skip line"

# ── 9. gh not on PATH at all → skip, exit 0 ─────────────────────────────────────────────────
out="$(run_tool --pre "$d" empty)"
rc=$?
assert_eq "$rc" "0" "9. gh missing → exit 0"
assert_contains "$out" "skip" "9. prints a skip line"

# ── 10. a tag below the floor has no release and is NOT an offender ────────────────────────
# The real repo carries eight tags (v1.0.0 through v1.4.2) cut before GitHub Releases were
# ever part of this project's flow; the oldest published release is v1.6.0. Without the floor
# --post is red on main forever over tags nobody will retroactively publish.
d="$(mk_fixture f10-below-floor 2.0.0 "$CHANGELOG_2AND1")"
tag_head "$d" v1.0.0; tag_head "$d" v2.0.0
out="$(RELEASE_PARITY_TAG_FLOOR=2.0.0 run_tool --post "$d" stubbed \
  STUB_RELEASE_LIST_JSON='[{"tagName":"v2.0.0","isDraft":false}]' \
  STUB_BODY_v2_0_0=$'content A\n')"
rc=$?
assert_eq "$rc" "0" "10. releaseless tag below the floor → exit 0"
assert_contains "$out" "predate the release convention" "10. says why it was not checked"
assert_contains "$out" "1 tag(s) below" "10. counts the skipped tag"

echo ""
if [ "$ASSERT_FAILS" -eq 0 ]; then
  echo "ok - all test-release-parity.sh assertions passed"
  exit 0
fi
echo "FAIL - $ASSERT_FAILS assertion(s) failed"
exit 1
