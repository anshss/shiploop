#!/usr/bin/env bash
# PreToolUse(*) hook, subagent-scoped: the two headless-launcher watchdogs that have no
# stop/idle equivalent — D10, .specs/2026-09-11-advisor-worker-design.md. Closes two of G12's
# four launcher-retirement blockers (blocker 4). agent-progress-guard.sh already ported the
# other two (early-abort signature + D8's idle supervision); this ports the remaining pair:
#   - wall-clock       (the launcher's GOVERN_WORKER_TIMEOUT)
#   - token budget     (the launcher's GOVERN_WORKER_MAX_TOKENS)
# The launcher's third remaining item, EXIT/INT/TERM cleanup traps, has NO hook equivalent and is
# NOT ported here — see the comment at the bottom of this file for what does and does not cover it.
#
# WHY PreToolUse, not SubagentStop/TeammateIdle (D10). Those two only fire when a child STOPS or
# goes QUIET. A child that is busily doing the wrong thing for an hour does neither — it never
# stops and never idles. The event a working child emits CONTINUOUSLY is a tool call, so that is
# the one place a ceiling on wall-clock or tokens can actually catch it in progress.
#
# DETECTION: "this is a child", not the driver/advisor. Verified live 2026-09-11 against the
# installed claude 2.1.246 by spawning a real subagent and diffing its own PreToolUse payload
# against the dispatching session's: `agent_id` and `agent_type` are present on every tool call a
# subagent makes and ABSENT on the driver's own (docs: https://code.claude.com/docs/en/hooks,
# "Common input fields" — "Present only when the hook fires inside a subagent call"). This is a
# straight port of the SAME signal `router-posture-guard.sh` already keys its own sub-agent skip
# on (there it reads the call's OWN transcript_path for a `.../subagents/` path segment; here it
# reads `agent_id` directly, which is the field the platform adds for exactly this purpose and
# works at any nesting depth). `[ -n "$agent_id" ] || exit 0` is both the detection AND the
# guarantee the constraint below asks for: an advisor/driver session's own tool calls never reach
# past this line, so this hook can never deny the operator's own work.
#
# THE CHILD'S OWN TRANSCRIPT. PreToolUse does NOT carry an `agent_transcript_path` the way
# SubagentStop does (verified live, same session as above: a subagent's PreToolUse payload
# carries the identical `transcript_path` as the driver's own dispatching call — it is the shared
# top-level transcript, not a per-child one). But the platform still writes each subagent's own
# stream to a fixed, discoverable path alongside the parent's: for a parent transcript at
# `<dir>/<session_id>.jsonl`, a spawned child's own turns land at
# `<dir>/<session_id>/subagents/agent-<agent_id>.jsonl` — confirmed live by spawning a real
# subagent and inspecting the `.jsonl`/`.meta.json` pair the platform actually wrote to disk.
# Undocumented (the platform's own docs describe neither the directory layout nor a dedicated
# field here), so this degrades to "no token check this call" rather than a wrong verdict when the
# file isn't where expected — same "absence of data is never evidence of doom" contract every
# other watchdog in this repo already holds to.
#
# HARD CONSTRAINT, same as every other watchdog here: every signal is DETERMINISTIC, read straight
# off the child's own transcript file. No model call anywhere in this path.
#
# Response shape: a DENY, never a kill. A worker mid-task that is denied its next tool call can
# still emit a final text response — its structured report, with an honest status and a filled
# escalation — so the work already done and the reason it stopped both survive. A kill would lose
# both (D10). This also means the response is a `permissionDecision` in the hook's stdout JSON,
# never a nonzero exit: hooks in this repo NEVER hard-fail a session (root CLAUDE.md rule, restated
# here because a `set -e` slip in a PreToolUse hook denies every later tool call in the SESSION
# that installed it, not just the one call under test).
#
# BOTH CAPS SHIP ON, each with its own kill switch (0 disables that one specifically) — an
# inert-by-default watchdog is the G7 defect this whole design exists to close. Neither default
# below is a derived constant; both are starting points, tunable per fleet:
#   GOVERN_AGENT_WALLCLOCK    (seconds, default 3600) — the SAME 1h starting point the launcher's
#     own GOVERN_WORKER_TIMEOUT already ships, ported unchanged rather than inventing a new number
#     for the identical question ("how long is too long for one child").
#   GOVERN_AGENT_TOKEN_BUDGET (tokens, default 10000000) — the launcher's OWN GOVERN_WORKER_MAX_TOKENS
#     ships OFF (0) by default, which G7 forbids repeating here, so this is a fresh pick rather
#     than a straight port: half of the ~22M-token runaway that tickets #3/#6 measured before
#     GOVERN_WORKER_MAX_TOKENS existed (spawn-worker.sh, "#16"), generous enough not to trip on
#     ordinary heavy multi-file work, tight enough to actually catch a wandering child.
# Deliberately its OWN two switches, NOT GOVERN_AGENT_SUPERVISION (D8's idle-supervision knob) —
# conflating them would mean one kill switch silently disables three unrelated mechanisms.
set -uo pipefail

# --- read the PreToolUse hook stdin payload ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

agent_id="$(get agent_id)"
[ -n "$agent_id" ] || exit 0   # no agent_id → this is the driver/advisor itself, never touch it

agent_type="$(get agent_type)"
transcript_path="$(get transcript_path)"
session_id="$(get session_id)"

# Sanitize for filename/path use — an agent_id is a platform-issued token in practice, but never
# trust it into a path unescaped (same discipline router-posture-guard.sh applies to session_id).
safe_id="$(printf '%s' "$agent_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe_id" ] || safe_id="unknown"

deny() { # <reason text> -> emits the PreToolUse deny JSON and exits 0
  local esc; esc="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  exit 0
}

# ── wall-clock ───────────────────────────────────────────────────────────────────────────────
# Keyed on agent_id, first-seen time recorded in a state file — same ${TMPDIR:-/tmp} per-key
# state-file idiom router-posture-guard.sh already uses for its per-session warn/fanout counters.
# Like those, this file is never swept: it is a few bytes per child the OS's own tmp cleanup
# eventually reclaims, the same tradeoff already accepted for the counters it's modeled on.
wallclock_cap="${GOVERN_AGENT_WALLCLOCK:-3600}"
case "$wallclock_cap" in (*[!0-9]*) wallclock_cap=3600 ;; esac
if [ "$wallclock_cap" != "0" ]; then
  wc_state="${TMPDIR:-/tmp}/metarepo-agent-watchdog-wallclock-${safe_id}"
  now="$(date +%s)"
  if [ -f "$wc_state" ]; then
    first="$(cat "$wc_state" 2>/dev/null || true)"
    case "$first" in (*[!0-9]*|"") first="$now" ;; esac
  else
    first="$now"
    printf '%s' "$now" > "$wc_state" 2>/dev/null || true
  fi
  elapsed=$(( now - first ))
  if [ "$elapsed" -ge "$wallclock_cap" ] 2>/dev/null; then
    deny "[AGENT WATCHDOG] wall-clock: this child (agent_id=${agent_id}, agent_type=${agent_type:-unknown}) has been running ~${elapsed}s, past the ${wallclock_cap}s cap (GOVERN_AGENT_WALLCLOCK). Do not start another tool call. Stop now and return your final response as your structured report: an honest status, and if you cannot finish, a filled escalation naming what is left and why. Raise GOVERN_AGENT_WALLCLOCK if this task genuinely needs longer."
  fi
fi

# ── token budget ─────────────────────────────────────────────────────────────────────────────
# Sum from the child's OWN transcript (derived path, see header) via govern::cumulative_tokens —
# the same function the headless launcher's own GOVERN_WORKER_MAX_TOKENS watchdog polls against a
# live worker.jsonl. One implementation, two callers, so a token total has one definition.
token_cap="${GOVERN_AGENT_TOKEN_BUDGET:-10000000}"
case "$token_cap" in (*[!0-9]*) token_cap=10000000 ;; esac
if [ "$token_cap" != "0" ] && [ -n "$transcript_path" ] && [ -n "$session_id" ]; then
  proj_dir="$(dirname "$transcript_path")"
  child_transcript="$proj_dir/$session_id/subagents/agent-${agent_id}.jsonl"
  if [ -f "$child_transcript" ]; then
    # Reach common.sh defensively, same idiom agent-progress-guard.sh already uses: if common.sh
    # itself is not found at either candidate path, `|| exit 0` degrades this to a silent no-op.
    # A common.sh that DOES load but whose own workspace-config source fails (a bare checkout with
    # no scripts/lib/workspace.sh) still defines every function that doesn't need that config,
    # govern::cumulative_tokens included — verified live: bash suppresses `set -e` for the whole
    # recursive execution of one member of an `A || B` list, so a failure deep inside common.sh's
    # OWN sourcing of workspace.sh does not stop the rest of common.sh from loading. That is a
    # feature here, not a gap to route around: a pure function over a transcript file has no
    # business needing repo/org config to answer a token count. SELF_ROOT mirrors
    # agent-progress-guard.sh exactly: this script installs to scripts/ (workspace) or lives at
    # templates/hooks/ (hub repo / hermetic tests).
    SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    tokens="$(
      source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
        || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
      command -v govern::cumulative_tokens >/dev/null 2>&1 || exit 0
      govern::cumulative_tokens "$child_transcript"
    )" || true
    case "$tokens" in (*[!0-9]*|"") tokens="" ;; esac
    if [ -n "$tokens" ] && [ "$tokens" -ge "$token_cap" ] 2>/dev/null; then
      deny "[AGENT WATCHDOG] token budget: this child (agent_id=${agent_id}, agent_type=${agent_type:-unknown}) has burned ~${tokens} tokens, past the ${token_cap}-token cap (GOVERN_AGENT_TOKEN_BUDGET). Do not start another tool call. Stop now and return your final response as your structured report: an honest status, and if you cannot finish, a filled escalation naming what is left and why. Raise GOVERN_AGENT_TOKEN_BUDGET if this task genuinely needs a bigger budget."
    fi
  fi
fi

exit 0

# ── traps: what does NOT port, and what already covers the case they existed for ───────────────
# The launcher's EXIT/INT/TERM cleanup (spawn-worker.sh's spawn_worker_cleanup) does three things
# on every exit path: (1) reap its own wall-clock/token/early-abort watchdog subshells so a killed
# governor never leaks a `sleep`-holding process, (2) kill_tree the actual `claude -p` OS process
# plus every grandchild it spawned, so a stopped/killed governor never leaves an orphaned process
# reparented to init and billing a box, (3) record the attempt outcome into attempts.jsonl so a
# SIGKILLed attempt is never miscounted as a completed one for sizing history.
#
# None of that has a hook equivalent, and this file does not invent one (D10: "the launcher's
# EXIT/INT/TERM cleanup has no hook equivalent"). Whether SessionEnd's own
# worktree/session-end-cleanup.sh covers the case the traps existed for, checked directly rather
# than assumed:
#   - (1) and (3) do not apply to the interactive lane at all: an in-session Agent child is NOT a
#     separate OS process the way the launcher's `claude -p` is — it is a sidechain inside the
#     SAME running `claude` process (verified live: its transcript is a `subagents/` file under
#     the parent's OWN session directory, not a second top-level session) — so there is no second
#     process to leak, and no per-attempt sizing ledger on this lane to protect.
#   - (2)'s actual interactive-lane analogue — SOMETHING left running after a session ends
#     uncleanly — is PARTIALLY covered. session-end-cleanup.sh kills every process still bound to
#     this worktree's own dev-server ports (kill_port, scoped to processes whose cwd is under the
#     worktree), which is the concrete instance of "a dead run leaving something behind" this
#     workspace actually has (it ships no cloud/deploy infra, so the launcher's sibling
#     run_deploy_sweep has nothing to sweep here either way). It does NOT reap an arbitrary
#     background process a child started outside the known REPO_PORTS list — there is no
#     interactive-lane equivalent of govern::kill_tree's generic PID-tree walk.
#   - Neither this hook nor SessionEnd survives a hard SIGKILL/OOM/host-restart of the whole
#     session — but that is not a NEW gap opened by retiring the launcher: the launcher's own EXIT
#     trap already carries the identical caveat in its own comment ("a hard SIGKILL ... leaves a
#     worktree with zero cleanup", spawn-worker.sh). SessionEnd's own documented matcher values
#     (`clear`, `resume`, `logout`, `prompt_input_exit`, `other`) list graceful termination only;
#     the platform's docs do not claim it fires on an unclean kill either.
# Net: parity on the graceful-exit path for the one resource class this workspace has (worktree
# dev-server ports); no parity, on either lane, for a hard kill; no interactive-lane equivalent of
# a generic arbitrary-process reap. Recorded here rather than claimed as full parity.
