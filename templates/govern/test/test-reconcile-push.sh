#!/usr/bin/env bash
# Regression for /meta-repo-harness:push — locks the invariants the command
# depends on but doesn't own itself (sync-templates.sh + sync-port.sh do the
# work; this test verifies those honor the promises /push makes to the operator).
#
# Contract:
#   1. GOVERN_UPSTREAM_HARNESS_REPO empty → sync-port inert (exit 0, "feature off").
#   2. Drift on a mirrored mechanism script → sync-templates --check exit 3.
#   3. workspace.sh-only change → NOT surfaced as drift (config sink filtered).
#   4. package.json-only change → NOT surfaced as drift (workspace-specific).
#   5. --dry-run mode → prints the plan, cuts no branch, invokes no PR/merge.
#   6. No drift → sync-port exits 0 with "in sync" message, no work.
#
# Every heavy dep is stubbed via the script's env seams.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

SYNCPORT="$(cd "$DIR/.." && pwd)/sync-port.sh"
SYNCTPL="$(cd "$DIR/.." && pwd)/sync-templates.sh"
# Porter prompt seam — same skip as test-sync-port.sh.
PORTER_PROMPT="$GOVERN_PROMPTS_DIR/sync-porter-prompt.md"
[ -f "$PORTER_PROMPT" ] || { echo "SKIP: porter prompt missing at $PORTER_PROMPT" >&2; exit 77; }

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly found\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build a sandbox mirroring test-sync-port.sh's shape.
# Pass "" as arg1 for the inert (no-upstream) case; unset/no-arg → default upstream.
mk_sandbox() { # <upstream-repo-value>
  local upstream_val="${1-meta-repo-harness}"
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
GOVERN_MERGE_REPOS="alpha"
GOVERN_UPSTREAM_HARNESS_REPO="$upstream_val"
GOVERN_UPSTREAM_HARNESS_DIR="$T"
GOVERN_META_REPO_SLUG="acme/meta-repo-harness"
wsp_repo_slug() { case "\$1" in meta-repo-harness) printf '%s' "\$GOVERN_META_REPO_SLUG";; *) printf '%s/%s' "\$GITHUB_ORG" "\$1";; esac; }
wsp_repo_localdir() { case "\$1" in meta-repo-harness) printf '%s' "$T";; *) printf '%s/%s' "\$META_ROOT" "\$1";; esac; }
wsp_is_merge_repo() { local r="\$1" a; for a in \$GOVERN_MERGE_REPOS; do [ "\$r" = "\$a" ] && return 0; done; return 1; }
EOF
  printf 'echo run\n' > "$H/scripts/govern/run-loop.sh"
  printf '# marker placeholder\n' > "$H/scripts/govern/.templates-synced-at"
  printf '# Escalations\n\n## Open\n' > "$H/governor/escalations.md"
  printf '# tickets\n' > "$H/queue/tickets.md"
  # Also seed package.json + a git-tracked marker file so we can create workspace-only drift.
  printf '{"name":"acme","scripts":{}}\n' > "$H/package.json"
  git -C "$H" init -q; git -C "$H" config user.email t@t; git -C "$H" config user.name t
  git -C "$H" add -A; git -C "$H" commit -qm init
  local BASE; BASE="$(git -C "$H" rev-parse HEAD)"

  # Template counterparts.
  printf 'echo run\n' > "$T/templates/govern/run-loop.sh"
  printf '#!/usr/bin/env bash\nMETA_NAME="__META_NAME__"\nGITHUB_ORG="__GITHUB_ORG__"\nREPOS=(__REPOS__)\n' > "$T/templates/lib/workspace.sh"
  printf 'echo assert\n' > "$T/templates/govern/test/assert.sh"
  git -C "$T" init -q; git -C "$T" config user.email t@t; git -C "$T" config user.name t
  git -C "$T" add -A; git -C "$T" commit -qm "init templates"
  git init --bare -q "$TBARE"
  git -C "$T" remote add origin "$TBARE"
  git -C "$T" push -q origin HEAD:main
  git -C "$T" fetch -q origin

  # Marker at BASE.
  GOVERN_DIR="$H/scripts/govern" GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at" \
    GOVERN_TEMPLATE_DIR="$T/templates/govern" \
    bash "$SYNCTPL" --mark "$BASE"
  git -C "$H" add -A; git -C "$H" commit -qm "mark base"
  } >/dev/null 2>&1
  printf '%s\n' "$s"
}

tool_env() { # <sandbox>
  local s="$1" H="$s/harness" T="$s/templates"
  export GOVERN_WS_ROOT="$H"
  export GOVERN_TICKETS_FILE="$H/queue/tickets.md"
  export GOVERN_ESCALATIONS_FILE="$H/governor/escalations.md"
  export GOVERN_DIR="$H/scripts/govern"
  export GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at"
  export GOVERN_TEMPLATE_DIR="$T/templates/govern"
  export GOVERN_TEMPLATE_REPO_DIR="$T"
  export GOVERN_NO_PUSH=1
  export GOVERN_SYNC_PORTER_TIMEOUT=60
  export GOVERN_SYNC_PORTER_PROMPT="$PORTER_PROMPT"
}

mk_merge_stub() { cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exit 0
EOF
chmod +x "$1"; }

# ── Case 1: GOVERN_UPSTREAM_HARNESS_REPO empty → sync-port inert ────────────
s="$(mk_sandbox "")"
mrec="$s/mrec.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"; export GOVERN_MERGE_CMD="$merge"; bash "$SYNCPORT" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "1. no upstream knob → exit 0 (inert)"
assert_contains "$out" "feature off" "1. sync-port says feature off"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "1. no merge invoked when inert"

# ── Case 2: drift on a MIRRORED file → sync-templates reports drift ────────
s="$(mk_sandbox)"
printf 'echo v2\n' >> "$s/harness/scripts/govern/run-loop.sh"
git -C "$s/harness" add -A; git -C "$s/harness" commit -qm "feat: improve run-loop"
out="$( tool_env "$s"; bash "$SYNCTPL" --check 2>&1 )"; rc=$?
assert_eq "$rc" "3" "2. mirrored drift → sync-templates exit 3"
assert_contains "$out" "improve run-loop" "2. drift lists the commit subject"

# ── Case 3: workspace.sh-only change → NOT surfaced as drift ────────────────
s="$(mk_sandbox)"
printf '# operator custom var\nMY_KNOB="secret"\n' >> "$s/harness/scripts/lib/workspace.sh"
git -C "$s/harness" add -A; git -C "$s/harness" commit -qm "chore(workspace): operator knob"
out="$( tool_env "$s"; bash "$SYNCTPL" --check 2>&1 )"; rc=$?
assert_eq "$rc" "0" "3. workspace.sh change → NOT drift (exit 0)"
assert_contains "$out" "in sync" "3. reports still-in-sync"
files="$( tool_env "$s"; bash "$SYNCTPL" --files 2>&1 )"
assert_not_contains "$files" "workspace.sh" "3. workspace.sh never listed in --files"

# ── Case 4: package.json-only change → NOT surfaced as drift ────────────────
# (package.json has NO template counterpart — the template is generated fresh
# each time, no mirror file. Workspace-specific by design.)
s="$(mk_sandbox)"
printf '{"name":"acme","scripts":{"custom":"echo hi"}}\n' > "$s/harness/package.json"
git -C "$s/harness" add -A; git -C "$s/harness" commit -qm "chore: operator script"
out="$( tool_env "$s"; bash "$SYNCTPL" --check 2>&1 )"; rc=$?
assert_eq "$rc" "0" "4. package.json change → NOT drift (exit 0)"

# ── Case 5: --dry-run prints plan, cuts no branch, invokes nothing ─────────
s="$(mk_sandbox)"
printf 'echo v2\n' >> "$s/harness/scripts/govern/run-loop.sh"
git -C "$s/harness" add -A; git -C "$s/harness" commit -qm "feat: run-loop tweak"
mrec="$s/mrec.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"; export GOVERN_MERGE_CMD="$merge"; bash "$SYNCPORT" --dry-run 2>&1 )"; rc=$?
assert_eq "$rc" "0" "5. --dry-run → exit 0"
assert_contains "$out" "DRY RUN" "5. announces DRY RUN"
assert_contains "$out" "scripts/govern/run-loop.sh" "5. lists drifted file"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "5. dry-run: no merge invoked"
# No branch cut in the templates repo:
branches="$(git -C "$s/templates" branch --list 'sync-auto-*' 2>/dev/null)"
assert_not_contains "$branches" "sync-auto" "5. dry-run cuts NO branch"

# ── Case 6: no drift → sync-port exits 0 with in-sync message ──────────────
s="$(mk_sandbox)"
# Fast-forward marker to HEAD so there's no drift.
( tool_env "$s"; bash "$SYNCTPL" --mark >/dev/null 2>&1 )
mrec="$s/mrec.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"; export GOVERN_MERGE_CMD="$merge"; bash "$SYNCPORT" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "6. no drift → sync-port exit 0"
assert_contains "$out" "in sync" "6. sync-port reports in sync"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "6. no drift → no merge invoked"

assert_done
