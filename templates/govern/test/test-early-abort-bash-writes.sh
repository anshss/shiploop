#!/usr/bin/env bash
# The stall detector's two false-positive defects, unit-tested against the real functions in
# lib/common.sh (no fixture of their output — every case below builds a transcript and runs the
# detector over it).
#
# Defect A — "edited a file" is not the same as "used the Edit tool". The stall signal used to reset
# ONLY on an Edit/Write/NotebookEdit tool_use, so a worker instructed to change files through the
# shell (`cat >`, `sed -i`, a heredoc) emitted zero reset tokens and read as stalled while it was
# converging perfectly. A Bash command that WRITES a file must now reset the same counter, and a
# read-only run must still trip STALL or the detector has been disabled rather than fixed.
#
# Defect B — the wall-clock watchdog denies every further tool call and tells the child to stop and
# report. A stop-blocking progress check on top of that leaves the child no legal move: it cannot
# produce a diff (tools denied) and cannot exit (stop blocked). govern::watchdog_denied reads that
# denial off the same transcript, and it is what lets the stop through.
#
# Covered here:
#   1. the write-shape matrix — which Bash commands count as a file write, and which deliberately
#      do not (a missed write only preserves the old behavior; a wrong match silences the detector)
#   2. a run whose only file changes are Bash writes → NO stall
#   3. a genuinely read-only run → STILL stalls
#   4. a Bash-write run that is ALSO an identical-command loop → LOOP still fires (the write reset
#      must not mask the other signatures)
#   5. govern::watchdog_denied — present in the tail, absent, stale (outside the window), missing
#      file, and the kill switch
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # seed the hermetic workspace stub BEFORE common.sh is sourced
# shellcheck source=/dev/null
source "$DIR/../lib/common.sh"

# ── fixture builders ────────────────────────────────────────────────────────────────────────────
# One assistant turn carrying a single Bash tool_use, plus its tool_result. jq builds the JSON so
# a command containing quotes, newlines or backslashes is encoded correctly rather than by hand.
bash_turn() { # <command>
  jq -cn --arg c "$1" \
    '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}],usage:{input_tokens:1,output_tokens:1}}}'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
}
read_turn() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
}

# counts_as_write <command> -> yes|no
# Runs the REAL projection and reports whether it emitted the file-write token for this command.
counts_as_write() {
  local f="$TMP/one.jsonl" out
  bash_turn "$1" > "$f"
  # Captured into a variable rather than piped into grep: under `set -o pipefail` a `grep -q` that
  # exits on its first match can SIGPIPE the producer and turn a match into a false negative.
  out="$(govern::early_abort_signals "$f")"
  if [[ $'\n'"$out"$'\n' == *$'\nW\n'* ]]; then echo yes; else echo no; fi
}

# ── 1. the write-shape matrix ───────────────────────────────────────────────────────────────────
# Counted: each of these mutates a file, and the shell shape alone is enough to know it.
assert_eq "$(counts_as_write 'cat > /tmp/f.txt')"                  yes "a redirect to a path is a write"
assert_eq "$(counts_as_write 'echo hi >> notes.md')"               yes "an append redirect is a write"
assert_eq "$(counts_as_write "printf x > 'my file.txt'")"          yes "a quoted redirect target is still a path"
assert_eq "$(counts_as_write 'bash t.sh >/tmp/out.log 2>&1')"      yes "a redirect with an fd dup beside it still counts"
assert_eq "$(counts_as_write "cat > f.py <<'PY'
print(1)
PY")"                                                              yes "a heredoc redirected to a file is a write"
assert_eq "$(counts_as_write 'npm run build | tee build.log')"     yes "tee to a path is a write"
assert_eq "$(counts_as_write 'foo | tee -a build.log')"            yes "tee -a to a path is a write"
assert_eq "$(counts_as_write "sed -i '' -e s/a/b/ f.txt")"         yes "sed -i is an in-place edit"
assert_eq "$(counts_as_write 'perl -i -pe s/a/b/ f.txt')"          yes "perl -i is an in-place edit"
assert_eq "$(counts_as_write 'mv a.txt b.txt')"                    yes "mv changes the tree"
assert_eq "$(counts_as_write 'cp a.txt b.txt')"                    yes "cp changes the tree"
assert_eq "$(counts_as_write 'truncate -s 0 f.log')"               yes "truncate changes a file"
assert_eq "$(counts_as_write 'git apply p.patch')"                 yes "git apply writes the working tree"
assert_eq "$(counts_as_write 'git commit -m wip')"                 yes "git commit is landed progress"

# NOT counted. Each line is a shape that must stay out: a write we miss only preserves the old
# behavior, but a read we count as a write silences the detector for the whole run.
assert_eq "$(counts_as_write 'printf x > /dev/null')"              no  "a redirect to /dev/null writes nothing"
assert_eq "$(counts_as_write 'echo done >&2')"                     no  "an fd dup is not a file"
assert_eq "$(counts_as_write 'npm test 2>&1 | tail -20')"          no  "2>&1 on a test run is not a file write"
assert_eq "$(counts_as_write 'foo | tee /dev/null')"               no  "tee /dev/null writes nothing"
assert_eq "$(counts_as_write 'grep -rn foo src/ | head')"          no  "grep is a read"
assert_eq "$(counts_as_write 'cat file.txt')"                      no  "cat with no redirect is a read"
assert_eq "$(counts_as_write 'ls -la')"                            no  "ls is a read"
assert_eq "$(counts_as_write 'find . -name *.sh')"                 no  "find is a read"
assert_eq "$(counts_as_write 'git log --oneline -5')"              no  "git log is a read, though git commit is not"
assert_eq "$(counts_as_write 'grep -i foo f | sed s/a/b/')"        no  "grep -i beside a sed is not an in-place edit"
assert_eq "$(counts_as_write 'echo "a -> b"')"                     no  "an arrow inside a string is not a redirect"
assert_eq "$(counts_as_write 'npm install')"                       no  "install is left out: the shape cannot be told from a package install"
assert_eq "$(counts_as_write "python3 - <<'PY'
open('a','w').write('x')
PY")"                                                              no  "a heredoc into an interpreter's stdin is left out: only the embedded program says whether it writes"

# ── 2. a run whose only file changes are Bash writes must NOT stall ─────────────────────────────
# 40 turns, every one a shell file write and not a single Edit tool_use — exactly the worker this
# detector used to trap.
{ for i in $(seq 1 40); do bash_turn "cat > /tmp/part-$i.txt <<EOF
chunk
EOF"; done; } > "$TMP/bash-writes.jsonl"
assert_eq "$(govern::early_abort_reason "$TMP/bash-writes.jsonl")" "" \
  "40 turns of shell file writes and zero Edit tool_use → NOT a stall"

# ── 3. a genuinely read-only run must STILL stall ───────────────────────────────────────────────
{ for i in $(seq 1 40); do read_turn; done; } > "$TMP/readonly.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/readonly.jsonl")" "STALL" \
  "40 read-only turns still trip STALL — the detector is fixed, not disabled"

# A read-only run that shells out constantly, but only to READ, is the same case: commands alone
# must not count as progress.
{ for i in $(seq 1 40); do bash_turn "grep -rn thing src/ | head -20"; done; } > "$TMP/read-cmds.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/read-cmds.jsonl")" "STALL" \
  "40 turns of read-only Bash commands still trip STALL"

# ── 4. the other signatures are untouched ───────────────────────────────────────────────────────
# The same failing command six times, each turn ALSO a real file write. The write reset must not
# mask the loop.
{ for i in $(seq 1 6); do bash_turn "npm test -- --run flaky"; bash_turn "cp a.txt b.txt"; done; } > "$TMP/loop.jsonl"
assert_contains "$(govern::early_abort_reason "$TMP/loop.jsonl")" "LOOP" \
  "an identically-repeated command still trips LOOP even when the worker is also writing files"

# ── 5. the wall-clock watchdog's deny marker ────────────────────────────────────────────────────
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

# STALE: the same marker, but far outside the tail window. A denial is terminal only while it is
# CURRENT (once tripped it denies every later call, so a real one is always at the end); an old
# mention — a child that read the watchdog's own source, say — must not disable its progress check.
{ cat "$TMP/denied.jsonl"; for i in $(seq 1 60); do read_turn; done; } > "$TMP/stale.jsonl"
govern::watchdog_denied "$TMP/stale.jsonl" && d4=yes || d4=no
assert_eq "$d4" "no" "a marker far outside the tail window is not a current denial"

GOVERN_WATCHDOG_MARKER_TAIL=0 govern::watchdog_denied "$TMP/denied.jsonl" && d5=yes || d5=no
assert_eq "$d5" "no" "GOVERN_WATCHDOG_MARKER_TAIL=0 disables the check"

assert_done
