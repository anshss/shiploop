#!/usr/bin/env bash
# PreToolUse(*) hook, subagent-scoped: caps a worker subagent's wall-clock runtime. This is one of
# three watchdog signals a worker subagent gets; agent-progress-guard.sh covers the other two (the
# early-abort signature and idle supervision). This hook covers the remaining one:
#   - wall-clock       (GOVERN_AGENT_WALLCLOCK, see below)
# A retired headless dispatch launcher used a wrapping process with EXIT/INT/TERM cleanup traps for
# its own process reaping; a hook has no equivalent for that, and none is invented here. See the
# comment at the bottom of this file for what does and does not cover the case those traps existed for.
#
# DO NOT RE-ADD A PER-AGENT TOKEN-VOLUME CAP HERE. A cumulative token total sums cache reads, which
# are re-paid every turn for the same prefix, so the number tracks turn count rather than spend.
# And killing a warm child throws away its prompt cache: the cold replacement pays cache creation
# (priced above input) plus full-price re-reads, so firing costs more than not firing except
# against a child that would never have finished. That case belongs to the wall-clock cap below and
# to the stall, identical-command-loop and tool-error-rate detection agent-progress-guard.sh
# carries, both of which measure whether the child is getting anywhere rather than how much it read.
#
# WHY PreToolUse, not SubagentStop/TeammateIdle. Those two only fire when a child STOPS or
# goes QUIET. A child that is busily doing the wrong thing for an hour does neither — it never
# stops and never idles. The event a working child emits CONTINUOUSLY is a tool call, so that is
# the one place a wall-clock ceiling can actually catch it in progress.
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
# HARD CONSTRAINT, same as every other watchdog here: every signal is DETERMINISTIC, read straight
# off a per-agent timestamp state file. No model call anywhere in this path.
#
# Response shape: a DENY, never a kill. A worker mid-task that is denied its next tool call can
# still emit a final text response — its structured report, with an honest status and a filled
# escalation — so the work already done and the reason it stopped both survive. A kill would lose
# both. This also means the response is a `permissionDecision` in the hook's stdout JSON,
# never a nonzero exit: hooks in this repo NEVER hard-fail a session (root CLAUDE.md rule, restated
# here because a `set -e` slip in a PreToolUse hook denies every later tool call in the SESSION
# that installed it, not just the one call under test).
#
# THE CAP SHIPS ON, with its own kill switch (0 disables it): an inert-by-default watchdog is the
# defect this whole design exists to close. The default is not a derived constant, it is a starting
# point, tunable per fleet:
#   GOVERN_AGENT_WALLCLOCK (seconds, default 3600): the SAME 1h starting point the retired
#     launcher's own GOVERN_WORKER_TIMEOUT used to ship, carried over unchanged rather than
#     inventing a new number for the identical question ("how long is too long for one child").
# Deliberately its OWN switch, NOT GOVERN_AGENT_SUPERVISION (the idle-supervision knob).
# Conflating them would mean one kill switch silently disables unrelated mechanisms.
set -uo pipefail

# --- read the PreToolUse hook stdin payload ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

agent_id="$(get agent_id)"
[ -n "$agent_id" ] || exit 0   # no agent_id → this is the driver/advisor itself, never touch it

agent_type="$(get agent_type)"

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

exit 0

# ── traps: what does NOT port, and what already covers the case they existed for ───────────────
# The retired launcher's own wrapping process used an EXIT/INT/TERM trap to do three things on
# every exit path: (1) reap its own wall-clock/token/early-abort watchdog subshells so a killed governor
# never leaks a `sleep`-holding process, (2) kill_tree a forked `claude -p` OS process plus every
# grandchild it spawned, so a stopped/killed governor never leaves an orphaned process reparented
# to init and billing a box, (3) record the attempt outcome so a SIGKILLed attempt is never
# miscounted as a completed one for sizing history.
#
# None of that has a hook equivalent, and this file does not invent one. Whether SessionEnd's own
# worktree/session-end-cleanup.sh covers the case those traps existed for, checked directly rather
# than assumed:
#   - (1) and (3) do not apply here at all: an in-session Agent child is NOT a separate OS process
#     the way a forked `claude -p` is, it is a sidechain inside the SAME running `claude` process
#     (verified live: its transcript is a `subagents/` file under the parent's OWN session
#     directory, not a second top-level session), so there is no second process to leak, and no
#     per-attempt sizing ledger to protect.
#   - (2)'s actual analogue, SOMETHING left running after a session ends
#     uncleanly — is PARTIALLY covered. session-end-cleanup.sh kills every process still bound to
#     this worktree's own dev-server ports (kill_port, scoped to processes whose cwd is under the
#     worktree), which is the concrete instance of "a dead run leaving something behind" this
#     workspace actually has (it ships no cloud/deploy infra, so a deploy sweep would have nothing
#     to sweep here either way). It does NOT reap an arbitrary background process a child started
#     outside the known REPO_PORTS list: there is no in-session equivalent of govern::kill_tree's
#     generic PID-tree walk.
#   - Neither this hook nor SessionEnd survives a hard SIGKILL/OOM/host-restart of the whole
#     session, but that is not a NEW gap opened by retiring the launcher: its own EXIT trap
#     carried the identical caveat, a hard SIGKILL leaves a worktree with zero cleanup either
#     way. SessionEnd's own documented matcher values
#     (`clear`, `resume`, `logout`, `prompt_input_exit`, `other`) list graceful termination only;
#     the platform's docs do not claim it fires on an unclean kill either.
# Net: parity on the graceful-exit path for the one resource class this workspace has (worktree
# dev-server ports); no parity for a hard kill; no equivalent of a generic arbitrary-process reap.
# Recorded here rather than claimed as full parity.
