#!/usr/bin/env bash
# A worker's cwd at session start is the meta-repo worktree root, so a sub-repo's own
# CLAUDE.md is never auto-loaded, and worker-prompt.md's "read the sub-repo CLAUDE.md" line is a
# pointer, not a handoff. govern::gotchas_in_file (lib/common.sh) + its spawn-worker.sh call site
# closes that for entries an author explicitly tagged `**Paths:**`: a ticket naming those files gets
# the tagged text INLINED into its dispatch prompt.
#
# Cases:
#   1. A root CLAUDE.md entry tagged for the ticket's path is present in the assembled prompt.
#   2. The TOUCHED sub-repo's own CLAUDE.md entry (repo-relative Paths) is present too.
#   3. A root learnings.md entry tagged for a path the ticket does NOT touch is absent.
#   4. The touched sub-repo's own learnings.md entry tagged for a DIFFERENT path in the SAME repo is
#      absent — proves file-level, not whole-repo, selection.
#   5. An entry with no `**Paths:**` field never appears, even though its file matched elsewhere.
#   6. A repo the ticket never mentions contributes nothing (its CLAUDE.md is never even opened).
#   7. GOVERN_GOTCHA_INJECT=0 suppresses the whole section.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP" "alpha"   # REPOS = (alpha web)
mkdir -p "$TMP/governor" "$TMP/alpha" "$TMP/web"

cat > "$TMP/tickets.md" <<'EOF'
## #701 — fix the pay charge handler
**Severity:** Medium
**Where:** alpha/src/pay/charge.ts

Refactor the charge path.

---
EOF
printf 'DOCTRINE-SENTINEL\n' > "$TMP/governor/preferences.md"
printf 'HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Root CLAUDE.md: one entry tagged for the ticket's path (repo-prefixed — root files see the full
# candidate token), one tagged for a path the ticket does NOT touch.
cat > "$TMP/CLAUDE.md" <<'EOF'
# root

### root gotcha for the pay path
**Paths:** alpha/src/pay/**
ROOT-PAY-GOTCHA-SENTINEL: root-level rule about the pay path.

### root gotcha for an untouched path
**Paths:** web/pages/**
ROOT-WEB-GOTCHA-SENTINEL: this ticket never touches web/, must not appear.
EOF

# Root learnings.md: same shape, same two-entries pattern, at the OTHER of the two scanned root files.
cat > "$TMP/learnings.md" <<'EOF'
# learnings

### 2026-09-01 — untouched-path learning
**Paths:** web/pages/**
ROOT-LEARNINGS-WEB-SENTINEL: unrelated to this ticket, must not appear.
EOF

# alpha's OWN CLAUDE.md: repo-relative Paths (no "alpha/" prefix) — one matching entry, one for a
# different path in the SAME repo (proves file-level selection, not whole-repo), one untagged.
cat > "$TMP/alpha/CLAUDE.md" <<'EOF'
# alpha

### alpha-local gotcha for the pay path
**Paths:** src/pay/**
ALPHA-PAY-GOTCHA-SENTINEL: sub-repo-local rule about the pay path.

### alpha-local gotcha for a different path
**Paths:** src/other/**
ALPHA-OTHER-GOTCHA-SENTINEL: same repo, different file, must not appear.

### untagged alpha rule
No Paths field on this one at all.
ALPHA-UNTAGGED-SENTINEL: must never appear regardless of what it says.
EOF

# alpha's OWN learnings.md: an entry for a different path in the same repo — absent.
cat > "$TMP/alpha/learnings.md" <<'EOF'
# alpha learnings

### 2026-09-02 — other-path learning
**Paths:** src/other/**
ALPHA-LEARNINGS-OTHER-SENTINEL: same repo, different file, must not appear.
EOF

# web's CLAUDE.md: the ticket never names a web/ path, so this must never even surface its own
# perfectly-tagged, otherwise-matching-shaped entry — the repo itself was never a candidate.
cat > "$TMP/web/CLAUDE.md" <<'EOF'
# web

### web gotcha
**Paths:** **
WEB-NEVER-CANDIDATE-SENTINEL: web/ is not named by the ticket at all; must not appear.
EOF

render() { # <env assignments...> -- <ticket>
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs" \
      GOVERN_WORKER_MODEL="sonnet" \
      GOVERN_SPAWN_PRINT_PROMPT=1 \
      GOVERN_GOTCHA_INJECT=1 \
      ${envs[@]+"${envs[@]}"} "$SPAWN" "$@"
}

out="$(render -- 701)"

assert_contains "$out" "ROOT-PAY-GOTCHA-SENTINEL" "1. root CLAUDE.md entry tagged for the touched path is inlined"
assert_contains "$out" "ALPHA-PAY-GOTCHA-SENTINEL" "2. alpha's own CLAUDE.md entry (repo-relative Paths) is inlined"
assert_not_contains "$out" "ROOT-WEB-GOTCHA-SENTINEL" "3a. root CLAUDE.md entry for an untouched path is absent"
assert_not_contains "$out" "ROOT-LEARNINGS-WEB-SENTINEL" "3b. root learnings.md entry for an untouched path is absent"
assert_not_contains "$out" "ALPHA-OTHER-GOTCHA-SENTINEL" "4a. alpha CLAUDE.md entry for a different file in the SAME repo is absent"
assert_not_contains "$out" "ALPHA-LEARNINGS-OTHER-SENTINEL" "4b. alpha learnings.md entry for a different file in the SAME repo is absent"
assert_not_contains "$out" "ALPHA-UNTAGGED-SENTINEL" "5. an entry with no **Paths:** field never appears"
assert_not_contains "$out" "WEB-NEVER-CANDIDATE-SENTINEL" "6. a repo the ticket never names contributes nothing"
assert_contains "$out" "Recorded gotchas for files this ticket touches" "the injected section carries its own heading"

off="$(render GOVERN_GOTCHA_INJECT=0 -- 701)"
assert_not_contains "$off" "ROOT-PAY-GOTCHA-SENTINEL" "7a. GOVERN_GOTCHA_INJECT=0 suppresses an otherwise-matching root entry"
assert_not_contains "$off" "ALPHA-PAY-GOTCHA-SENTINEL" "7b. GOVERN_GOTCHA_INJECT=0 suppresses an otherwise-matching sub-repo entry"
assert_not_contains "$off" "Recorded gotchas for files this ticket touches" "7c. GOVERN_GOTCHA_INJECT=0 drops the section heading entirely"

assert_done
