#!/usr/bin/env bash
# Hermetic regression for the AUTO harness→template porter (sync-port.sh).
#
# Fail-closed contract under test:
#   1. no drift            → no-op (exit 0), no branch / porter / PR / merge.
#   2. drift + ported + gate passes → merge invoked (green-or-no-checks) + marker advanced.
#   3. drift + porter LEAKS a forbidden identity string → gate BLOCKS, escalation filed, NO merge.
#   4. drift + porter ESCALATES → NO merge, escalation filed.
#   5. --dry-run → prints the plan, cuts NO branch, invokes NO merge.
#   6. lock held → exits 0 without acting.
#   7. escalations are NUMERIC (### #N) so the whole lifecycle sees them.
#   8. empty-diff porter → escalation, no push/PR, templates restored to main.
#   9. uncommitted-work strand → escalation, no push/PR, templates restored.
#  10. fingerprint dedup — two runs against same drift → one entry, Last-seen bump.
#  11. GOVERN_UPSTREAM_HARNESS_REPO empty (default) → mechanism inert, exit 0.
#
# Every heavy dep is stubbed via the script's env seams.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-port.sh"
STPL="$(cd "$DIR/.." && pwd)/sync-templates.sh"
# Porter prompt: assert.sh resolves GOVERN_PROMPTS_DIR to templates/governor
# (template layout) or <root>/governor (scaffolded workspace). The prompt lives
# beside the other worker prompts in both layouts.
PORTER_PROMPT="$GOVERN_PROMPTS_DIR/sync-porter-prompt.md"
[ -f "$PORTER_PROMPT" ] || { echo "SKIP: porter prompt missing at $PORTER_PROMPT" >&2; exit 77; }

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] unexpectedly found\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build a fresh, independent sandbox (harness repo + templates repo with a bare origin, drift seeded).
mk_sandbox() {
  local s; s="$(mktemp -d "$ROOT/case.XXXXXX")"
  local H="$s/harness" T="$s/templates" TBARE="$s/templates.git"
  {
  mkdir -p "$H/scripts/govern" "$H/scripts/lib" "$H/governor" "$H/queue"
  mkdir -p "$T/templates/govern/test" "$T/templates/lib"

  # ── harness repo: fake identity + a mirrored file + marker + queue/escalations ──
  cat > "$H/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$H}"
META_NAME="acmeproduct"
ROOT_PM="npm"
GITHUB_ORG="AcmeOrg"
REPOS=(alpha web)
GOVERN_MERGE_REPOS="alpha meta-repo-harness"
GOVERN_UPSTREAM_HARNESS_REPO="meta-repo-harness"
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
  git -C "$H" init -q; git -C "$H" config user.email t@t; git -C "$H" config user.name t
  git -C "$H" add -A; git -C "$H" commit -qm init
  local BASE; BASE="$(git -C "$H" rev-parse HEAD)"

  # ── templates repo: the counterpart + a placeholder workspace.sh + a trivial test dir ──
  printf 'echo run\n' > "$T/templates/govern/run-loop.sh"
  printf '#!/usr/bin/env bash\nMETA_NAME="__META_NAME__"\nGITHUB_ORG="__GITHUB_ORG__"\nREPOS=(__REPOS__)\n' > "$T/templates/lib/workspace.sh"
  printf 'echo assert\n' > "$T/templates/govern/test/assert.sh"
  git -C "$T" init -q; git -C "$T" config user.email t@t; git -C "$T" config user.name t
  git -C "$T" add -A; git -C "$T" commit -qm "init templates"
  git init --bare -q "$TBARE"
  git -C "$T" remote add origin "$TBARE"
  git -C "$T" push -q origin HEAD:main
  git -C "$T" fetch -q origin

  # ── set the marker to BASE, then create DRIFT ──
  GOVERN_DIR="$H/scripts/govern" GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at" \
    GOVERN_TEMPLATE_DIR="$T/templates/govern" \
    bash "$STPL" --mark "$BASE"
  git -C "$H" add -A; git -C "$H" commit -qm "mark base"
  printf 'echo run v2\n' >> "$H/scripts/govern/run-loop.sh"
  git -C "$H" add -A; git -C "$H" commit -qm "feat: improve run-loop mechanism"
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

mk_porter_stub() { # <path> <target-counterpart-abs>
  cat > "$1" <<EOF
#!/usr/bin/env bash
tgt="$2"
if [ "\${STUB_NO_COMMIT:-0}" != "1" ] && [ -n "\${STUB_ADD_LINE:-}" ]; then
  printf '%s\n' "\$STUB_ADD_LINE" >> "\$tgt"
  git add -A >/dev/null 2>&1
  git commit -qm "port: stub change" >/dev/null 2>&1
fi
report="{\"status\":\"\${STUB_STATUS:-ported}\",\"files\":[\"govern/run-loop.sh\"],\"escalation\":\"\${STUB_ESCALATION:-}\"}"
[ -n "\${GOVERN_REPORT_PATH:-}" ] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$1"
}

mk_gh_stub() { cat > "$1" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "pr" ] && [ "$2" = "create" ] && { echo "https://github.com/acme/meta-repo-harness/pull/42"; exit 0; }
exit 0
EOF
chmod +x "$1"; }

mk_merge_stub() { cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exit 0
EOF
chmod +x "$1"; }

# ── Case 1: no drift → no-op ────────────────────────────────────────────────────────────────────
s="$(mk_sandbox)"; ( tool_env "$s"
  bash "$STPL" --mark >/dev/null 2>&1 )
out="$( tool_env "$s"; bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "1. no-drift → exit 0"
assert_contains "$out" "in sync" "1. no-drift → 'in sync' message"
assert_not_contains "$(git -C "$s/templates" branch --list 'sync-auto-*')" "sync-auto" "1. no branch cut"

# ── Case 2: drift + ported + gate passes → merge invoked + marker advanced ───────────────────────
s="$(mk_sandbox)"
porter="$s/porter.sh"; mk_porter_stub "$porter" "$s/templates/templates/govern/run-loop.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
drift_sha="$(git -C "$s/harness" rev-parse HEAD)"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  export STUB_STATUS=ported STUB_ADD_LINE='echo "run v2 generic mechanism"'
  bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "2. ported + gate pass → exit 0"
assert_contains "$(cat "$mrec" 2>/dev/null)" "meta-repo-harness 42" "2. merge-pr invoked for the PR"
assert_contains "$(cat "$s/harness/scripts/govern/.templates-synced-at" 2>/dev/null)" "$drift_sha" "2. marker advanced to live HEAD"
assert_not_contains "$(cat "$s/harness/governor/escalations.md")" "sync-port —" "2. no escalation on success"

# ── Case 3: drift + porter LEAKS a forbidden identity string → gate BLOCKS, NO merge, escalation ──
s="$(mk_sandbox)"
porter="$s/porter.sh"; mk_porter_stub "$porter" "$s/templates/templates/govern/run-loop.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  export STUB_STATUS=ported STUB_ADD_LINE='echo AcmeOrg deploy target'
  bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "3. forbidden-string leak → exit 1"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "3. merge NOT invoked on leak"
assert_contains "$(cat "$s/harness/governor/escalations.md")" "FORBIDDEN identity" "3. escalation filed with the leak reason"

# ── Case 4: drift + porter ESCALATES → NO merge, escalation filed ────────────────────────────────
s="$(mk_sandbox)"
porter="$s/porter.sh"; mk_porter_stub "$porter" "$s/templates/templates/govern/run-loop.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  export STUB_STATUS=escalated STUB_NO_COMMIT=1 STUB_ESCALATION="ambiguous whether this hunk is generic"
  bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "4. porter escalates → exit 1"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "4. merge NOT invoked on porter escalation"
assert_contains "$(cat "$s/harness/governor/escalations.md")" "ambiguous whether this hunk is generic" "4. escalation carries the porter reason"

# ── Case 5: --dry-run → prints plan, no branch, no merge ─────────────────────────────────────────
s="$(mk_sandbox)"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"; export GOVERN_MERGE_CMD="$merge"; bash "$TOOL" --dry-run 2>&1 )"; rc=$?
assert_eq "$rc" "0" "5. --dry-run → exit 0"
assert_contains "$out" "DRY RUN" "5. dry-run announces itself"
assert_contains "$out" "scripts/govern/run-loop.sh" "5. dry-run lists the drifted file"
assert_contains "$out" "would open a PR" "5. dry-run states it would open a PR"
assert_contains "$out" "acmeorg" "5. dry-run prints the forbidden identity strings"
assert_not_contains "$(git -C "$s/templates" branch --list 'sync-auto-*')" "sync-auto" "5. dry-run cuts NO branch"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "5. dry-run invokes NO merge"

# ── Case 6: lock held → exits 0 without acting ──────────────────────────────────────────────────
s="$(mk_sandbox)"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
lock="$s/held-lock"; mkdir -p "$lock"
out="$( tool_env "$s"; export GOVERN_SYNC_PORT_LOCK="$lock" GOVERN_MERGE_CMD="$merge"; bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "6. lock held → exit 0"
assert_contains "$out" "held by another run" "6. lock-held message"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "6. lock held → no merge"

# ── Case 7: escalations are NUMERIC `### #N` so the whole lifecycle sees them
s="$(mk_sandbox)"
porter="$s/porter.sh"; mk_porter_stub "$porter" "$s/templates/templates/govern/run-loop.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  export STUB_STATUS=escalated STUB_NO_COMMIT=1 STUB_ESCALATION="hunk ambiguous"
  bash "$TOOL" 2>&1 )"; rc=$?
esc="$(cat "$s/harness/governor/escalations.md")"
assert_eq "$rc" "1" "7. sync-port escalation exits 1"
assert_contains "$esc" "### #1 — sync-port:" "7. sync-port entry is NUMERIC (### #N)"
assert_contains "$esc" "**Opened:**" "7. numeric entry carries an Opened: stamp for the stale-ager"
dirty="$(git -C "$s/harness" status --porcelain -- governor/escalations.md 2>/dev/null)"
assert_eq "$dirty" "" "7. escalations.md committed same-step (no dirty tree)"

# ── Case 8: empty-diff porter → fail-closed BEFORE push/PR ────────────────────────────────
s="$(mk_sandbox)"
cat > "$s/porter-empty.sh" <<EOF
#!/usr/bin/env bash
git commit --allow-empty -qm "empty port attempt" >/dev/null 2>&1
git reset --hard origin/main >/dev/null 2>&1
report='{"status":"ported","files":["govern/run-loop.sh"]}'
[ -n "\${GOVERN_REPORT_PATH:-}" ] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$s/porter-empty.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$s/porter-empty.sh" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "8. empty-diff porter → exit 1"
esc="$(cat "$s/harness/governor/escalations.md")"
assert_contains "$esc" "sync-port:" "8. empty-diff → numeric sync-port escalation filed"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "8. empty-diff → merge NOT invoked"
cur_branch="$(git -C "$s/templates" rev-parse --abbrev-ref HEAD)"
assert_eq "$cur_branch" "main" "8. templates repo restored to main (no orphan branch)"

# ── Case 9: uncommitted-work strand — porter commits but leaves modification uncommitted ─────
s="$(mk_sandbox)"
cat > "$s/porter-strand.sh" <<EOF
#!/usr/bin/env bash
printf 'echo committed\n' >> templates/govern/run-loop.sh
git add -A >/dev/null 2>&1; git commit -qm "port change" >/dev/null 2>&1
printf 'echo stranded\n' >> templates/govern/run-loop.sh
report='{"status":"ported","files":["govern/run-loop.sh"]}'
[ -n "\${GOVERN_REPORT_PATH:-}" ] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$s/porter-strand.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$s/porter-strand.sh" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="/usr/bin/true"
  bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "9. uncommitted-work strand → exit 1"
esc="$(cat "$s/harness/governor/escalations.md")"
assert_contains "$esc" "UNCOMMITTED" "9. strand → escalation cites the uncommitted work"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "9. strand → merge NOT invoked"
cur_branch="$(git -C "$s/templates" rev-parse --abbrev-ref HEAD)"
assert_eq "$cur_branch" "main" "9. templates repo restored to main after strand"
dirty="$(git -C "$s/templates" status --porcelain 2>/dev/null)"
assert_eq "$dirty" "" "9. strand cleaned from templates worktree (no dirty files)"

# ── Case 10: fingerprint dedup — TWO runs against same drift produce ONE open entry ─────────
s="$(mk_sandbox)"
porter="$s/porter.sh"; mk_porter_stub "$porter" "$s/templates/templates/govern/run-loop.sh"
gh="$s/gh.sh"; mk_gh_stub "$gh"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
_scaffold_fail="$s/scaf-fail.sh"; printf '#!/usr/bin/env bash\nexit 7\n' > "$_scaffold_fail"; chmod +x "$_scaffold_fail"
run1="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="$_scaffold_fail"
  export STUB_STATUS=ported STUB_ADD_LINE='echo "generic v2"'
  bash "$TOOL" 2>&1 )"; rc1=$?
assert_eq "$rc1" "1" "10a. first run escalates on scaffold fail"
n_entries1="$(grep -c '^### #' "$s/harness/governor/escalations.md" || true)"
assert_eq "$n_entries1" "1" "10a. exactly ONE numeric escalation after first run"
run2="$( tool_env "$s"
  export GOVERN_CLAUDE_BIN="$porter" GOVERN_GH_BIN="$gh" GOVERN_MERGE_CMD="$merge"
  export GOVERN_SCAFFOLD_TEST_CMD="$_scaffold_fail"
  export STUB_STATUS=ported STUB_ADD_LINE='echo "generic v3"'
  bash "$TOOL" 2>&1 )"; rc2=$?
assert_eq "$rc2" "1" "10b. second run also escalates"
n_entries2="$(grep -c '^### #' "$s/harness/governor/escalations.md" || true)"
assert_eq "$n_entries2" "1" "10b. STILL exactly ONE entry after second run (dedup)"
assert_contains "$(cat "$s/harness/governor/escalations.md")" "Last-seen:" "10b. dedup wrote a Last-seen line"

# ── Case 11: GOVERN_UPSTREAM_HARNESS_REPO empty → mechanism inert ────────────────────────────
s="$(mk_sandbox)"
# Strip the upstream knob from the sandbox workspace.sh.
sed -i.bak 's|^GOVERN_UPSTREAM_HARNESS_REPO=.*|GOVERN_UPSTREAM_HARNESS_REPO=""|' "$s/harness/scripts/lib/workspace.sh"
rm -f "$s/harness/scripts/lib/workspace.sh.bak"
mrec="$s/merge-record.txt"; merge="$s/merge.sh"; mk_merge_stub "$merge" "$mrec"
out="$( tool_env "$s"; export GOVERN_MERGE_CMD="$merge"; bash "$TOOL" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "11. GOVERN_UPSTREAM_HARNESS_REPO empty → exit 0 (inert)"
assert_contains "$out" "feature off" "11. states that the feature is off"
assert_eq "$( [ -s "$mrec" ] && echo yes || echo no )" "no" "11. inert → no merge"

assert_done
