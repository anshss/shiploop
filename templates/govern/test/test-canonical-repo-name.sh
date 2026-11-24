#!/usr/bin/env bash
# govern::canonical_repo_name + normalize_pr_field canonicalization: a worker report naming the
# same repo by its full owner/repo SLUG used to pass normalize (any non-empty string was accepted)
# and then silently fail collect_ticket_prs' EXACT-match walk — one consumer read the field while
# the merge path saw "no PR", and the block was deleted with the PR open. Every .repo that passes
# normalize is now rewritten onto the ONE token the merge path keys on, and an identifier nothing
# configured matches is a hard refusal — never "no PR".
# Negative controls: a short name passes through byte-identical, and a malformed .prs[] entry
# refuses the WHOLE report rather than being dropped.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha,api"
# harness_repo_slugs reads the meta root's own git origin; give the stub one.
( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
  && git remote add origin https://github.com/acme/harness.git )
# harness_repo_slugs reads the META ROOT's origin; the meta root is the tickets file's git toplevel.
mkdir -p "$T/queue"; printf '# Tickets\n' > "$T/queue/tickets.md"
export GOVERN_TICKETS_FILE="$T/queue/tickets.md"
source "$DIR/../lib/common.sh"
set +e   # common.sh re-armed -e; refusals (rc 1) are the behavior under test
mkdir -p "$T/bin"
# gh stub: PR 5 is OPEN in acme/alpha (for the bare-integer shapes).
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"pr view 5"* ]]; then printf 'OPEN\n'; exit 0; fi
exit 1
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# canonical_repo_name: configured short name, full slug of a configured repo, harness slug + bare
# harness name; anything else refuses (rc 1, no output).
assert_eq "$(govern::canonical_repo_name "alpha")" "alpha" "a configured short name is canonical already"
assert_eq "$(govern::canonical_repo_name "acme/alpha")" "alpha" "the full owner/repo slug canonicalizes to the short name"
assert_eq "$(govern::canonical_repo_name "ACME/ALPHA")" "alpha" "slug matching is case-insensitive"
assert_eq "$(govern::canonical_repo_name "acme/harness")" "acme/harness" "a harness slug is canonical"
assert_eq "$(govern::canonical_repo_name "harness")" "harness" "a bare harness name is canonical"
out="$(govern::canonical_repo_name "ghost")"; assert_eq "$?" "1" "an identifier nothing configured matches refuses (rc 1)"
assert_eq "$out" "" "the refusal prints nothing (never a repo token)"

# normalize: the slug form is REWRITTEN onto the short name (was passed through untouched).
out="$(govern::normalize_pr_field '{"pr":{"repo":"acme/alpha","number":9,"url":"u"}}')"
assert_eq "$(printf '%s' "$out" | jq -r '.pr.repo')" "alpha" ".pr.repo slug is rewritten onto the canonical token"

# normalize: a .prs[] slug entry is canonicalized on the same seam.
out="$(govern::normalize_pr_field '{"status":"resolved","prs":[{"repo":"acme/alpha","number":1},{"repo":"api","number":2}]}')"
assert_eq "$(printf '%s' "$out" | jq -r '.prs[0].repo')" "alpha" "the .prs[] slug entry is rewritten onto the canonical token"
assert_eq "$(printf '%s' "$out" | jq -r '.prs[1].repo')" "api" "the already-canonical .prs[] entry passes through"

# negative controls.
out="$(govern::normalize_pr_field '{"status":"resolved","pr":{"repo":"alpha","number":9}}')"; rc=$?
assert_eq "$rc" "0" "an already-canonical report still normalizes clean (control)"
assert_contains "$out" '"repo":"alpha"' "the control report's repo is untouched"

govern::normalize_pr_field '{"status":"resolved","prs":[{"repo":"ghost","number":3}]}' >/dev/null 2>&1
assert_eq "$?" "1" "an unknown .prs[] repo refuses the WHOLE report (never dropped silently)"
govern::normalize_pr_field '{"status":"resolved","prs":[{"repo":"alpha"}]}' >/dev/null 2>&1
assert_eq "$?" "1" "a .prs[] entry missing .number refuses the report"
govern::normalize_pr_field '{"status":"resolved","pr":{"repo":"ghost","number":3}}' >/dev/null 2>&1
assert_eq "$?" "1" "an unknown .pr repo refuses (never the no-PR path)"

assert_done
