#!/usr/bin/env bash
# Guard test for govern-self-apply.sh — deterministic, no real Claude. A fake "agent" makes a
# specific edit; we assert the guards commit a safe edit and revert+escalate unsafe ones.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SA="$DIR/../govern-self-apply.sh"

# Build a clean sandbox harness git repo; echo its path.
mk_sandbox() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/scripts/govern/lib" "$T/scripts/govern/test" "$T/scripts/lib" "$T/governor" "$T/.claude"
  # govern-self-apply.sh sources the real common.sh, which sources $WS_ROOT/scripts/lib/workspace.sh.
  # The sandbox runs under GOVERN_WS_ROOT="$T", so seed a minimal workspace.sh there.
  printf '#!/usr/bin/env bash\nset -uo pipefail\nMETA_ROOT="${META_ROOT:-%s}"\nGITHUB_ORG="acme"\nREPOS=(alpha)\nGOVERN_MERGE_REPOS=(alpha)\nwsp_is_merge_repo() { [ "$1" = alpha ]; }\nwsp_repo_slug() { printf "%%s/%%s" "$GITHUB_ORG" "$1"; }\nwsp_repo_localdir() { printf "%%s/%%s" "$META_ROOT" "$1"; }\n' "$T" > "$T/scripts/lib/workspace.sh"
  for s in select-ticket await-ci merge-pr spawn-worker run-loop dry-run; do
    printf '#!/usr/bin/env bash\necho %s\n' "$s" > "$T/scripts/govern/$s.sh"
  done
  printf '# preferences (protected)\n- hard-stops here\n' > "$T/governor/preferences.md"
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
  printf '# improvements\n' > "$T/governor/improvements.md"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -q -m init )
  echo "$T"
}
run_sa() { # sandbox agentcmd
  GOVERN_WS_ROOT="$1" GOVERN_ESCALATIONS_FILE="$1/governor/escalations.md" \
    GOVERN_SELF_APPLY=1 GOVERN_SELFAPPLY_TEST_CMD=true GOVERN_APPLY_AGENT_CMD="$2" \
    bash "$SA" "$1/run" >/dev/null 2>&1 || true
}
commits() { ( cd "$1" && git log --oneline | grep -c 'self-improvement' || true ); }

# 1. SAFE edit to an allowed file → committed.
T1="$(mk_sandbox)"
run_sa "$T1" 'printf "\n# safe tweak\n" >> scripts/govern/run-loop.sh'
assert_eq "$(commits "$T1")" "1" "safe edit to an allowed file is committed"
assert_contains "$(cat "$T1/scripts/govern/run-loop.sh")" "safe tweak" "the safe edit persisted"

# 2. Edit to a PROTECTED file (not in allowlist) → reverted, escalated, no commit.
T2="$(mk_sandbox)"
run_sa "$T2" 'printf "x\n" >> governor/preferences.md'
assert_eq "$(commits "$T2")" "0" "protected-file edit is NOT committed"
assert_eq "$(cat "$T2/governor/preferences.md" | grep -c '^x$')" "0" "protected file was reverted clean"
assert_contains "$(cat "$T2/governor/escalations.md")" "BLOCKED" "a blocked-self-improvement escalation was filed"

# 3. Edit to an allowed file that touches a SAFETY-RAIL pattern → reverted, no commit.
T3="$(mk_sandbox)"
run_sa "$T3" 'printf "\nGOVERN_MAX_TICKETS=999\n" >> scripts/govern/run-loop.sh'
assert_eq "$(commits "$T3")" "0" "safety-rail pattern edit is NOT committed"
assert_eq "$(grep -c 'GOVERN_MAX_TICKETS=999' "$T3/scripts/govern/run-loop.sh")" "0" "safety-rail edit was reverted"

# 4. Blocked-self-apply escalation is NUMERIC (### #N + Opened:) so the whole lifecycle sees it
# (emit-pending / apply-answers / govern-health stale-ager). Regression for the item-1 fix — pre-fix
# these were `### self-improvement BLOCKED — …` free-form headings the parser ignored entirely.
T4="$(mk_sandbox)"
run_sa "$T4" 'printf "x\n" >> governor/preferences.md'
esc4="$(cat "$T4/governor/escalations.md")"
assert_contains "$esc4" "### #" "4. self-apply BLOCKED entry is numeric (### #N)"
assert_contains "$esc4" "**Opened:**" "4. entry carries an Opened: stamp for the stale-ager"
# committed same-step (#14) — no dirty escalations.md left on disk
dirty4="$(git -C "$T4" status --porcelain -- governor/escalations.md 2>/dev/null)"
assert_eq "$dirty4" "" "4. escalations.md committed same-step (no dirty tree)"
# emit-pending picks it up (numeric → lifecycle wired)
EMIT="$DIR/../escalations-emit-pending.sh"
env GOVERN_WS_ROOT="$T4" GOVERN_ESCALATIONS_FILE="$T4/governor/escalations.md" GOVERN_PENDING_FILE="$T4/pending.json" \
    GOVERN_BOOKKEEP_LOCK="$T4/bk.lock" GOVERN_NO_PUSH=1 bash "$EMIT" test-run >/dev/null 2>&1
n_pending="$(jq -r '.count' "$T4/pending.json" 2>/dev/null || echo 0)"
assert_eq "$n_pending" "1" "4. emit-pending picks up the numeric self-apply escalation"

rm -rf "$T1" "$T2" "$T3" "$T4"
assert_done
