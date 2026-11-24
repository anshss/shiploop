#!/usr/bin/env bash
# Regression: a direct push to main that breaks a hub-context check must be refused BEFORE it
# lands, not discovered later as silent red on origin/main. CI's hub-context-tests job runs the
# list only AFTER the push and nothing consumes its result, so the pre-push guard in
# tools/hub-context-pre-push.sh is the only local signal a direct-to-main push gets.
#
# Contract exercised (checker takes "<localsha> <remoteref> <remotesha>" as argv, or pre-push
# stdin when no args are given):
#   failing doc-guard + README-only diff + refs/heads/main -> REFUSED, assertion named
#   clean list      + doc-path diff   + refs/heads/main    -> allowed
#   kill switch GOVERN_PRE_PUSH_HUB_TESTS=0                -> skipped (not even run)
#   failing guard   + non-main remoteref                   -> allowed (feature branches PR-gated)
#   failing guard   + diff on a non-gated path             -> allowed (path gate)
#   failing guard   + structural diff (templates/)         -> REFUSED (full-list scope)
#   quarantined guard failing                              -> reported, NOT gating
#   guard exiting 77 (hub resolution broken)               -> FAILURE, as CI treats it
#   listed but missing guard file                           -> FAILURE, as CI treats it
#   doc-subset entry absent from the main list              -> REFUSED (loud list drift)
#   VERSION/CHANGELOG.md in the diff                        -> check-version-consistency runs
#   stdin mode (no argv)                                    -> same verdicts as argv mode
# The hub .githooks/pre-push wrapper gets the same verdicts via stdin and chains a default-path
# hook. From a real hub checkout, the doc-only path (--run-doc-checks) must finish under 30s.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/assert.sh"
set +e   # assert.sh sets -e; we drive the guard and inspect exit codes ourselves

CHECKER="$DIR/../../../tools/hub-context-pre-push.sh"
[ -f "$CHECKER" ] || { echo "SKIP: hub-context-pre-push.sh not found" >&2; exit 0; }

# mk_hub_fixture: a throwaway hub-shaped git repo with a one-test list whose pass/fail is
# controlled by a marker file, the doc subset listing that same test, and a stubbed
# check-version-consistency gated by its own marker. Commits: parent (remote main tip)
# -> child (local main tip), a README edit so the doc path is exercised by default.
# Prints the fixture root via FX; refs via REMOTE_TIP / LOCAL_TIP.
mk_hub_fixture() {
  FX="$(mktemp -d "${TMPDIR:-/tmp}/hubctx-test.XXXXXX")"
  mkdir -p "$FX/tools" "$FX/templates/govern/test"
  cp "$CHECKER" "$FX/tools/hub-context-pre-push.sh"
  chmod +x "$FX/tools/hub-context-pre-push.sh"
  cat >"$FX/templates/govern/test/test-fake-hub-guard.sh" <<'FAKE'
#!/usr/bin/env bash
if [ -f "$(dirname "$0")/../../../MAKE_FAKE_FAIL" ]; then
  echo "assert_eq expected actual: fake hub guard failure"
  exit 1
fi
exit 0
FAKE
  chmod +x "$FX/templates/govern/test/test-fake-hub-guard.sh"
  printf '# fixture list\ntest-fake-hub-guard\n' > "$FX/tools/hub-context-tests.txt"
  printf '# fixture doc subset\ntest-fake-hub-guard\n' > "$FX/tools/hub-context-doc-tests.txt"
  cat >"$FX/tools/check-version-consistency.sh" <<'VERSION'
#!/usr/bin/env bash
[ -f "$(dirname "$0")/../MAKE_VERSION_FAIL" ] && exit 1
exit 0
VERSION
  chmod +x "$FX/tools/check-version-consistency.sh"
  printf 'v1\n' > "$FX/README.md"
  git -C "$FX" init -q
  git -C "$FX" -c user.email=you@test -c user.name=you add -A
  git -C "$FX" -c user.email=you@test -c user.name=you commit -qm base
  printf 'v2\n' > "$FX/README.md"
  git -C "$FX" -c user.email=you@test -c user.name=you commit -qam "doc change"
  REMOTE_TIP="$(git -C "$FX" rev-parse HEAD~1)"
  LOCAL_TIP="$(git -C "$FX" rev-parse HEAD)"
}
cleanup_fixture() { [ -n "${FX:-}" ] && rm -rf "$FX"; FX=""; }
trap cleanup_fixture EXIT

# run_guard MODE [REMOTE_REF]: drive the fixture's checker against a main push; sets $rc / $err.
run_guard() {
  local mode="$1" ref="${2:-refs/heads/main}"
  if [ "$mode" = "argv" ]; then
    err="$(cd "$FX" && env -u GOVERN_PRE_PUSH_HUB_TESTS bash tools/hub-context-pre-push.sh \
      "$LOCAL_TIP" "$ref" "$REMOTE_TIP" 2>&1 >/dev/null)"; rc=$?
  else
    err="$(cd "$FX" && env -u GOVERN_PRE_PUSH_HUB_TESTS \
      printf 'refs/heads/main %s %s %s\n' "$LOCAL_TIP" "$ref" "$REMOTE_TIP" \
      | bash tools/hub-context-pre-push.sh 2>&1 >/dev/null)"; rc=$?
  fi
}

# ── Refusal: a failing doc guard blocks the doc-only main push and names the assertion ──
mk_hub_fixture
touch "$FX/MAKE_FAKE_FAIL"
run_guard argv
assert_eq "$rc" "1" "failing doc guard REFUSES the doc-only main push"
assert_contains "$err" "test-fake-hub-guard FAILED" "refusal names the failing assertion"
assert_contains "$err" "REFUSED" "refusal says the push was refused"

# ── Clean doc push: a green subset lets the push through ──
rm -f "$FX/MAKE_FAKE_FAIL"
run_guard argv
assert_eq "$rc" "0" "green doc guards allow the clean doc push"

# ── Kill switch: skipped without running anything (the failing fixture would refuse) ──
touch "$FX/MAKE_FAKE_FAIL"
err="$(cd "$FX" && GOVERN_PRE_PUSH_HUB_TESTS=0 bash tools/hub-context-pre-push.sh \
  "$LOCAL_TIP" refs/heads/main "$REMOTE_TIP" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "0" "GOVERN_PRE_PUSH_HUB_TESTS=0 skips the check"
assert_contains "$err" "skipped" "kill switch says it skipped"

# ── Non-main targets are never checked (feature branches are PR-gated) ──
run_guard argv refs/heads/sl-a1b2c3d4e5f6
assert_eq "$rc" "0" "non-main target is never checked (failing guard notwithstanding)"
cleanup_fixture

# ── Path gate: a diff that touches no gated path does not run any check ──
mk_hub_fixture
touch "$FX/MAKE_FAKE_FAIL"
mkdir -p "$FX/random" && printf 'x\n' > "$FX/random/notes.txt"
git -C "$FX" add -A
git -C "$FX" -c user.email=you@test -c user.name=you commit -qm "non-gated paths only"
REMOTE_TIP="$(git -C "$FX" rev-parse HEAD~1)"; LOCAL_TIP="$(git -C "$FX" rev-parse HEAD)"
run_guard argv
assert_eq "$rc" "0" "diff on non-gated paths does not run any check"

# ── Structural scope: a templates/ diff runs the FULL list and still refuses on red ──
mk_hub_fixture
touch "$FX/MAKE_FAKE_FAIL"
mkdir -p "$FX/templates/govern" && printf 'x\n' > "$FX/templates/govern/something.sh"
git -C "$FX" add -A
git -C "$FX" -c user.email=you@test -c user.name=you commit -qm "structural change"
REMOTE_TIP="$(git -C "$FX" rev-parse HEAD~1)"; LOCAL_TIP="$(git -C "$FX" rev-parse HEAD)"
run_guard argv
assert_eq "$rc" "1" "structural diff (templates/) runs the full list and refuses on red"
assert_contains "$err" "test-fake-hub-guard FAILED" "structural refusal names the failing assertion"
cleanup_fixture

# ── Quarantine: a failing quarantined guard is reported but not gating (CI parity) ──
mk_hub_fixture
touch "$FX/MAKE_FAKE_FAIL"
printf '# fixture doc subset\n!test-fake-hub-guard\n' > "$FX/tools/hub-context-doc-tests.txt"
run_guard argv
assert_eq "$rc" "0" "failing QUARANTINED doc guard does not gate the push"
assert_contains "$err" "QUARANTINED" "quarantine failure is still reported"
cleanup_fixture

# ── Exit 77 (hub resolution broken) is a FAILURE, as CI treats it ──
mk_hub_fixture
printf '#!/usr/bin/env bash\nexit 77\n' > "$FX/templates/govern/test/test-fake-hub-guard.sh"
run_guard argv
assert_eq "$rc" "1" "exit 77 from a listed guard FAILS the push (CI parity: a skip is not a pass)"
assert_contains "$err" "SKIPPED (exit 77)" "the 77 refusal explains why a skip counts as failure"
cleanup_fixture

# ── Listed but missing guard file fails, as CI treats it ──
mk_hub_fixture
rm "$FX/templates/govern/test/test-fake-hub-guard.sh"
run_guard argv
assert_eq "$rc" "1" "listed guard with no file FAILS the push (CI parity)"
assert_contains "$err" "no such test file" "missing-guard refusal names the list"
cleanup_fixture

# ── List drift: a doc-subset entry absent from the main list is a loud refusal ──
mk_hub_fixture
printf '# fixture doc subset\ntest-not-in-main-list\n' > "$FX/tools/hub-context-doc-tests.txt"
run_guard argv
assert_eq "$rc" "1" "doc subset naming an unlisted test REFUSES the push (loud drift)"
assert_contains "$err" "must be a subset of the main list" "drift refusal names the subset rule"
cleanup_fixture

# ── VERSION rollback: the diff stays doc-scope and check-version-consistency is wired in ──
mk_hub_fixture
printf '1.0.0\n' > "$FX/VERSION"
git -C "$FX" add -A
git -C "$FX" -c user.email=you@test -c user.name=you commit -qm "version change"
REMOTE_TIP="$(git -C "$FX" rev-parse HEAD~1)"; LOCAL_TIP="$(git -C "$FX" rev-parse HEAD)"
touch "$FX/MAKE_VERSION_FAIL"
run_guard argv
assert_eq "$rc" "1" "VERSION diff runs check-version-consistency and refuses on red"
assert_contains "$err" "check-version-consistency.sh FAILED" "version refusal names the checker"
rm -f "$FX/MAKE_VERSION_FAIL"
run_guard argv
assert_eq "$rc" "0" "VERSION diff with a green version check is allowed"
cleanup_fixture

# ── stdin mode (git pre-push wiring): same verdicts with refs on stdin ──
mk_hub_fixture
touch "$FX/MAKE_FAKE_FAIL"
run_guard stdin
assert_eq "$rc" "1" "stdin mode refuses a failing main push like argv mode"

rm -f "$FX/MAKE_FAKE_FAIL"
run_guard stdin
assert_eq "$rc" "0" "stdin mode allows a clean main push like argv mode"
cleanup_fixture

# ── Hub .githooks/pre-push wrapper: forwards stdin to the checker and refuses on red ──
WRAPPER="$DIR/../../../.githooks/pre-push"
if [ -f "$WRAPPER" ]; then
  mk_hub_fixture
  touch "$FX/MAKE_FAKE_FAIL"
  mkdir -p "$FX/.githooks"
  cp "$WRAPPER" "$FX/.githooks/pre-push"
  chmod +x "$FX/.githooks/pre-push"
  # The wrapper derives the checker from its own location: mirror the real layout.
  err="$(cd "$FX" && env -u GOVERN_PRE_PUSH_HUB_TESTS \
    printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_TIP" "$REMOTE_TIP" \
    | bash .githooks/pre-push refs/heads/main origin 2>&1 >/dev/null)"; rc=$?
  assert_eq "$rc" "1" "hub .githooks/pre-push wrapper refuses a red main push"
  assert_contains "$err" "REFUSED" "wrapper surfaces the checker's refusal"

  # Chaining: a default-path hook still runs (and its refusal still blocks) alongside the guard.
  cat >"$FX/.git/hooks/pre-push" <<'LEGACY'
#!/usr/bin/env bash
echo "legacy hook ran" >&2
exit 0
LEGACY
  chmod +x "$FX/.git/hooks/pre-push"
  rm -f "$FX/MAKE_FAKE_FAIL"
  err="$(cd "$FX" && env -u GOVERN_PRE_PUSH_HUB_TESTS \
    printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_TIP" "$REMOTE_TIP" \
    | bash .githooks/pre-push refs/heads/main origin 2>&1 >/dev/null)"; rc=$?
  assert_eq "$rc" "0" "wrapper allows a clean push with a default-path hook present"
  assert_contains "$err" "legacy hook ran" "wrapper chains the default-path pre-push after its check"

  cat >"$FX/.git/hooks/pre-push" <<'LEGACY'
#!/usr/bin/env bash
exit 1
LEGACY
  err="$(cd "$FX" && env -u GOVERN_PRE_PUSH_HUB_TESTS \
    printf 'refs/heads/main %s refs/heads/main %s\n' "$LOCAL_TIP" "$REMOTE_TIP" \
    | bash .githooks/pre-push refs/heads/main origin 2>&1 >/dev/null)"; rc=$?
  assert_eq "$rc" "1" "wrapper propagates a chained default-path hook's refusal"
  cleanup_fixture
else
  echo "note: hub .githooks/pre-push not present in this checkout, wrapper cases skipped" >&2
fi

# ── Push budget: from a real hub checkout, the doc-only path must finish in under 30s ──
# --run-doc-checks is exactly what a doc-only push runs (the doc-guard subset plus the version
# consistency checker), so this times the real cost of the path the hook takes on the ticket's
# incident shape (a README push).
HUB="$(cd "$DIR/../../.." && pwd)"
if [ -f "$HUB/tools/hub-context-tests.txt" ] && [ -f "$HUB/tools/hub-context-doc-tests.txt" ]; then
  start=$(python3 -c 'import time; print(time.time())')
  cd "$HUB" && env -u GOVERN_PRE_PUSH_HUB_TESTS bash tools/hub-context-pre-push.sh --run-doc-checks >/dev/null 2>&1
  guard_rc=$?
  end=$(python3 -c 'import time; print(time.time())')
  elapsed="$(python3 -c "print(f'{$end-$start:.1f}')")"
  assert_eq "$([ "$guard_rc" = "0" ] && echo green || echo red)" "green" \
    "budget: the doc-only path passes against the current checkout"
  under="$(python3 -c "print('yes' if $end-$start < 30 else 'no')")"
  assert_eq "$under" "yes" "budget: the doc-only path finishes in under 30s (took ${elapsed}s)"
  cd "$DIR" || exit 1
else
  echo "SKIP (77): not running from a hub checkout, push-budget cases need the real lists" >&2
  exit 77
fi

assert_done
