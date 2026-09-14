#!/usr/bin/env bash
# Two-factor auto-merge safety guard (govern::pr_automerge_allowed): the governor's auto-merge
# lane must NEVER land a PR it did not itself open, regardless of CI. This test exercises every
# fail-closed path directly against merge-pr.sh via a fake `gh` on PATH — the CANONICAL adversary
# for the "external contributor's green PR gets auto-merged" scenario the guard exists to prevent.
#
# Matrix (own gh login is "acme"; alpha is auto-mergeable):
#   A. External author + own repo + green CI                  → BLOCK exit 5, reason external-author
#   B. Own author    + FORK repo (bob owns head)               → BLOCK exit 5, reason fork-pr
#   C. gh api user   FAILS                                     → BLOCK exit 5, reason lookup-failed
#   D. Own author    + own repo + green CI, branch ticket-42   → ALLOW exit 0, guard silent
#   E. Own author    + own repo + green CI, branch vf-lever-enforce (a real worktree:new slug,
#      matching no governor branch pattern) → ALLOW exit 0: the guard no longer looks at branch
#      name at all, so a worktree:new slug merges same as any other own-author, non-fork PR.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # alpha auto-mergeable, web frontend, org acme
# Guard is bypassed by default under mk_ws_stub — this test exercises it explicitly.
unset _GOVERN_ASSUME_MERGE_ALLOWED

# The gh stub is DATA-DRIVEN: the test writes GH_* files that shape each response so the same stub
# handles every matrix cell without a per-cell rewrite. Files:
#   $T/gh-user       — text emitted for `gh api user --jq .login` (empty ⇒ non-zero exit, lookup-failed)
#   $T/gh-pr.json    — full JSON object emitted for `gh api repos/<slug>/pulls/<N>`
#   $T/gh-checks.json — JSON emitted for `gh pr checks --json …` (via await-ci)
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"api user"*)
    if [[ -s "$T/gh-user" ]]; then cat "$T/gh-user"; exit 0; fi
    exit 1;;
  *"api repos/"*"pulls/"*)
    if [[ -s "$T/gh-pr.json" ]]; then cat "$T/gh-pr.json"; exit 0; fi
    exit 1;;
  *"pr checks"*)
    if [[ -s "$T/gh-checks.json" ]]; then cat "$T/gh-checks.json"; exit 0; fi
    echo '[{"bucket":"pass"}]'; exit 0;;
  *"pr merge"*)
    # If any test-cell forgets to block a bad PR, the merge would succeed silently. Instead RECORD
    # the merge attempt so the assertions can catch a guard bypass.
    echo "$*" >> "$T/merge-invocations.log"; echo 'merged'; exit 0;;
  *"pr view"*"headRefName"*)
    # branch-cleanup backstop lookup — return whatever ref the PR json advertises so cleanup is quiet.
    jq -r '.head.ref // ""' "$T/gh-pr.json" 2>/dev/null; exit 0;;
  *) echo '[]'; exit 0;;
esac
EOF
chmod +x "$T/bin/gh"

# Own login = acme (matches slug prefix from mk_ws_stub → acme/alpha).
printf 'acme\n' > "$T/gh-user"

# Convenience: shape the PR JSON for a cell.
pr_json() { # author  head-ref  head-owner  base-owner
  jq -n --arg a "$1" --arg h "$2" --arg ho "$3" --arg bo "$4" \
    '{user:{login:$a},head:{ref:$h,repo:{owner:{login:$ho}}},base:{repo:{owner:{login:$bo}}}}' \
    > "$T/gh-pr.json"
}

run_merge() { # exit-code var  <extra-env=k=v ...>
  : > "$T/merge-invocations.log"
  set +e
  # Cache-buster: the workspace login is cached across calls via _GOVERN_OWN_LOGIN. Unset it per cell
  # so each cell freshly re-derives from $T/gh-user (a cell-C lookup-failure test would false-pass if
  # a prior cell had cached "acme").
  out="$(unset _GOVERN_OWN_LOGIN; PATH="$T/bin:$PATH" GOVERN_WS_ROOT="$T" GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"
  rc=$?
  set -e
}

# ── A. External author + own repo + green CI → block(external-author) ──
pr_json "outsider" "ticket-42" "acme" "acme"
run_merge
assert_eq "$rc" "5" "A: external author blocked with exit 5"
assert_contains "$out" "external-pr-blocked (external-author)" "A: reason token is external-author"
assert_eq "$(wc -l < "$T/merge-invocations.log" | tr -d ' ')" "0" "A: gh pr merge was NEVER invoked"

# ── B. Own author + FORK head (bob's fork) → block(fork-pr) ──
pr_json "acme" "ticket-42" "bob" "acme"
run_merge
assert_eq "$rc" "5" "B: fork PR blocked with exit 5"
assert_contains "$out" "external-pr-blocked (fork-pr)" "B: reason token is fork-pr"
assert_eq "$(wc -l < "$T/merge-invocations.log" | tr -d ' ')" "0" "B: gh pr merge was NEVER invoked"

# ── C. gh api user FAILS → block(lookup-failed) — the "transient GitHub outage" adversary ──
: > "$T/gh-user"   # empty ⇒ stub returns non-zero ⇒ own_login lookup fails
pr_json "acme" "ticket-42" "acme" "acme"
run_merge
assert_eq "$rc" "5" "C: gh api user failure blocked with exit 5 (fail-closed)"
assert_contains "$out" "external-pr-blocked (lookup-failed)" "C: reason token is lookup-failed"
assert_eq "$(wc -l < "$T/merge-invocations.log" | tr -d ' ')" "0" "C: gh pr merge was NEVER invoked on lookup failure"
printf 'acme\n' > "$T/gh-user"   # restore for the allow cells

# ── D. Own author + own repo + green CI, branch ticket-42 → ALLOW (exit 0) ──
pr_json "acme" "ticket-42" "acme" "acme"
run_merge
assert_eq "$rc" "0" "D: legit governor PR is ALLOWED (guard is not a false-positive)"
if grep -qF "external-pr-blocked" <<<"$out"; then
  assert_eq "blocked" "allowed" "D: legit PR must not print external-pr-blocked"
else
  assert_eq "allowed" "allowed" "D: legit PR must not print external-pr-blocked"
fi
assert_eq "$(wc -l < "$T/merge-invocations.log" | tr -d ' ')" "1" "D: gh pr merge WAS invoked once"

# ── E. Own author + own repo + green CI, branch vf-lever-enforce (a real worktree:new slug,
#      not any governor-owned pattern) → ALLOW. The regression test for this ticket: the guard
#      no longer has a branch-pattern leg, so a worktree:new slug merges like any other PR that
#      passes the author and fork checks. ──
pr_json "acme" "vf-lever-enforce" "acme" "acme"
run_merge
assert_eq "$rc" "0" "E: worktree:new slug branch is ALLOWED (no branch-pattern leg left to trip)"
assert_eq "$(wc -l < "$T/merge-invocations.log" | tr -d ' ')" "1" "E: gh pr merge WAS invoked once"

assert_done
