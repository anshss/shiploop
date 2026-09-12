#!/usr/bin/env bash
# The progress signal behind the stall check, unit-tested against the real functions in
# lib/common.sh (no fixture of their output: every case builds a real transcript or a real git tree
# and runs the real function over it).
#
# THE DEFECT THIS LOCKS. The transcript-side signal counts Edit/Write/NotebookEdit tool_uses, so an
# agent that changes files through the shell emits none of them and reads as stalled while
# converging perfectly, and then has its stop refused. Classifying the COMMAND cannot fix that: a
# heredoc piped into an interpreter says nothing about whether the program inside it writes. So the
# question is asked of the filesystem instead, which no command idiom can hide from. The transcript
# function is deliberately left exactly as it was; the tree probe is the new evidence, and the hook
# is where the two meet (test-agent-progress-guard.sh cases 15 to 20).
#
# Covered here:
#   1. the transcript signal is unchanged: read-only turns stall, a heredoc-only run also "stalls"
#      by that measure alone, and the loop signature still fires
#   2. govern::progress_trees — the enclosing repo, its nested sub-repos, and their linked
#      worktrees, which is where a worker actually works
#   3. govern::tree_probe — the fingerprint moves on a new file and on a commit, holds still when
#      nothing happens, reports dirtiness, and answers NOTHING when it cannot resolve a tree
#   4. govern::watchdog_denied — present, absent, stale, missing file, kill switch
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # seed the hermetic workspace stub BEFORE common.sh is sourced
# shellcheck source=/dev/null
source "$DIR/../lib/common.sh"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
bash_turn() { # <command> — one assistant turn carrying a Bash tool_use, plus its tool_result.
  jq -cn --arg c "$1" \
    '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}],usage:{input_tokens:1,output_tokens:1}}}'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
}
read_turn() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
}

# ── 1. the transcript signal is unchanged ───────────────────────────────────────────────────────
{ for i in $(seq 1 40); do read_turn; done; } > "$TMP/readonly.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/readonly.jsonl")" "STALL" \
  "40 read-only turns still trip STALL: the transcript signal is intact"

{ for i in $(seq 1 40); do bash_turn "python3 - <<'PY'
open('part-$i.txt','w').write('chunk')
PY"; done; } > "$TMP/heredoc.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/heredoc.jsonl")" "STALL" \
  "a heredoc-only run ALSO reads as a stall from the transcript alone: this is why the tree probe exists, and why no command-text rule is added here"

{ for i in $(seq 1 6); do bash_turn "npm test -- --run flaky"; bash_turn "cp a.txt b.txt"; done; } > "$TMP/loop.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/loop.jsonl")" "LOOP" \
  "the identical-command signature is untouched"

# ── 2. which trees the probe resolves ───────────────────────────────────────────────────────────
mk_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q .
  git -C "$1" config user.email t@test; git -C "$1" config user.name t
  printf 'seed\n' > "$1/seed.txt"
  git -C "$1" add -A; git -C "$1" commit -qm init
}
META="$TMP/meta"; mk_repo "$META"          # the enclosing checkout
mk_repo "$META/subrepo"                     # a nested checkout, meta-repo shape
git -C "$META/subrepo" worktree add -q -b wt "$TMP/sub.wt" 2>/dev/null
trees="$(govern::progress_trees "$META")"
assert_contains "$trees" "$META" "the enclosing repo is fingerprinted"
assert_contains "$trees" "$META/subrepo" \
  "a NESTED sub-repo is fingerprinted too: a parent's git status never reports a nested checkout's files"
assert_contains "$trees" "$TMP/sub.wt" \
  "and every LINKED WORKTREE, which is where a worker actually works while the session stands elsewhere"

assert_eq "$(govern::progress_trees "$TMP/nowhere-at-all")" "" "a directory that does not exist resolves no trees"

# ── 3. the fingerprint ──────────────────────────────────────────────────────────────────────────
fp_of() { govern::tree_probe "$1" | sed -n 1p; }
dirty_of() { govern::tree_probe "$1" | sed -n 2p; }

CLEAN="$TMP/clean"; mk_repo "$CLEAN"
a="$(fp_of "$CLEAN")"
[ -n "$a" ] && got=yes || got=no
assert_eq "$got" "yes" "a resolvable clean checkout produces a fingerprint"
assert_eq "$(dirty_of "$CLEAN")" "0" "a clean checkout is not dirty"
assert_eq "$(fp_of "$CLEAN")" "$a" "the fingerprint holds still when nothing changes"

printf 'new\n' > "$CLEAN/added.txt"
b="$(fp_of "$CLEAN")"
[ "$b" != "$a" ] && moved=yes || moved=no
assert_eq "$moved" "yes" "a brand new UNTRACKED file moves the fingerprint: that is the common shape of real progress"
assert_eq "$(dirty_of "$CLEAN")" "1" "and the tree reads as dirty"

printf 'more\n' >> "$CLEAN/seed.txt"
c="$(fp_of "$CLEAN")"
[ "$c" != "$b" ] && moved2=yes || moved2=no
assert_eq "$moved2" "yes" "modifying a tracked file moves it too"

git -C "$CLEAN" add -A >/dev/null 2>&1; git -C "$CLEAN" commit -qm work
d="$(fp_of "$CLEAN")"
[ "$d" != "$c" ] && moved3=yes || moved3=no
assert_eq "$moved3" "yes" \
  "COMMITTING moves the fingerprint: committing empties the porcelain output, so without HEAD in the hash a worker that committed its work would look untouched"

# A commit with nothing else outstanding leaves a clean tree, and the probe says so rather than
# pretending the work is still visible. The fingerprint, not the dirty flag, is what carries it.
assert_eq "$(dirty_of "$CLEAN")" "0" "a fully committed tree with nothing ahead is clean again"

# ── 3b. no tree, no answer ──────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/plain"
assert_eq "$(govern::tree_probe "$TMP/plain" || true)" "" \
  "a directory that is not a git checkout answers NOTHING: a check that cannot tell must never be the one that denies"
assert_eq "$(govern::tree_probe "$TMP/does-not-exist" || true)" "" "a missing directory answers nothing"
assert_eq "$(govern::tree_probe "" || true)" "" "an empty start directory answers nothing"
assert_eq "$(GOVERN_PROGRESS_TREE_MAX=0 govern::tree_probe "$CLEAN" || true)" "" \
  "past GOVERN_PROGRESS_TREE_MAX the probe answers nothing rather than paying an unbounded fan-out"

# ── 4. the wall-clock watchdog's deny marker ────────────────────────────────────────────────────
mk_denied() { # <file> — a stalled transcript whose LAST turns carry the watchdog's deny text
  { for i in $(seq 1 40); do read_turn; done
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":"[AGENT WATCHDOG] wall-clock: this child has been running ~3612s, past the 3600s cap (GOVERN_AGENT_WALLCLOCK). Do not start another tool call. Stop now and return your final response as your structured report."}]}}\n'
  } > "$1"
}
mk_denied "$TMP/denied.jsonl"
govern::watchdog_denied "$TMP/denied.jsonl" && d=yes || d=no
assert_eq "$d" "yes" "a watchdog denial in the child's recent turns is detected off the transcript"

govern::watchdog_denied "$TMP/readonly.jsonl" && d2=yes || d2=no
assert_eq "$d2" "no" "a transcript with no denial is not reported as denied"

govern::watchdog_denied "$TMP/does-not-exist.jsonl" && d3=yes || d3=no
assert_eq "$d3" "no" "a missing transcript reads as no evidence of a denial, never as denied"

# STALE: the same marker, far outside the tail window. A denial is terminal only while it is
# CURRENT (once tripped it denies every later call, so a real one is always at the end); an old
# mention, from a child that read the watchdog's own source say, must not disable its progress check.
{ cat "$TMP/denied.jsonl"; for i in $(seq 1 60); do read_turn; done; } > "$TMP/stale.jsonl"
govern::watchdog_denied "$TMP/stale.jsonl" && d4=yes || d4=no
assert_eq "$d4" "no" "a marker far outside the tail window is not a current denial"

GOVERN_WATCHDOG_MARKER_TAIL=0 govern::watchdog_denied "$TMP/denied.jsonl" && d5=yes || d5=no
assert_eq "$d5" "no" "GOVERN_WATCHDOG_MARKER_TAIL=0 disables the check"

assert_done
