#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
AWAIT="$DIR/../await-ci.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake gh: emit the JSON in $FAKE_GH_JSON for `gh pr checks ... --json bucket`.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_GH_JSON"
EOF
chmod +x "$TMP/gh"

run() { PATH="$TMP:$PATH" GOVERN_CI_MAX_TRIES=1 GOVERN_CI_NONE_GRACE=0 FAKE_GH_JSON="$1" "$AWAIT" alpha 1; }

assert_eq "$(run '[{"bucket":"pass"},{"bucket":"pass"}]')" "green"   "all pass → green"
assert_eq "$(run '[{"bucket":"pass"},{"bucket":"fail"}]')" "red"     "any fail → red"
assert_eq "$(run '[{"bucket":"pending"}]')"                "pending" "pending → pending"
assert_eq "$(run '[]')"                                    "none"    "no checks → none"
assert_done
