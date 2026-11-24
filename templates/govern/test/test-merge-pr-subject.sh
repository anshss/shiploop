#!/usr/bin/env bash
# merge-pr.sh passes an explicit --subject built from the PR TITLE: GitHub's squash-merge of a
# SINGLE-COMMIT PR defaults the merge message to that COMMIT's own subject, not the PR title — and
# the PR-hygiene scrub can only PATCH title/body, never the branch commit, so a worker whose
# commit subject still carried the local ticket id leaked it into the public repo on exactly the
# single-commit PRs this governor always produces.
# Negative control: an unreadable title degrades to the old behavior (no --subject) with a WARN,
# and never blocks the merge — this is hygiene, not a correctness gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
MERGE="$DIR/../merge-pr.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
BIN="$(mktemp -d)"

# 1. Readable title → the echo'd merge command carries --subject with the PR title.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr view"* && "$*" == *"--json title"* ]]; then printf 'feat: clean public title\n'; exit 0; fi
exit 0
EOF
chmod +x "$BIN/gh"
out="$(PATH="$BIN:$PATH" GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"
assert_contains "$out" "subject feat: clean public title" "the squash subject is the PR title, not the branch commit"
assert_contains "$out" "gh pr merge 42" "the merge command itself is unchanged"

# 2. Unreadable title → WARN + no --subject (old behavior), still exit 0.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/gh"
out="$(PATH="$BIN:$PATH" GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 43 2>&1)"
code=$?
assert_eq "$code" "0" "an unreadable title never blocks the merge"
assert_contains "$out" "could not read" "the degraded path warns loudly"
if printf '%s' "$out" | grep -q -- "--subject"; then
  echo "FAIL - a --subject was built from an unreadable title"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - no --subject is passed when the title is unreadable"
fi

assert_done
