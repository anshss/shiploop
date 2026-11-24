#!/usr/bin/env bash
# Regression for tools/make-release.sh.
#
# Drives the REAL script end to end inside fixture git repos: origin is a local bare repo
# (git push works with no network), and `gh` is a stateful stub earlier on PATH that records
# release bodies and replays them to `release view`/`release list`, so the landing path
# (commit, tag, push, release create, parity --post, self-heal) is exercised the same way
# tools/check-release-parity.sh's stub does for the checker. The script's first real run
# against the live releases page is the final integration step beyond these fixtures.
#
# Usage: bash tools/test/test-make-release.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$DIR/.." && pwd)"
# The section/body trim rule the byte-match assertion reuses is the shared lib itself, so a
# drift between make-release.sh and check-release-parity.sh fails this test by construction.
# shellcheck source=../lib/release-text.sh
. "$TOOLS/lib/release-text.sh"

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
dump_on_fail() {  # rc output label: print the captured output when the run did not exit 0
  if [ "$1" -ne 0 ]; then
    printf '%s\n%s\n' "----- output ($3) -----" "$2"
  fi
}

# ---------------------------------------------------------------------------
# Stateful gh stub: release list/view replay recorded state; create/edit record it.
# ---------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
STATE="${STUB_STATE:?STUB_STATE not set}"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  [ "${STUB_GH_AUTH_OK:-1}" = "1" ] && exit 0 || exit 1
fi
body_path() {
  printf '%s/%s_body' "$STATE" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
}
if [ "${1:-}" = "release" ] && [ "${2:-}" = "list" ]; then
  if [ -f "$STATE/tags" ]; then
    jq -Rn 'reduce inputs as $t ([]; . + [{"tagName": $t, "isDraft": false}])' "$STATE/tags"
  else
    printf '[]'
  fi
  exit 0
fi
parse_create_or_edit() {  # sets TAG and NOTES_FILE from "$@"
  TAG=""
  NOTES_FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --notes-file) NOTES_FILE="$2"; shift ;;
      --title) shift ;;
      --*) ;;
      *) [ -z "$TAG" ] && TAG="$1" ;;
    esac
    shift
  done
}
if [ "${1:-}" = "release" ] && [ "${2:-}" = "create" ]; then
  shift 2
  parse_create_or_edit "$@"
  if [ "${STUB_CORRUPT_BODY:-0}" = "1" ] && [ -n "$NOTES_FILE" ]; then
    tail -n +2 "$NOTES_FILE" > "$(body_path "$TAG")"
  else
    cat "$NOTES_FILE" > "$(body_path "$TAG")"
  fi
  grep -qxF "$TAG" "$STATE/tags" 2>/dev/null || printf '%s\n' "$TAG" >> "$STATE/tags"
  printf '%s\n' "create $TAG" >> "$STATE/calls"
  exit 0
fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "edit" ]; then
  shift 2
  parse_create_or_edit "$@"
  cat "$NOTES_FILE" > "$(body_path "$TAG")"
  printf '%s\n' "edit $TAG" >> "$STATE/calls"
  exit 0
fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then
  f="$(body_path "${3:-}")"
  [ -f "$f" ] || exit 1
  # gh's -q .body prints the body text raw, not JSON-encoded; replay it the same way.
  cat "$f"
  exit 0
fi
echo "gh-stub: unhandled invocation: $*" >&2
exit 9
GHSTUB
chmod +x "$STUB_BIN/gh"
STUBBED_PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# Fixture: origin is a local bare repo, work is a clone on main holding a mini hub tree
# with the REAL tools copied in (make-release needs the two checkers, the hash generator
# and scaffold.sh's mechanism map; nothing here reaches the network).
# ---------------------------------------------------------------------------
CHANGELOG_BODY=$(printf '# Changelog\n\n## 1.1.0 - 2026-11-25\n\n- the release ceremony is one verified step\n- body extraction reuses the checker trim rule  \n\n\n## 1.0.0 - 2026-11-01\n\n- initial\n')
# Same CHANGELOG minus the 1.1.0 section, for the missing-section refusal.
CHANGELOG_NO_SECTION=$(printf '# Changelog\n\n## 1.0.0 - 2026-11-01\n\n- initial\n')

mk_fixture() {  # name changelog -> echoes the work clone path
  local name="$1" changelog="$2"
  local seed="$WORK/$name-seed" bare="$WORK/$name-origin.git" work="$WORK/$name"
  mkdir -p "$seed/templates/lib" "$seed/tools/lib" "$seed/.claude-plugin"
  printf '1.0.0' > "$seed/VERSION"
  printf '%s\n' "$changelog" > "$seed/CHANGELOG.md"
  printf '{"name": "fixture", "version": "1.0.0"}\n' > "$seed/.claude-plugin/plugin.json"
  printf '{"plugins": [{"name": "fixture", "version": "1.0.0"}]}\n' > "$seed/.claude-plugin/marketplace.json"
  : > "$seed/templates/lib/purge.txt"
  cp "$TOOLS/make-release.sh" "$TOOLS/check-version-consistency.sh" \
     "$TOOLS/check-release-parity.sh" "$TOOLS/gen-mechanism-hashes.sh" "$seed/tools/"
  cp "$TOOLS/lib/release-text.sh" "$seed/tools/lib/"
  cp "$TOOLS/../scaffold.sh" "$seed/scaffold.sh"
  ( cd "$seed" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name t \
      && git add -A \
      && git commit -q -m seed )
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git -C "$seed" push -q "$bare" main
  git clone -q "$bare" "$work"
  git -C "$work" config user.email t@t
  git -C "$work" config user.name t
  printf '%s' "$work"
}

mk_state() {  # state dir with one seeded published release (v1.0.0)
  local state="$1"
  mkdir -p "$state"
  printf 'v1.0.0\n' > "$state/tags"
  : > "$state/calls"
}

run_mr() {  # workdir state [args...] -> runs the FIXTURE's copy, so ROOT resolves into the fixture
  local workdir="$1" state="$2"; shift 2
  ( cd "$workdir" \
      && STUB_STATE="$state" MAKE_RELEASE_POST_WAIT=0 MAKE_RELEASE_POST_POLL=1 \
         PATH="$STUBBED_PATH" bash tools/make-release.sh "$@" 2>&1 )
}

# ── 1. happy path: mutations, commit, tag, push, release, parity --post green ──────────────
work="$(mk_fixture f1-happy "$CHANGELOG_BODY")"
state="$WORK/f1-state"
mk_state "$state"
out="$(run_mr "$work" "$state" 1.1.0 --headline "one verified step")"
rc=$?
dump_on_fail "$rc" "$out" "1a"; assert_eq "$rc" "0" "1a. full ceremony → exit 0"
assert_eq "$(cat "$work/VERSION")" "1.1.0" "1b. VERSION bumped"
assert_eq "$(jq -r .version "$work/.claude-plugin/plugin.json")" "1.1.0" "1c. plugin.json bumped"
assert_eq "$(jq -r '.plugins[0].version' "$work/.claude-plugin/marketplace.json")" "1.1.0" "1d. marketplace.json bumped"
assert_eq "$(git -C "$work" rev-parse HEAD)" "$(git -C "$WORK/f1-happy-origin.git" rev-parse main)" "1e. main pushed to origin"
assert_eq "$(git -C "$work" rev-parse HEAD)" "$(git -C "$work" rev-parse refs/tags/v1.1.0^{commit})" "1f. tag v1.1.0 on the release commit"
case "$(git -C "$work" log -1 --format=%s)" in
  "release: 1.1.0, one verified step") printf 'ok   - 1g. commit subject is release: <version>, <headline>\n' ;;
  *) printf 'FAIL - 1g. commit subject is %s\n' "$(git -C "$work" log -1 --format=%s)"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
esac
assert_contains "$(cat "$state/calls")" "create v1.1.0" "1h. gh release create called for v1.1.0"
# The byte-match: the body gh received equals the CHANGELOG section under the shared trim
# rule, character for character (the fixture section carries trailing whitespace and blank
# lines, so a re-derived trim instead of the shared one fails here).
expected_body="$(changelog_section 1.1.0 "$work/CHANGELOG.md" | normalize_release_text)"
if cmp -s <(printf '%s\n' "$expected_body") "$state/v1_1_0_body"; then
  printf 'ok   - 1i. release body byte-matches the CHANGELOG section under the shared trim rule\n'
else
  printf 'FAIL - 1i. release body differs from the normalized CHANGELOG section\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi
post_out="$( ( cd "$work" && STUB_STATE="$state" PATH="$STUBBED_PATH" \
  bash "$TOOLS/check-release-parity.sh" --post "$work" ) 2>&1 )"
post_rc=$?
dump_on_fail "$post_rc" "$post_out" "1j. independent parity --post"
assert_eq "$post_rc" "0" "1j. independent parity --post over the landed fixture → exit 0"

# ── 2. --dry-run mutates nothing ───────────────────────────────────────────────────────────
work="$(mk_fixture f2-dry "$CHANGELOG_BODY")"
state="$WORK/f2-state"
mk_state "$state"
head_before="$(git -C "$work" rev-parse HEAD)"
out="$(run_mr "$work" "$state" 1.1.0 --headline "one verified step" --dry-run)"
rc=$?
assert_eq "$rc" "0" "2a. --dry-run → exit 0"
assert_eq "$(cat "$work/VERSION")" "1.0.0" "2b. VERSION untouched"
assert_eq "$(jq -r .version "$work/.claude-plugin/plugin.json")" "1.0.0" "2c. plugin.json untouched"
assert_eq "$(git -C "$work" status --porcelain | wc -l | tr -d ' ')" "0" "2d. working tree still clean"
assert_eq "$(git -C "$work" rev-parse HEAD)" "$head_before" "2e. no commit added"
git -C "$work" rev-parse -q --verify refs/tags/v1.1.0 >/dev/null \
  && { printf 'FAIL - 2f. --dry-run tagged v1.1.0\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1)); } \
  || printf 'ok   - 2f. no tag created\n'
case "$(cat "$state/calls")" in
  *create*) printf 'FAIL - 2g. --dry-run created a release\n%s\n' "$(cat "$state/calls")"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  *) printf 'ok   - 2g. no release created\n' ;;
esac
assert_contains "$out" "dry-run -" "2h. dry-run explains what the real run would do"

# ── 3. stale origin refuses with a named error, nothing mutated ────────────────────────────
work="$(mk_fixture f3-stale "$CHANGELOG_BODY")"
state="$WORK/f3-state"
mk_state "$state"
head_before="$(git -C "$work" rev-parse HEAD)"
# main moves on the remote out from under the fixture work tree (a merged train PR).
other="$WORK/f3-other"
git clone -q "$WORK/f3-stale-origin.git" "$other"
git -C "$other" config user.email t@t
git -C "$other" config user.name t
( cd "$other" && printf 'x' > moved.txt && git add -A && git commit -q -m "train PR" && git push -q origin main )
out="$(run_mr "$work" "$state" 1.1.0 --headline "one verified step")"
rc=$?
assert_eq "$rc" "1" "3a. stale origin → exit 1"
assert_contains "$out" "stale origin" "3b. refusal names the staleness"
assert_eq "$(cat "$work/VERSION")" "1.0.0" "3c. VERSION untouched"
assert_eq "$(git -C "$work" rev-parse HEAD)" "$head_before" "3d. no commit added"

# ── 4. version not strictly greater refuses ────────────────────────────────────────────────
work="$(mk_fixture f4-notgreater "$CHANGELOG_BODY")"
state="$WORK/f4-state"
mk_state "$state"
out="$(run_mr "$work" "$state" 1.0.0 --headline "no bump")"
rc=$?
assert_eq "$rc" "1" "4a. version equal to VERSION → exit 1"
assert_contains "$out" "strictly greater" "4b. refusal names the version rule"
assert_eq "$(cat "$work/VERSION")" "1.0.0" "4c. VERSION untouched"

# ── 5. missing CHANGELOG section refuses before any mutation lands ─────────────────────────
work="$(mk_fixture f5-nosection "$CHANGELOG_NO_SECTION")"
state="$WORK/f5-state"
mk_state "$state"
head_before="$(git -C "$work" rev-parse HEAD)"
out="$(run_mr "$work" "$state" 1.1.0 --headline "prose not written yet")"
rc=$?
assert_eq "$rc" "1" "5a. missing CHANGELOG section → exit 1"
assert_contains "$out" "no section for 1.1.0" "5b. refusal names the missing section"
assert_eq "$(git -C "$work" rev-parse HEAD)" "$head_before" "5c. no commit added"

# ── 6. self-heal: a corrupted release body is rewritten from the section ───────────────────
work="$(mk_fixture f6-heal "$CHANGELOG_BODY")"
state="$WORK/f6-state"
mk_state "$state"
out="$(STUB_CORRUPT_BODY=1 run_mr "$work" "$state" 1.1.0 --headline "one verified step")"
rc=$?
dump_on_fail "$rc" "$out" "6a"; assert_eq "$rc" "0" "6a. body mismatch self-heals → exit 0"
assert_contains "$(cat "$state/calls")" "edit v1.1.0" "6b. gh release edit rewrote the body"
expected_body="$(changelog_section 1.1.0 "$work/CHANGELOG.md" | normalize_release_text)"
if cmp -s <(printf '%s\n' "$expected_body") "$state/v1_1_0_body"; then
  printf 'ok   - 6c. healed body byte-matches the CHANGELOG section\n'
else
  printf 'FAIL - 6c. healed body differs from the normalized CHANGELOG section\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1))
fi
assert_contains "$out" "self-healing" "6d. the heal is announced, not silent"

# ── 7. gh unauthenticated refuses loud (no skip like the checkers) ─────────────────────────
work="$(mk_fixture f7-noauth "$CHANGELOG_BODY")"
state="$WORK/f7-state"
mk_state "$state"
out="$(STUB_GH_AUTH_OK=0 run_mr "$work" "$state" 1.1.0 --headline "one verified step")"
rc=$?
assert_eq "$rc" "1" "7a. gh unauthenticated → exit 1 (never a skip)"
assert_contains "$out" "gh is not authenticated" "7b. refusal names the auth requirement"

# ── 8. missing --headline is a usage error ─────────────────────────────────────────────────
work="$(mk_fixture f8-noheadline "$CHANGELOG_BODY")"
state="$WORK/f8-state"
mk_state "$state"
out="$(run_mr "$work" "$state" 1.1.0)"
rc=$?
assert_eq "$rc" "2" "8a. missing --headline → usage exit 2"
assert_contains "$out" "usage:" "8b. usage line printed"

echo ""
if [ "$ASSERT_FAILS" -eq 0 ]; then
  echo "ok - all test-make-release.sh assertions passed"
  exit 0
fi
echo "FAIL - $ASSERT_FAILS assertion(s) failed"
exit 1
