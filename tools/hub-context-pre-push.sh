#!/usr/bin/env bash
# Hub-context pre-push guard: refuse a direct push to main that breaks a hub-context test BEFORE
# it lands, instead of leaving origin/main red with no signal. CI's hub-context-tests job runs
# the list (tools/hub-context-tests.txt) only AFTER the push and nothing consumes its result, so
# a doc-only push that breaks a vocab guard used to sit red until someone looked at CI by hand.
#
# Fired only when ALL of these hold:
#   - the push targets refs/heads/main (feature branches are PR-gated; never checked here)
#   - GOVERN_PRE_PUSH_HUB_TESTS is unset or not "0" (kill switch)
#   - the pushed diff touches a path the list reads: templates/ tools/ commands/ monitors/
#     assets/, any *.md, or VERSION
#
# The full list costs ~85s serially on a doc/vocab-only push, far over the sub-30s push budget a
# direct-to-main push must respect, and running the tests concurrently makes them several times
# SLOWER (each scaffolds its own workspace; they contend, they do not parallelize). So the diff
# picks the scope:
#   - doc-only push (every changed path is a *.md or VERSION): run the doc-guard subset listed in
#     tools/hub-context-doc-tests.txt (cheap vocab guards, the exact defect class of a prose
#     regression), plus tools/check-version-consistency.sh when VERSION or CHANGELOG.md changed
#     (a manifest rollback breaks it and costs well under a second);
#   - any other gated push (templates/, tools/, commands/, ... changed): structural, rare, worth
#     the full list.
# Tests run from THIS checkout (the script's own root), so the list's $DIR/../../.. hub
# resolution is correct and a skip (exit 77) counts as a FAILURE, exactly as CI treats it. A
# quarantined test (leading !) is reported but not gating, also exactly as CI treats it.
#
# Refs: three args (localsha remoteref remotesha), or git pre-push stdin ("<localref>
# <localsha> <remoteref> <remotesha>" per line) when no args are given. Exit 0 when nothing
# needs checking or everything passes, non-zero naming the failing assertion otherwise.
# `--run-doc-checks` skips ref parsing entirely and runs exactly what a doc-only push would run
# (the budget assertion in the suite times this on a real hub checkout).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
list="$root/tools/hub-context-tests.txt"
doc_list="$root/tools/hub-context-doc-tests.txt"
test_dir="$root/templates/govern/test"

# Not a hub checkout (no list): nothing to assert, succeed immediately.
[ -f "$list" ] || exit 0

if [ "${GOVERN_PRE_PUSH_HUB_TESTS:-}" = "0" ]; then
  echo "pre-push: hub-context check skipped (GOVERN_PRE_PUSH_HUB_TESTS=0)" >&2
  exit 0
fi

zero=0000000000000000000000000000000000000000
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
rc_all=0

doc_only=0
if [ "${1:-}" = "--run-doc-checks" ]; then
  doc_only=1
else
  # ── Collect the pushes to inspect: "<localsha> <remoteref> <remotesha>" per line ──
  pairs=()
  if [ "$#" -ge 3 ]; then
    pairs+=("$1 $2 $3")
  else
    while read -r _lref lsha rref rsha; do
      [ -n "${rref:-}" ] || continue
      pairs+=("$lsha $rref $rsha")
    done
  fi

  if [ "${#pairs[@]}" = "0" ]; then
    exit 0   # no refs pushed: nothing to guard
  fi

  gated=0
  all_paths=()
  for pair in "${pairs[@]}"; do
    read -r lsha rref rsha <<<"$pair"
    case "$rref" in refs/heads/main) ;; *) continue ;; esac
    [ "$lsha" = "$zero" ] && continue      # branch deletion: nothing to test
    # Both endpoints must be real objects; a caller that cannot resolve them is not guardable.
    git -C "$root" cat-file -e "${lsha}^{commit}" 2>/dev/null || continue
    if [ "$rsha" = "$zero" ]; then
      base="$empty_tree"                   # new branch: diff everything the tip adds
    elif git -C "$root" cat-file -e "${rsha}^{commit}" 2>/dev/null; then
      base="$rsha"                         # fast-forward or behind: diff is remote tip..local tip
    else
      continue                             # unresolvable remote side: not guardable here
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      all_paths+=("$p")
    done < <(git -C "$root" diff --name-only "$base" "$lsha")
  done

  if [ "${#all_paths[@]}" = "0" ]; then
    exit 0   # no main push with a diff: nothing to guard
  fi

  doc_only=1
  for p in "${all_paths[@]}"; do
    case "$p" in
      *.md|VERSION|*/VERSION) : ;;
      *) doc_only=0; break ;;
    esac
  done
  for p in "${all_paths[@]}"; do
    case "$p" in
      *.md|VERSION|*/VERSION|templates/*|tools/*|commands/*|monitors/*|assets/*)
        gated=1; break ;;
    esac
  done
  if [ "$gated" = "0" ]; then
    exit 0   # the diff touches no path the list reads
  fi
fi

if [ "$doc_only" = "1" ]; then
  # ── Doc push: the cheap subset ──
  if [ ! -f "$doc_list" ]; then
    echo "pre-push: doc-only push needs $doc_list (relative to the hub root), which is missing" >&2
    exit 1
  fi
  names=()
  quarantined=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    q=0
    case "$line" in '!'*) q=1; line="${line#!}" ;; esac
    if ! grep -qxE "[!]?${line}" "$list"; then
      echo "pre-push: $doc_list names '$line' but tools/hub-context-tests.txt does not; the doc subset must be a subset of the main list" >&2
      exit 1
    fi
    names+=("$line")
    quarantined+=("$q")
  done < "$doc_list"

  # A VERSION/CHANGELOG rollback is a doc-path push too, and tools/check-version-consistency.sh
  # rejects it in well under a second. Missing tool: nothing to run.
  version_rc=0
  if [ "${1:-}" != "--run-doc-checks" ]; then
    for p in "${all_paths[@]}"; do
      case "$p" in
        VERSION|*/VERSION|CHANGELOG.md|*/CHANGELOG.md)
          if [ -f "$root/tools/check-version-consistency.sh" ]; then
            bash "$root/tools/check-version-consistency.sh" >/tmp/hub-pre-push-version.log 2>&1 \
              || version_rc=$?
          fi
          break ;;
      esac
    done
  else
    if [ -f "$root/tools/check-version-consistency.sh" ]; then
      bash "$root/tools/check-version-consistency.sh" >/tmp/hub-pre-push-version.log 2>&1 \
        || version_rc=$?
    fi
  fi
  if [ "$version_rc" != "0" ]; then
    echo "pre-push: tools/check-version-consistency.sh FAILED (exit $version_rc)" >&2
    sed 's/^/    /' /tmp/hub-pre-push-version.log >&2
    rc_all=1
  else
    rc_all=0
  fi
else
  # ── Structural push: the full list ──
  names=()
  quarantined=()
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    q=0
    case "$line" in '!'*) q=1; line="${line#!}" ;; esac
    names+=("$line")
    quarantined+=("$q")
  done < "$list"
fi

if [ "${#names[@]}" = "0" ]; then
  exit "$rc_all"   # nothing (left) to run
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hub-context-pre-push.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

# run_one <name>: run the test, record its exit code and output.
run_one() {
  local name="$1" rc
  if bash "$test_dir/$name.sh" >"$tmp/$name.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" >"$tmp/$name.rc"
}

# ── Run serially: concurrent runs of these scaffold-heavy tests contend and are slower ──
for name in "${names[@]}"; do
  [ -f "$test_dir/$name.sh" ] || { printf 'missing\n' >"$tmp/$name.rc"; continue; }
  run_one "$name"
done

# ── Collect ──
i=0
for name in "${names[@]}"; do
  rc="$(cat "$tmp/$name.rc" 2>/dev/null || printf 'missing')"
  q="${quarantined[$i]:-0}"
  i=$((i + 1))
  if [ "$rc" = "missing" ]; then
    if [ "$q" = "1" ]; then
      echo "pre-push: hub-context test $name is QUARANTINED but its file is missing (see tools/hub-context-tests.txt)" >&2
      continue
    fi
    echo "pre-push: hub-context test $name is listed in tools/hub-context-tests.txt but no such test file exists" >&2
    rc_all=1
    continue
  fi
  if [ "$rc" = "0" ]; then
    continue
  fi
  if [ "$q" = "1" ]; then
    echo "pre-push: hub-context test $name is QUARANTINED (known-broken, not gating; see tools/hub-context-tests.txt), exit $rc" >&2
    continue
  fi
  if [ "$rc" = "77" ]; then
    echo "pre-push: hub-context test $name SKIPPED (exit 77): hub resolution broke; treating as a FAILURE, as CI does" >&2
  else
    echo "pre-push: hub-context test $name FAILED (exit $rc)" >&2
  fi
  sed 's/^/    /' "$tmp/$name.out" >&2
  rc_all=1
done

if [ "$rc_all" = "1" ]; then
  echo "pre-push: push to main REFUSED: the hub-context check is red. Fix the failing" >&2
  echo "  assertion above and commit again, or push a feature branch instead (PRs are gated" >&2
  echo "  by CI). Skip once with GOVERN_PRE_PUSH_HUB_TESTS=0 if you must push anyway." >&2
fi
exit "$rc_all"
