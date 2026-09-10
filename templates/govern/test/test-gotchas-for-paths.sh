#!/usr/bin/env bash
# Rail 9 / #125: the interactive lane (Agent(subagent_type: "worker"), .claude/agents/worker.md)
# has no launcher to inject **Paths:**-tagged CLAUDE.md/learnings.md gotchas into its prompt the
# way spawn-worker.sh does for the headless lane (#118/#174) — that mechanism fires on the headless
# dispatch path only. gotchas-for-paths.sh is the interactive lane's own entry point into the SAME
# lookup: a worker subagent runs it directly, as its first step, on the paths it is about to touch.
#
# This pins the CLI wrapper AND (implicitly, since spawn-worker.sh now calls the very same
# function) that both lanes share ONE implementation — govern::gotcha_block in lib/common.sh — so
# they can never drift against each other the way a hand-forked second copy would.
#
# Cases:
#   1. A root CLAUDE.md entry tagged for a given path is present in the output.
#   2. The named sub-repo's own CLAUDE.md entry (repo-relative Paths) is present too.
#   3. An entry tagged for a path NOT passed as an argument is absent.
#   4. An entry with no `**Paths:**` field never appears.
#   5. A repo never named as an argument contributes nothing.
#   6. No candidate matches any tagged entry -> silent, empty output, exit 0.
#   7. GOVERN_GOTCHA_INJECT=0 suppresses the whole mechanism.
#   8. No arguments at all -> usage error, exit 2.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SCRIPT="$DIR/../gotchas-for-paths.sh"
[ -f "$SCRIPT" ] || { echo "SKIP: gotchas-for-paths.sh not found at $SCRIPT" >&2; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP" "alpha"   # REPOS = (alpha web)
mkdir -p "$TMP/alpha" "$TMP/web"

# Root CLAUDE.md: one entry tagged for the path under test, one tagged for a path never passed.
cat > "$TMP/CLAUDE.md" <<'EOF'
# root

### root gotcha for the pay path
**Paths:** alpha/src/pay/**
ROOT-PAY-GOTCHA-SENTINEL: root-level rule about the pay path.

### root gotcha for a path never passed
**Paths:** web/pages/**
ROOT-WEB-GOTCHA-SENTINEL: never named as an argument, must not appear.
EOF

# alpha's OWN CLAUDE.md: repo-relative Paths — one matching entry, one untagged.
cat > "$TMP/alpha/CLAUDE.md" <<'EOF'
# alpha

### alpha-local gotcha for the pay path
**Paths:** src/pay/**
ALPHA-PAY-GOTCHA-SENTINEL: sub-repo-local rule about the pay path.

### untagged alpha rule
No Paths field on this one at all.
ALPHA-UNTAGGED-SENTINEL: must never appear regardless of what it says.
EOF

# web's CLAUDE.md: web/ is never passed as a candidate path, so this must never even surface its
# own perfectly-tagged, otherwise-matching-shaped entry.
cat > "$TMP/web/CLAUDE.md" <<'EOF'
# web

### web gotcha
**Paths:** **
WEB-NEVER-CANDIDATE-SENTINEL: web/ is never named as an argument; must not appear.
EOF

run() { # <env assignments...> -- <path args...>
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env GOVERN_WS_ROOT="$TMP" \
      GOVERN_GOTCHA_INJECT=1 \
      ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@"
}

out="$(run -- "alpha/src/pay/charge.ts")"

assert_contains "$out" "ROOT-PAY-GOTCHA-SENTINEL" "1. root CLAUDE.md entry tagged for the given path is present"
assert_contains "$out" "ALPHA-PAY-GOTCHA-SENTINEL" "2. alpha's own CLAUDE.md entry (repo-relative Paths) is present"
assert_not_contains "$out" "ROOT-WEB-GOTCHA-SENTINEL" "3. an entry tagged for a path never passed is absent"
assert_not_contains "$out" "ALPHA-UNTAGGED-SENTINEL" "4. an entry with no **Paths:** field never appears"
assert_not_contains "$out" "WEB-NEVER-CANDIDATE-SENTINEL" "5. a repo never named as an argument contributes nothing"
assert_contains "$out" "Recorded gotchas for files this ticket touches" "the output carries the same heading the headless lane injects"

nomatch="$(run -- "alpha/src/unrelated/thing.ts")"
assert_eq "$nomatch" "" "6. no candidate matches a tagged entry -> silent, empty output"

off="$(run GOVERN_GOTCHA_INJECT=0 -- "alpha/src/pay/charge.ts")"
assert_eq "$off" "" "7. GOVERN_GOTCHA_INJECT=0 suppresses the whole mechanism"

if env GOVERN_WS_ROOT="$TMP" "$SCRIPT" >/dev/null 2>&1; then usage_rc=0; else usage_rc=$?; fi
assert_eq "$usage_rc" "2" "8. no arguments at all is a usage error (exit 2)"

assert_done
