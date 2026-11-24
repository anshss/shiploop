#!/usr/bin/env bash
# Repo-wide SHAPE guard for the pipefail-SIGPIPE trap: a live pipeline whose CONSUMER stops
# reading early (`grep -q`, `grep -m<N>`, `head`) can SIGPIPE the producer once its output
# exceeds the pipe buffer (~64KB). Under `set -o pipefail` that turns a correct match into an
# exit-141 failure (fatal under `set -e`, or an inverted `if` without it). Every such site in
# templates/ has been rewritten to a here-string or a full-drain slice (sed -n); this test
# flags any `producer | grep ...-q...` and `producer | head ...` line inside a pipefail
# script, and fails on any hit not on the explicit allowlist
# (govern/test/pipefail-shape-allowlist.txt: file + the exact trimmed line, so a line that
# changes text re-earns review even when its line number drifts).
#
# The allowlist is the contract. Every entry needs a real reason: a proven-small producer or
# a test fixture whose input is test-controlled and small by construction. Never add a row to
# make a violation disappear without one.
#
# Also proves the mechanism itself, both ways:
#   - the scan goes RED on a synthetic offender file containing both shapes (a guard that
#     only ever reports clean is a guard nobody re-checks);
#   - on a >64KB payload under pipefail, the OLD `printf | grep -q` shape reproduces exit 141
#     (negative control: the failure mode is real, not theoretical), while the fixed shapes
#     (a here-string grep and a full-drain `sed -n '1p'` slice) return 0 and still match.
# This test asserts on the HUB template tree, so it runs only from a hub checkout (suite
# convention: exit 77 elsewhere; listed in tools/hub-context-tests.txt).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Suite convention for hub-asserting tests: resolve the hub as the test file's own
# $DIR/../../.. and exit 77 when that is not a hub checkout. In a scaffolded workspace this
# resolves to the workspace root, whose scripts/ tree is an INSTALLED copy (CI's copy step
# carries only *.sh, so the allowlist would be missing there anyway) - this test is
# hub-context-only and runs from the checkout in its own CI job.
HUB_ROOT="$(cd "$DIR/../../.." && pwd)"
ALLOWLIST="$DIR/pipefail-shape-allowlist.txt"
if [[ ! -f "$HUB_ROOT/templates/tail.sh" ]]; then
  echo "not a hub checkout (no templates/ tree) - SKIP"
  exit 77
fi
TEMPLATES_ROOT="$HUB_ROOT/templates"

# The scan itself, reusable so the red-path proof below can call it against a scratch tree.
# $1 = root dir to scan; $2 = allowlist file. Prints one "rel<TAB>trimmed-line" per
# unallowlisted offender; prints nothing on a clean tree.
pfg::scan() {
  local scanroot="$1" allow="$2" f rel line trimmed
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    rel="${f#"$scanroot"/}"
    # This guard's own source embeds the offending SHAPES as synthetic-fixture text (to prove
    # the scan goes red); that text is not a live pipefail site, so exclude this file by name.
    # The exclusion does NOT cover the scratch tree the red-path proof scans below.
    [[ "$rel" == "govern/test/test-pipefail-shape-guard.sh" ]] && continue
    grep -qF 'pipefail' "$f" 2>/dev/null || continue
    # Early-exit consumer, class 1: `| grep` carrying -q / -m<N> (stops at the Nth match), or
    # an -Eq-style flag, anything that can close its read end before the producer is done.
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      trimmed="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$line")"
      [[ "$trimmed" == \#* ]] && continue
      if [[ -f "$allow" ]] && grep -qxF "$(printf '%s\t%s' "$rel" "$trimmed")" "$allow" 2>/dev/null; then
        continue
      fi
      printf '%s\t%s\n' "$rel" "$trimmed"
    done < <(grep -nE '(^|[^|])\|[[:space:]]*grep\b' "$f" 2>/dev/null \
              | grep -E -- '-[a-zA-Z]*q[a-zA-Z]*\b|-[a-zA-Z]*m[[:space:]]*[0-9]|\bEq\b' \
              | sed -E 's/^[0-9]+://')
    # Early-exit consumer, class 2: `| head` (line- or byte-bounded; both stop after N units).
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      trimmed="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$line")"
      [[ "$trimmed" == \#* ]] && continue
      if [[ -f "$allow" ]] && grep -qxF "$(printf '%s\t%s' "$rel" "$trimmed")" "$allow" 2>/dev/null; then
        continue
      fi
      printf '%s\t%s\n' "$rel" "$trimmed"
    # `(^|[^|])\|` (here and above): a bare `\|` would also match the SECOND `|` of a `||`
    # logical-or, misreading a fully independent, already-safe command as a live-pipe offender.
    # Require the matched `|` to be preceded by start-of-line or a non-pipe character.
    done < <(grep -nE '(^|[^|])\|[[:space:]]*head\b' "$f" 2>/dev/null | sed -E 's/^[0-9]+://')
  done < <(find "$scanroot" -type f -name '*.sh')
}

# 1. the live scan over templates/, against the real allowlist.
hits="$(pfg::scan "$TEMPLATES_ROOT" "$ALLOWLIST")"
if [[ -z "$hits" ]]; then
  echo "ok - no unallowlisted pipefail-SIGPIPE shape in templates/"
else
  ASSERT_FAILS=$((ASSERT_FAILS + 1))
  echo "not ok - unallowlisted pipefail-SIGPIPE shape(s): rewrite (bias) or add a JUSTIFIED allowlist row:" >&2
  while IFS=$'\t' read -r fl l; do
    printf '    %s: %s\n' "$fl" "$l" >&2
  done <<< "$hits"
fi

# 2. prove the scan goes RED on a synthetic offender (scratch tree, no allowlist).
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/offender.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body="$(some_producer)"
if printf '%s' "$body" | grep -q 'NEEDLE'; then
  echo hit
fi
big_listing | head -n 5
EOF
redhits="$(pfg::scan "$T" "/nonexistent-allowlist")"
n="$(grep -c . <<< "$redhits" || true)"
assert_eq "$n" "2" "scan goes RED on a synthetic offender and catches BOTH shapes (grep -q and head)"

# 3. prove the allowlist suppresses one exact line, and ONLY that line.
printf '%s\t%s\n' "offender.sh" "if printf '%s' \"\$body\" | grep -q 'NEEDLE'; then" > "$T/allowlist.txt"
partial="$(pfg::scan "$T" "$T/allowlist.txt")"
assert_contains "$partial" "head -n 5" "the unlisted head site still reports"
if grep -qF "grep -q 'NEEDLE'" <<< "$partial"; then
  ASSERT_FAILS=$((ASSERT_FAILS + 1))
  echo "not ok - allowlisting one exact line did not suppress it" >&2
else
  echo "ok - allowlisting one exact line suppresses only that line"
fi

# 4. the mechanism, live: >64KB payload, match in the first bytes, under pipefail.
big="$(printf 'NEEDLE\n%*s' 2000000 '')"
rc_old=0
( set -o pipefail; printf '%s' "$big" | grep -q NEEDLE ) || rc_old=$?
assert_eq "$rc_old" "141" "OLD shape (printf | grep -q) reproduces SIGPIPE 141 on a >64KB payload (negative control)"
rc_new=0
( set -o pipefail; grep -q NEEDLE <<< "$big" ) || rc_new=$?
assert_eq "$rc_new" "0" "fixed shape (grep -q on a here-string) matches cleanly on the same payload"
rc_drain=0
drained="$( set -o pipefail; printf '%s' "$big" | sed -n '1p' )" || rc_drain=$?
assert_eq "$rc_drain" "0" "full-drain slice (sed -n '1p') never SIGPIPEs the producer"
assert_eq "$drained" "NEEDLE" "full-drain slice still returns the first line"

assert_done
