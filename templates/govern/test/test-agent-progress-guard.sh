#!/usr/bin/env bash
# agent-progress-guard.sh — the SubagentStop + TeammateIdle hook that applies the deterministic
# doom signature (govern::early_abort_reason in lib/common.sh) to in-session `Agent`
# children, which have no pid and no external process for anything to poll.
#
# Covered here, on SubagentStop:
#   1. STALL    — many read-only turns right before the child tries to stop → blocked, surfaced
#                 as a fleet event
#   2. LOOP     — the same Bash command repeated identically → blocked, quotes the command
#   3. HEALTHY  — edits throughout, same turn count → NOT blocked, no event
#   4. DEFAULT ON — GOVERN_AGENT_SUPERVISION unset, on the SAME doomed transcript → blocked: the
#                   mechanism ships ON by default (an inert-by-default gate is the defect this
#                   design is written against)
#   5. KILL SWITCH — GOVERN_AGENT_SUPERVISION=0 explicitly, on the SAME doomed transcript → no
#                    block, no event: the operator can still turn it off
#   6. RE-ENTRANCY — stop_hook_active:true on a doomed transcript → no block (never adds a THIRD
#                    loop turn on top of Claude Code's own stop-hook block cap)
#   7. MISSING agent_transcript_path → no block, no crash
#   15. TREE CHANGED — 40 turns whose only file changes came from a heredoc piped into an
#       interpreter, so zero Edit tool_use: blocked while the tree is clean, ALLOWED once the tree
#       actually changes. The filesystem is the signal, not the shape of the command.
#   16. WATCHDOG-CAPPED — a stalled transcript whose last turns carry the wall-clock watchdog's own
#       deny text → NOT blocked. The watchdog has already denied every tool call and told the child
#       to stop and report; refusing the stop on top of that leaves it no legal move at all.
#   17. DIRTY TREE, NO BASELINE — uncommitted work on disk on the first look → allowed.
#   18. READ-ONLY AGENT TYPES — a lookup and an investigator are never stalled, however read-only
#       their turns look: producing no diff is what success looks like for them.
#   19. UNRESOLVABLE TREE — cwd is not a git checkout, so the tree check cannot tell → allowed.
#       A check that cannot tell must never be the thing that denies a stop.
#   20. THE GATES DO NOT WIDEN — a lookup child in an identical-command loop is still blocked.
#   8. NO PRIVATE COPY — the STALL reason text this hook emits for a transcript is byte-identical
#      to calling govern::early_abort_reason() directly on the SAME transcript, because the hook
#      calls the shared function rather than reimplementing its own copy.
#
# Covered here, on TeammateIdle (an idle notification is not evidence of anything at all —
# a worker correctly blocked on a background task presents identically to a stalled one, so this
# path alarms but never blocks):
#   9.  IDLE STALL, via agent_transcript_path  → fleet event with signal=idle, NO block decision
#   10. IDLE STALL, via transcript_path only (no agent_transcript_path present) → same alarm —
#       the field this event actually carries is unverified against a live payload, so the hook
#       tries both rather than assuming one
#   11. IDLE HEALTHY → no alarm
#   12. IDLE, kill switch off → no alarm even on a doomed transcript
#   13. IDLE, missing both transcript fields → silent no-op, no crash
#   14. the idle alarm is a FLEET event and deliberately NOT a lever event (see the case itself)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

# Two layouts: scripts/agent-progress-guard.sh in a scaffolded workspace,
# templates/hooks/agent-progress-guard.sh in the hub repo. GOVERN_HOOKS_DIR (from assert.sh)
# resolves whichever one we're in.
GUARD="$GOVERN_HOOKS_DIR/agent-progress-guard.sh"
[ -f "$GUARD" ] || { echo "SKIP: agent-progress-guard.sh not found under $GOVERN_HOOKS_DIR"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # exports GOVERN_WS_ROOT so the guard's common.sh source resolves hermetically

# STALL transcript: 40 assistant turns, all Read, zero file mutations — the same shape
# govern::early_abort_reason detects in any worker transcript.
gen_stall() {
  for i in $(seq 1 40); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_stall > "$TMP/stall.jsonl"

# HEALTHY transcript: same turn count, edits interleaved throughout.
gen_healthy() {
  for i in $(seq 1 40); do
    if (( i % 3 == 0 )); then name=Edit; else name=Read; fi
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n' "$name"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_healthy > "$TMP/healthy.jsonl"

# LOOP transcript: 6 turns, the SAME Bash command every time, edits interleaved so STALL can
# never be what fires — isolates the loop detector.
gen_loop() {
  for i in $(seq 1 6); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test -- --run flaky"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.txt"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_loop > "$TMP/loop.jsonl"

# HEREDOC transcript: the same 40 turns as the STALL one, but every turn pipes a heredoc into an
# interpreter, which is the dominant file-writing idiom in a shell-first environment. Not one
# Edit/Write tool_use anywhere, and nothing in the command TEXT can tell you whether the program
# inside the heredoc writes a file. This is the shape that used to trip STALL.
gen_heredoc() {
  for i in $(seq 1 40); do
    jq -cn --arg c "python3 - <<'PY'
open('part-$i.txt','w').write('chunk')
PY" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}],usage:{input_tokens:1,output_tokens:1}}}'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}\n'
  done
}
gen_heredoc > "$TMP/heredoc.jsonl"

# ── the working trees the guard fingerprints ───────────────────────────────────────────────────
# mk_git_repo <dir> — a real git checkout with one commit, left CLEAN. The guard resolves the tree
# from the payload's cwd, so every case below points cwd at one of these.
mk_git_repo() {
  mkdir -p "$1"
  git -C "$1" init -q .
  git -C "$1" config user.email t@test; git -C "$1" config user.name t
  printf 'seed\n' > "$1/seed.txt"
  git -C "$1" add -A; git -C "$1" commit -qm init
}
mk_git_repo "$TMP/tree-clean"    # stays clean for every case that must still block
mk_git_repo "$TMP/tree-work"     # case 15 changes this one between two guard invocations
mk_git_repo "$TMP/tree-dirty"
printf 'uncommitted\n' > "$TMP/tree-dirty/scratch.txt"   # case 17: work on disk, never committed
mkdir -p "$TMP/not-a-repo"       # case 19: cwd the guard cannot resolve a tree from

# WATCHDOG-CAPPED transcript: a genuinely stalled run (so the progress check DOES fire) whose last
# tool_result is the wall-clock watchdog's own denial, verbatim from agent-watchdog-guard.sh.
{ gen_stall
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":"[AGENT WATCHDOG] wall-clock: this child (agent_id=a16, agent_type=worker) has been running ~3612s, past the 3600s cap (GOVERN_AGENT_WALLCLOCK). Do not start another tool call. Stop now and return your final response as your structured report."}]}}\n'
} > "$TMP/watchdog-capped.jsonl"

# run_guard <transcript> <agent_id> <stop_hook_active> [extra env assignments...]
#
# Field is agent_transcript_path, NOT transcript_path: verified live (2026-09-10, claude 2.1.246)
# that on a real SubagentStop event, `transcript_path` is the PARENT session's own transcript —
# `agent_transcript_path` is the child's. This fixture mirrors the real payload shape exactly (it
# also carries a `transcript_path` pointing somewhere else, to catch a regression that reads the
# wrong field back).
# GUARD_CWD is the tree the guard will fingerprint (the payload's cwd). It defaults to a CLEAN
# checkout so the stall cases below still reach a block: the tree check can only ever suppress a
# stall, so a case that asserts a block has to be standing somewhere that genuinely has no work in
# it. GUARD_AGENT_TYPE drives the read-only exemption.
GUARD_CWD="$TMP/tree-clean"
GUARD_AGENT_TYPE="general-purpose"
# The guard stores its per-agent tree fingerprint under ${TMPDIR:-/tmp}, so point TMPDIR into this
# run's own scratch directory. Without it the SECOND run of this file would read the FIRST run's
# fingerprints back for the same agent ids, see a different tree, and read every block case as
# progress. Hermetic per run, and it exercises the real state path rather than stubbing it out.
mkdir -p "$TMP/state"
run_guard() {
  local transcript="$1" agent_id="$2" active="$3"; shift 3
  printf '{"session_id":"s-%s","cwd":"%s","transcript_path":"%s/PARENT-not-the-childs.jsonl","agent_transcript_path":"%s","agent_id":"%s","agent_type":"%s","stop_hook_active":%s}' \
      "$agent_id" "$GUARD_CWD" "$TMP" "$transcript" "$agent_id" "$GUARD_AGENT_TYPE" "$active" \
    | env TMPDIR="$TMP/state" "$@" bash "$GUARD"
}

# run_guard_idle <transcript> <agent_id> <via> [extra env assignments...]
#
# <via> is "agent" (payload carries agent_transcript_path, the SubagentStop shape) or "plain"
# (payload carries ONLY transcript_path — no agent_transcript_path at all). TeammateIdle's real
# payload shape is unverified beyond Claude Code's generic hook docs, so the hook tries both
# fields; these two shapes are what "tries both" actually needs covered.
run_guard_idle() {
  local transcript="$1" agent_id="$2" via="$3"; shift 3
  if [ "$via" = "agent" ]; then
    printf '{"session_id":"s-%s","cwd":"%s","hook_event_name":"TeammateIdle","agent_transcript_path":"%s","agent_id":"%s","agent_type":"worker"}' \
        "$agent_id" "$GUARD_CWD" "$transcript" "$agent_id" \
      | env TMPDIR="$TMP/state" "$@" bash "$GUARD"
  else
    printf '{"session_id":"s-%s","cwd":"%s","hook_event_name":"TeammateIdle","transcript_path":"%s","agent_id":"%s","agent_type":"worker"}' \
        "$agent_id" "$GUARD_CWD" "$transcript" "$agent_id" \
      | env TMPDIR="$TMP/state" "$@" bash "$GUARD"
  fi
}

# ── 1. STALL, supervision ON ───────────────────────────────────────────────────────────────────
events1="$TMP/events-1.jsonl"
out1="$(run_guard "$TMP/stall.jsonl" a1 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events1")"
assert_contains "$out1" '"decision":"block"' "STALL on a subagent about to stop → the stop is blocked"
assert_contains "$out1" "STALL" "the block reason carries the deterministic signature that fired"
assert_contains "$(cat "$events1" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "STALL is surfaced as a fleet event — an operator watching fleet-monitor.sh sees it without opening a transcript"
assert_contains "$(cat "$events1" 2>/dev/null || true)" '"agent_id":"a1"' \
  "the event identifies WHICH subagent instance alarmed"

# ── 2. LOOP, supervision ON ─────────────────────────────────────────────────────────────────────
out2="$(run_guard "$TMP/loop.jsonl" a2 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EARLY_ABORT_REPEATS=5)"
assert_contains "$out2" '"decision":"block"' "an identically-repeated command → blocked"
assert_contains "$out2" "LOOP" "the loop signature is the one reported, not the stall one"
assert_contains "$out2" "npm test" "the block reason quotes the repeated command"

# ── 3. HEALTHY, supervision ON — must NOT fire ─────────────────────────────────────────────────
events3="$TMP/events-3.jsonl"
out3="$(run_guard "$TMP/healthy.jsonl" a3 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events3")"
assert_eq "$out3" "" "a subagent editing files throughout is NOT blocked, at the same turn count"
[ -s "$events3" ] && has3=yes || has3=no
assert_eq "$has3" "no" "no fleet event for a healthy stop"

# ── 4. DEFAULT ON — the SAME doomed transcript, GOVERN_AGENT_SUPERVISION unset ─────────────────
events4="$TMP/events-4.jsonl"
out4="$(run_guard "$TMP/stall.jsonl" a4 false GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events4")"
assert_contains "$out4" '"decision":"block"' "GOVERN_AGENT_SUPERVISION unset → defaults ON: the doomed subagent IS blocked"
assert_contains "$(cat "$events4" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "the default-on path still surfaces the fleet event"

# ── 5. KILL SWITCH — GOVERN_AGENT_SUPERVISION=0 explicitly, on the SAME doomed transcript ──────
events5="$TMP/events-5.jsonl"
out5a="$(run_guard "$TMP/stall.jsonl" a5b false GOVERN_AGENT_SUPERVISION=0 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events5")"
assert_eq "$out5a" "" "GOVERN_AGENT_SUPERVISION=0 → the doomed subagent is NOT blocked"
[ -s "$events5" ] && has5=yes || has5=no
assert_eq "$has5" "no" "the kill switch suppresses the fleet event too — fully inert, not just silent-on-stdout"

# ── 6. RE-ENTRANCY — stop_hook_active:true on the same doomed transcript ───────────────────────
out5="$(run_guard "$TMP/stall.jsonl" a5 true GOVERN_AGENT_SUPERVISION=1)"
assert_eq "$out5" "" "stop_hook_active:true → never re-fires a block on top of Claude Code's own cap"

# ── 7. MISSING agent_transcript_path → no crash, no block ─────────────────────────────────────
out6="$(printf '{"session_id":"s6","cwd":"%s","agent_id":"a6","agent_type":"lookup","stop_hook_active":false}' "$TMP" \
  | env GOVERN_AGENT_SUPERVISION=1 bash "$GUARD")"
assert_eq "$out6" "" "no agent_transcript_path on stdin → silent no-op, never a crash"

# ── 8. NO PRIVATE COPY — the hook's verdict matches calling the shared function directly ────────
# Drive govern::early_abort_reason() out of the SAME lib/common.sh this hook sources, directly
# (bypassing the hook's own transcript-reading plumbing), and compare its verdict on the STALL
# transcript to the hook's.
SPAWN_DIR="$(dirname "$GUARD")"
common="$SPAWN_DIR/govern/lib/common.sh"; [ -f "$common" ] || common="$SPAWN_DIR/../govern/lib/common.sh"
if [ -f "$common" ]; then
  direct="$(GOVERN_WS_ROOT="$TMP" bash -c '. "'"$common"'" && govern::early_abort_reason "'"$TMP"'/stall.jsonl"')"
  assert_contains "$out1" "$direct" \
    "the hook's block reason is the SAME string govern::early_abort_reason computes directly — one signature, not a private copy"
fi

# ── 9. IDLE STALL via agent_transcript_path — alarm, NEVER a block decision ────────────────────
events9="$TMP/events-9.jsonl"
out9="$(run_guard_idle "$TMP/stall.jsonl" a9 agent GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events9")"
assert_eq "$out9" "" "TeammateIdle is not a stop — a doom signature never becomes a block decision on this path"
assert_contains "$(cat "$events9" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "the STALL signature still reaches the fleet event log on the idle path"
assert_contains "$(cat "$events9" 2>/dev/null || true)" '"signal":"idle"' \
  "the idle-sourced alarm is tagged so it reads differently from a SubagentStop alarm"

# ── 10. IDLE STALL via transcript_path only — the agent_transcript_path fallback ───────────────
events10="$TMP/events-10.jsonl"
out10="$(run_guard_idle "$TMP/stall.jsonl" a10 plain GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events10")"
assert_eq "$out10" "" "no block on this path even when the fallback field is what carried the transcript"
assert_contains "$(cat "$events10" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "falling back to transcript_path still reaches the same alarm when agent_transcript_path is absent"

# ── 11. IDLE HEALTHY — must NOT fire ────────────────────────────────────────────────────────────
events11="$TMP/events-11.jsonl"
out11="$(run_guard_idle "$TMP/healthy.jsonl" a11 agent GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events11")"
assert_eq "$out11" "" "a healthy transcript produces no output on the idle path either"
[ -s "$events11" ] && has11=yes || has11=no
assert_eq "$has11" "no" "no fleet event for an idle notification with no doom signature — idle alone is never evidence"

# ── 12. IDLE, kill switch off — no alarm even on a doomed transcript ───────────────────────────
events12="$TMP/events-12.jsonl"
out12="$(run_guard_idle "$TMP/stall.jsonl" a12 agent GOVERN_AGENT_SUPERVISION=0 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events12")"
assert_eq "$out12" "" "kill switch applies identically on the idle path"
[ -s "$events12" ] && has12=yes || has12=no
assert_eq "$has12" "no" "GOVERN_AGENT_SUPERVISION=0 suppresses the idle alarm too"

# ── 13. IDLE, missing both transcript fields → silent no-op, no crash ─────────────────────────
out13="$(printf '{"session_id":"s13","cwd":"%s","hook_event_name":"TeammateIdle","agent_id":"a13","agent_type":"worker"}' "$TMP" \
  | env GOVERN_AGENT_SUPERVISION=1 bash "$GUARD")"
assert_eq "$out13" "" "neither agent_transcript_path nor transcript_path present → silent no-op, never a crash"

# ── 14. the idle alarm is DELIBERATELY NOT a lever event ───────────────────────────────────────
# Decided when bench caught up with the post-09ab731 mechanisms: agent_progress_alarm stays on the
# fleet event log (GOVERN_EVENTS) and is NOT promoted to a lever event (GOVERN_LEVER_EVENTS).
#
# The reason, and the reason this is a test rather than a comment: every lever bench credits is a
# lever that REMOVES tokens from the counterfactual, and this one removes none. The TeammateIdle
# branch cannot block by construction (there is no stop to hold open), so it terminates nothing and
# truncates nothing; the SubagentStop branch blocks a stop, which makes the child work LONGER, not
# shorter. Crediting it would be crediting an observation as a saving. Recorded as a named
# exclusion in bench/KNOWN-LIMITS.md, and locked here so nobody quietly adds an emitter without
# moving that entry: the alarm firing must produce a fleet event and NO lever event.
events14="$TMP/events-14.jsonl"
lever14="$TMP/lever-14.jsonl"
out14="$(run_guard_idle "$TMP/stall.jsonl" a14 agent GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 \
  GOVERN_EVENTS_FILE="$events14" GOVERN_LEVER_EVENTS=1 GOVERN_LEVER_EVENTS_FILE="$lever14")"
assert_eq "$out14" "" "the idle path still never blocks"
assert_contains "$(cat "$events14")" "agent_progress_alarm" "the idle alarm IS surfaced, on the fleet event log"
[ -f "$lever14" ] && haslev14=yes || haslev14=no
assert_eq "$haslev14" "no" "and is NOT a lever event: it removes no tokens, so bench must not credit it"

# ── 15. TREE CHANGED — the heredoc worker, blocked while clean and allowed once it writes ──────
# Same turn count as the STALL transcript and the same absence of any Edit tool_use. Run twice
# against the SAME agent id: the first look establishes the fingerprint, then a real file lands in
# the tree and the second look must see it. This is the case the command-shape approach could not
# answer, because the command text says nothing about whether the embedded program writes.
GUARD_CWD="$TMP/tree-work"
out15a="$(run_guard "$TMP/heredoc.jsonl" a15 false GOVERN_AGENT_SUPERVISION=1)"
assert_contains "$out15a" '"decision":"block"' \
  "first look, clean tree: a heredoc-only run with nothing on disk to show for it is still blocked"
assert_contains "$out15a" "working tree has not changed" \
  "and the block reason says so, instead of claiming only Edit/Write/NotebookEdit count"

printf 'real work\n' > "$TMP/tree-work/part-1.txt"
events15="$TMP/events-15.jsonl"
out15b="$(run_guard "$TMP/heredoc.jsonl" a15 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events15")"
assert_eq "$out15b" "" \
  "the tree changed between the two looks, so the child is converging and its stop goes through"
[ -s "$events15" ] && has15=yes || has15=no
assert_eq "$has15" "no" "no fleet alarm either: it was never stalling"

# A THIRD look with nothing further written must block again, so case 15 proves the fingerprint is
# what changed the outcome rather than the agent id having been seen before.
GUARD_CWD="$TMP/tree-work"
out15c="$(run_guard "$TMP/heredoc.jsonl" a15 false GOVERN_AGENT_SUPERVISION=1)"
assert_contains "$out15c" '"decision":"block"' "an unchanged tree on the next look is a stall again"
GUARD_CWD="$TMP/tree-clean"

# ── 16. WATCHDOG-CAPPED — a stalled child that has already been denied its tools ────────────────
# The stop must go through. This child cannot land a diff (every tool call is denied) and the
# watchdog has explicitly told it to stop and report; blocking the stop leaves it no legal move and
# it burns its remaining turns arguing with two rails that contradict each other.
events16="$TMP/events-16.jsonl"
out16="$(run_guard "$TMP/watchdog-capped.jsonl" a16 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events16")"
assert_not_contains "$out16" "decision" "a watchdog-denied child is allowed to stop and report"
assert_eq "$out16" "" "no block decision at all on the terminal path"
assert_contains "$(cat "$events16" 2>/dev/null || true)" '"type":"agent_progress_alarm"' \
  "the alarm still fires — an operator should see the child both stalled AND was capped"

# The SAME transcript without the watchdog's marker still blocks, so case 16 proves the marker is
# what changed the outcome and not the transcript shape.
out16b="$(run_guard "$TMP/stall.jsonl" a16b false GOVERN_AGENT_SUPERVISION=1)"
assert_contains "$out16b" '"decision":"block"' "without the watchdog marker the same stalled shape is still blocked"

# ── 17. DIRTY TREE, NO BASELINE — the first look at a child that already has work on disk ───────
# There is no previous fingerprint to compare against on a child's first check, and uncommitted work
# is the honest evidence that it has produced something. Fail open and believe it.
GUARD_CWD="$TMP/tree-dirty"
out17="$(run_guard "$TMP/stall.jsonl" a17 false GOVERN_AGENT_SUPERVISION=1)"
assert_eq "$out17" "" "uncommitted work on disk on the first look → the stop is allowed"
GUARD_CWD="$TMP/tree-clean"

# ── 18. READ-ONLY AGENT TYPES are never stalled ────────────────────────────────────────────────
# The SAME read-only transcript and the SAME clean tree that blocks a general-purpose child. A
# lookup and an investigator are not supposed to produce a diff, so "no diff" is success for them.
# This fired on two real children in one day; both spent their last message arguing they were not
# stuck instead of delivering findings, and both sets of findings were lost.
events18="$TMP/events-18.jsonl"
GUARD_AGENT_TYPE="lookup"
out18a="$(run_guard "$TMP/stall.jsonl" a18a false GOVERN_AGENT_SUPERVISION=1 GOVERN_EVENTS=1 GOVERN_EVENTS_FILE="$events18")"
assert_eq "$out18a" "" "a lookup child is never stalled, however read-only its turns"
[ -s "$events18" ] && has18=yes || has18=no
assert_eq "$has18" "no" "and raises no alarm either: there is nothing wrong with it"
GUARD_AGENT_TYPE="investigator"
out18b="$(run_guard "$TMP/stall.jsonl" a18b false GOVERN_AGENT_SUPERVISION=1)"
assert_eq "$out18b" "" "an investigator child is never stalled either"
GUARD_AGENT_TYPE="worker"
out18c="$(run_guard "$TMP/stall.jsonl" a18c false GOVERN_AGENT_SUPERVISION=1)"
assert_contains "$out18c" '"decision":"block"' "a worker on the SAME transcript and tree IS still blocked"
GUARD_AGENT_TYPE="general-purpose"

# ── 19. UNRESOLVABLE TREE degrades to allow ────────────────────────────────────────────────────
# cwd is a plain directory, not a git checkout, so the tree question cannot be answered at all. A
# check that cannot tell must never be the thing that denies a stop.
GUARD_CWD="$TMP/not-a-repo"
out19="$(run_guard "$TMP/stall.jsonl" a19 false GOVERN_AGENT_SUPERVISION=1)"
assert_eq "$out19" "" "no resolvable working tree → the guard allows the stop rather than guessing"
GUARD_CWD="$TMP/tree-clean"

# ── 20. THE GATES DO NOT WIDEN ─────────────────────────────────────────────────────────────────
# Both gates are scoped to STALL. A child fighting its own tools is fighting them whatever its type
# and whatever the filesystem says, so LOOP is unchanged for a read-only type too.
GUARD_AGENT_TYPE="lookup"
out20="$(run_guard "$TMP/loop.jsonl" a20 false GOVERN_AGENT_SUPERVISION=1 GOVERN_EARLY_ABORT_REPEATS=5)"
assert_contains "$out20" "LOOP" "the loop signature still fires for a read-only agent type"
GUARD_AGENT_TYPE="general-purpose"

assert_done
