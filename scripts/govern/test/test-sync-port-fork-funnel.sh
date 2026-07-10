#!/usr/bin/env bash
# push v2 (#45) — the auto-fork contribution funnel in sync-port.sh.
#
# sync-port derives the templates-repo access posture from git+GitHub (not from
# workspace config) and routes the push + PR accordingly, so an adopter's port
# always ends as a PR against the REAL canonical hub:
#   A. direct-access (maintainer: push to origin, origin IS the hub)  → SAME-repo PR, bare head.
#   B. fork          (origin is the operator's fork, has a `parent`)  → CROSS-repo PR, head owner:branch.
#   C. plain-clone   (clone of the hub, NO push access)               → `gh repo fork` + CROSS-repo PR.
#   D. unknown perm  (gh returned a repo but no readable permission)  → DEGRADE to historical direct push.
#
# Every heavy dep is stubbed via the script's env seams. A `gh` stub emits posture-specific
# `repo view` JSON and records `repo fork` / `pr create` invocations; GOVERN_NO_PUSH=1 skips the
# real network push while still exercising the funnel + PR-create seam. Deterministic, no network.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-port.sh"
STPL="$(cd "$DIR/.." && pwd)/sync-templates.sh"
PORTER_PROMPT="$GOVERN_PROMPTS_DIR/sync-porter-prompt.md"
[ -f "$PORTER_PROMPT" ] || { echo "SKIP: porter prompt missing at $PORTER_PROMPT" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed" >&2; exit 77; }

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly found\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build a fresh sandbox (harness repo + templates repo w/ bare origin, drift seeded). Mirrors
# test-sync-port.sh's mk_sandbox — the machinery needed to reach the gate + push block.
mk_sandbox() {
  local s; s="$(mktemp -d "$ROOT/case.XXXXXX")"
  local H="$s/harness" T="$s/templates" TBARE="$s/templates.git"
  {
  mkdir -p "$H/scripts/govern" "$H/scripts/lib" "$H/governor" "$H/queue"
  mkdir -p "$T/templates/govern/test" "$T/templates/lib"
  cat > "$H/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$H}"
META_NAME="acmeproduct"
ROOT_PM="npm"
GITHUB_ORG="AcmeOrg"
REPOS=(alpha web)
GOVERN_MERGE_REPOS="alpha shiploop"
GOVERN_UPSTREAM_HARNESS_REPO="shiploop"
GOVERN_UPSTREAM_HARNESS_DIR="$T"
GOVERN_META_REPO_SLUG="acme/shiploop"
wsp_repo_slug() { case "\$1" in shiploop) printf '%s' "\$GOVERN_META_REPO_SLUG";; *) printf '%s/%s' "\$GITHUB_ORG" "\$1";; esac; }
wsp_repo_localdir() { case "\$1" in shiploop) printf '%s' "$T";; *) printf '%s/%s' "\$META_ROOT" "\$1";; esac; }
wsp_is_merge_repo() { local r="\$1" a; for a in \$GOVERN_MERGE_REPOS; do [ "\$r" = "\$a" ] && return 0; done; return 1; }
EOF
  printf 'echo run\n' > "$H/scripts/govern/run-loop.sh"
  printf '# marker placeholder\n' > "$H/scripts/govern/.templates-synced-at"
  printf '# Escalations\n\n## Open\n' > "$H/governor/escalations.md"
  printf '# tickets\n' > "$H/queue/tickets.md"
  git -C "$H" init -q; git -C "$H" config user.email t@t; git -C "$H" config user.name t
  git -C "$H" add -A; git -C "$H" commit -qm init
  local BASE; BASE="$(git -C "$H" rev-parse HEAD)"
  printf 'echo run\n' > "$T/templates/govern/run-loop.sh"
  printf '#!/usr/bin/env bash\nMETA_NAME="__META_NAME__"\nGITHUB_ORG="__GITHUB_ORG__"\nREPOS=(__REPOS__)\n' > "$T/templates/lib/workspace.sh"
  printf 'echo assert\n' > "$T/templates/govern/test/assert.sh"
  git -C "$T" init -q; git -C "$T" config user.email t@t; git -C "$T" config user.name t
  git -C "$T" add -A; git -C "$T" commit -qm "init templates"
  git init --bare -q "$TBARE"
  git -C "$T" remote add origin "$TBARE"
  git -C "$T" push -q origin HEAD:main
  git -C "$T" fetch -q origin
  GOVERN_DIR="$H/scripts/govern" GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at" \
    GOVERN_TEMPLATE_DIR="$T/templates/govern" bash "$STPL" --mark "$BASE"
  git -C "$H" add -A; git -C "$H" commit -qm "mark base"
  printf 'echo run v2\n' >> "$H/scripts/govern/run-loop.sh"
  git -C "$H" add -A; git -C "$H" commit -qm "feat: improve run-loop mechanism"
  } >/dev/null 2>&1
  printf '%s\n' "$s"
}

# Porter stub: appends a generic (non-identity) line + commits — a clean port that passes the gate.
mk_porter_stub() { cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'echo "run v2 generic mechanism"' >> "$2"
git add -A >/dev/null 2>&1; git commit -qm "port: stub change" >/dev/null 2>&1
report='{"status":"ported","files":["govern/run-loop.sh"]}'
[ -n "\${GOVERN_REPORT_PATH:-}" ] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$1"; }

# gh stub: posture-specific `repo view` JSON (from STUB_ORIGIN/STUB_PARENT/STUB_PERM); records
# `repo fork` + `pr create` invocations to STUB_REC; reports NO merged/open PR for the pre-checks.
mk_gh_stub() { cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    jq -n --arg o "${STUB_ORIGIN:-}" --arg p "${STUB_PARENT:-}" --arg v "${STUB_PERM:-}" \
      '{nameWithOwner:$o, parent:(if $p=="" then null else {nameWithOwner:$p} end), viewerPermission:$v}'
    ;;
  "repo fork") printf 'fork %s\n' "$*" >> "$STUB_REC" ;;
  "pr create") printf 'create %s\n' "$*" >> "$STUB_REC"
               echo "https://github.com/${STUB_PARENT:-$STUB_ORIGIN}/pull/7" ;;
  "pr list")   echo "" ;;   # no merged / open PR for the drift branch
  *)           : ;;
esac
exit 0
EOF
chmod +x "$1"; }

# run_posture <sandbox> — exports the gate/porter env + GOVERN_NO_PUSH=1 + NO_MERGE, runs sync-port.
run_posture() { # <s>
  local s="$1" H="$s/harness" T="$s/templates"
  GOVERN_WS_ROOT="$H" \
  GOVERN_TICKETS_FILE="$H/queue/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$H/governor/escalations.md" \
  GOVERN_DIR="$H/scripts/govern" \
  GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at" \
  GOVERN_TEMPLATE_DIR="$T/templates/govern" \
  GOVERN_TEMPLATE_REPO_DIR="$T" \
  GOVERN_NO_PUSH=1 \
  GOVERN_SYNC_PORTER_TIMEOUT=60 \
  GOVERN_SYNC_PORTER_PROMPT="$PORTER_PROMPT" \
  GOVERN_SYNC_PORT_NO_MERGE=1 \
  GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true" \
  GOVERN_CLAUDE_BIN="$s/porter.sh" \
  GOVERN_GH_BIN="$s/gh.sh" \
  STUB_REC="$s/gh-rec.txt" \
  bash "$TOOL" 2>&1
}

setup_case() { # <s>
  local s="$1"
  mk_porter_stub "$s/porter.sh" "$s/templates/templates/govern/run-loop.sh"
  mk_gh_stub "$s/gh.sh"
  : > "$s/gh-rec.txt"
}

# ── A. direct-access (maintainer): origin IS the hub, has push → SAME-repo PR, bare head ──
s="$(mk_sandbox)"; setup_case "$s"
out="$( STUB_ORIGIN="anshss/shiploop" STUB_PARENT="" STUB_PERM="ADMIN" run_posture "$s" )"; rc=$?
rec="$(cat "$s/gh-rec.txt")"
assert_eq "$rc" "0" "A. direct-access → exit 0 (no-merge PR opened)"
assert_contains     "$rec" "create --repo anshss/shiploop" "A. PR targets the canonical hub"
assert_contains     "$rec" "head sync-auto"               "A. head is the bare branch (same-repo PR)"
assert_not_contains "$rec" ":sync-auto"                     "A. head has NO owner prefix (not cross-repo)"
assert_not_contains "$rec" "fork "                          "A. gh repo fork NOT invoked (has push)"

# ── B. fork posture: origin is the operator's fork (parent=hub), has push → CROSS-repo PR ──
s="$(mk_sandbox)"; setup_case "$s"
out="$( STUB_ORIGIN="adopter/shiploop" STUB_PARENT="anshss/shiploop" STUB_PERM="ADMIN" run_posture "$s" )"; rc=$?
rec="$(cat "$s/gh-rec.txt")"
assert_eq "$rc" "0" "B. fork posture → exit 0"
assert_contains     "$rec" "create --repo anshss/shiploop"    "B. PR targets the canonical hub (fork's parent)"
assert_contains     "$rec" "head adopter:sync-auto"         "B. cross-repo head (adopter:branch)"
assert_not_contains "$rec" "fork "                            "B. gh repo fork NOT invoked (origin already the fork)"

# ── C. plain-clone: clone of the hub, NO push access → gh repo fork + CROSS-repo PR ──
s="$(mk_sandbox)"; setup_case "$s"
out="$( STUB_ORIGIN="anshss/shiploop" STUB_PARENT="" STUB_PERM="READ" _GOVERN_OWN_LOGIN="adopter" run_posture "$s" )"; rc=$?
rec="$(cat "$s/gh-rec.txt")"
assert_eq "$rc" "0" "C. plain-clone → exit 0"
assert_contains "$rec" "fork repo fork anshss/shiploop --clone=false" "C. gh repo fork of the hub invoked (no push access)"
assert_contains "$rec" "create --repo anshss/shiploop"                "C. PR targets the canonical hub"
assert_contains "$rec" "head adopter:sync-auto"                     "C. cross-repo head under the operator's login"

# ── D. unknown permission (gh resolved the repo but not viewerPermission) → DEGRADE to direct ──
s="$(mk_sandbox)"; setup_case "$s"
out="$( STUB_ORIGIN="anshss/shiploop" STUB_PARENT="" STUB_PERM="" run_posture "$s" )"; rc=$?
rec="$(cat "$s/gh-rec.txt")"
assert_eq "$rc" "0" "D. unknown-perm → exit 0"
assert_not_contains "$rec" "fork "        "D. unknown permission NEVER forks (fail-safe to direct)"
assert_contains     "$rec" "head sync-auto" "D. degrades to a bare-head same-repo PR"
assert_not_contains "$rec" ":sync-auto"   "D. no cross-repo head on the degrade path"

assert_done
