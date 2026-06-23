#!/usr/bin/env bash
# Guard test for the ticket-sweep Stop hook + SessionStart snapshot (aquanode #61).
# Builds a sandbox "main checkout" (owns tickets.md) and a "worktree" with one
# sub-repo, then drives session-snapshot.sh and ticket-sweep-reminder.sh through
# the #61 "Done when" scenarios — all deterministic, no real Claude, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# Both hooks install to scripts/ at scaffold time (see commands/setup.md), so from
# scripts/govern/test/ they sit two levels up.
SNAP="$DIR/../../session-snapshot.sh"
SWEEP="$DIR/../../ticket-sweep-reminder.sh"

# Discover the workspace's first sub-repo generically — the fingerprint iterates the
# REAL REPOS list from workspace.sh, so the sandbox sub-repo must be a name it knows.
# shellcheck source=../../lib/workspace.sh
source "$DIR/../../lib/workspace.sh"
REPO="${REPOS[0]}"

# Build a sandbox: $T/main (tickets.md) + $T/wt (worktree.env + sub-repo $REPO).
# Echoes $T.
mk_sandbox() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/main" "$T/wt"
  ( cd "$T/main" && git init -q && git config user.email t@t && git config user.name t \
      && printf '## #99 — placeholder\n' > tickets.md && git add -A && git commit -q -m init )
  printf 'export WORKTREE_NAME=test\n' > "$T/wt/worktree.env"
  ( cd "$T/wt" && mkdir "$REPO" && cd "$REPO" && git init -q \
      && git config user.email t@t && git config user.name t \
      && printf 'v1\n' > app.txt && git add -A && git commit -q -m init )
  echo "$T"
}

# run the SessionStart snapshot for <session_id> against sandbox <T>. META_ROOT is the
# generic test seam (workspace.sh honors the env override) — the snapshot reads it as MAIN.
snap() { printf '{"session_id":"%s","cwd":"%s/wt"}' "$2" "$1" \
  | META_ROOT="$1/main" bash "$SNAP"; }

# run the Stop hook for <session_id> against sandbox <T>; capture its stdout
sweep() { printf '{"session_id":"%s","cwd":"%s/wt","stop_hook_active":false}' "$2" "$1" \
  | META_ROOT="$1/main" TMPDIR="${TMPDIR:-/tmp}" bash "$SWEEP"; }

dirty_subrepo() { printf 'changed\n' >> "$1/wt/$REPO/app.txt"; }
commit_subrepo() { ( cd "$1/wt/$REPO" && git add -A && git commit -q -m work ); }

# Use a private TMPDIR per run so baseline/marker files never collide across cases.
export TMPDIR; TMPDIR="$(mktemp -d)"

# ── 1. Prior-session RESIDUE, no NEW work this session → stops silently ──
T="$(mk_sandbox)"
dirty_subrepo "$T"          # residue exists BEFORE the session starts
snap "$T" sess1             # baseline captures the residue
out="$(sweep "$T" sess1)"
assert_eq "$out" "" "residue present at session start + no new work → silent (no block)"

# ── 2. NEW code work after the baseline → fires the reminder ──
T="$(mk_sandbox)"
snap "$T" sess2             # clean baseline
dirty_subrepo "$T"          # new edit THIS session
out="$(sweep "$T" sess2)"
assert_contains "$out" '"decision":"block"' "new uncommitted work after baseline → fires"

# ── 3. Residue AND new work → still fires (long session that does work) ──
T="$(mk_sandbox)"
dirty_subrepo "$T"          # residue
snap "$T" sess3
commit_subrepo "$T"         # new commit THIS session (HEAD advances vs baseline)
out="$(sweep "$T" sess3)"
assert_contains "$out" '"decision":"block"' "residue + a new commit this session → fires"

# ── 4. New commit after baseline (the classic "ahead of origin" case) → fires ──
T="$(mk_sandbox)"
snap "$T" sess4
dirty_subrepo "$T"; commit_subrepo "$T"
out="$(sweep "$T" sess4)"
assert_contains "$out" '"decision":"block"' "fresh commit after a clean baseline → fires"

# ── 5. tickets.md edited this session → fires ──
T="$(mk_sandbox)"
snap "$T" sess5
printf '## #100 — new\n' >> "$T/main/tickets.md"
out="$(sweep "$T" sess5)"
assert_contains "$out" '"decision":"block"' "tickets.md changed this session → fires"

# ── 6. At-most-once: after a fire drops the marker, a second stop is silent ──
T="$(mk_sandbox)"
snap "$T" sess6
dirty_subrepo "$T"
out1="$(sweep "$T" sess6)"; out2="$(sweep "$T" sess6)"
assert_contains "$out1" '"decision":"block"' "first stop fires"
assert_eq "$out2" "" "second stop is short-circuited by the once-per-session marker"

# ── 7. stop_hook_active=true → never re-fire inside its own loop ──
T="$(mk_sandbox)"
snap "$T" sess7
dirty_subrepo "$T"
out="$(printf '{"session_id":"sess7","cwd":"%s/wt","stop_hook_active":true}' "$T" \
  | META_ROOT="$T/main" bash "$SWEEP")"
assert_eq "$out" "" "stop_hook_active honored → silent"

# ── 8. Snapshot is idempotent: resume/compact must NOT rebase the baseline ──
T="$(mk_sandbox)"
snap "$T" sess8                          # original clean baseline
base="$TMPDIR/metarepo-ticket-sweep-baseline-sess8"
first="$(cat "$base")"
dirty_subrepo "$T"
snap "$T" sess8                          # a second SessionStart (resume) — must be a no-op
assert_eq "$(cat "$base")" "$first" "second SessionStart keeps the ORIGINAL baseline"
out="$(sweep "$T" sess8)"
assert_contains "$out" '"decision":"block"' "work since the ORIGINAL baseline still fires after resume"

# ── 9. No-baseline fallback (session predates the hook): clean → silent, dirty → fires ──
T="$(mk_sandbox)"                        # NO snap call → no baseline file
out="$(sweep "$T" sess9clean)"
assert_eq "$out" "" "no baseline + clean tree → absolute fallback stays silent"
dirty_subrepo "$T"
out="$(sweep "$T" sess9clean)"
assert_contains "$out" '"decision":"block"' "no baseline + dirty tree → absolute fallback fires"

assert_done
