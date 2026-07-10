#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"

# Hermetic config: alpha is auto-mergeable, web is frontend (PR-only) — independent of the live workspace.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# Frontend repo → refused (exit 2), regardless of CI.
set +e
out="$(GOVERN_ECHO=1 "$MERGE" web 9 2>&1)"; code=$?
set -e
assert_eq "$code" "2" "web (frontend) merge refused with exit 2"
assert_contains "$out" "PR-only" "refusal explains frontend is PR-only"

# Allowlisted repo in echo mode → prints the gh merge command, does not run it, exit 0.
set +e
out2="$(GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code2=$?
set -e
assert_eq "$code2" "0" "alpha merge in echo mode exits 0"
assert_contains "$out2" "gh pr merge 42" "echo mode prints the merge command"

# FAIL-CLOSED: CI state UNVERIFIABLE ('error' from await-ci) must NOT merge — exit 4 (distinct
# from red/pending's 3) so the caller parks it as ci-state-unverifiable rather than a failing check.
# Stub await-ci onto PATH by shadowing gh: an erroring `gh pr checks` (exit 1, no JSON) drives the
# real await-ci to conclude 'error'. GOVERN_CI_ERR_MAX=1/GRACE=0 keep it instant.
TMP="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[[ "$*" == *"pr checks"* ]] && exit 1\nexit 0\n' > "$TMP/gh"
chmod +x "$TMP/gh"
set +e
out3="$(PATH="$TMP:$PATH" GOVERN_CI_ERR_MAX=1 GOVERN_CI_NONE_GRACE=0 GOVERN_ECHO=1 "$MERGE" alpha 43 2>&1)"; code3=$?
set -e
assert_eq "$code3" "4" "CI-unverifiable ('error') merge refused with distinct exit 4"
assert_contains "$out3" "not merging" "unverifiable CI refusal is logged"

# A RED/pending CI (checks present, one failing) → refused with exit 3 (unchanged).
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr checks"* ]]; then printf '%s' '[{"bucket":"fail"}]'; exit 0; fi
exit 0
EOF
chmod +x "$TMP/gh"
set +e
out4="$(PATH="$TMP:$PATH" GOVERN_ECHO=1 "$MERGE" alpha 44 2>&1)"; code4=$?
set -e
assert_eq "$code4" "3" "red CI merge refused with exit 3"
rm -rf "$TMP"

assert_done
