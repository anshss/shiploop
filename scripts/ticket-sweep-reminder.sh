#!/usr/bin/env bash
# Stop hook: when a session that did real code work is about to end, nudge once to
# reconcile tickets.md — file any newly-discovered bug/gap as a numbered ticket,
# and delete any ticket whose fix PR was opened this session. Generic — repo list
# from scripts/lib/workspace.sh, paths resolved relative to this script.
#
# Why this exists: the "discovered gap → tickets.md" and "PR opened → delete the
# ticket" rules in CLAUDE.md are convention, not enforced by anything. A
# compaction or a distracted turn silently drops them. This hook makes the "did I
# find something new?" check deterministic at session end.
#
# Design constraints (a Stop hook that always blocks would loop forever):
#   1. Fire AT MOST ONCE per session    — marker keyed on session_id.
#   2. Never re-fire inside its own loop — honor stop_hook_active.
#   3. Only fire when THIS session touched code — measured against a baseline the
#      SessionStart hook (session-snapshot.sh) snapshots at session start, so
#      prior-session residue (commits already ahead of origin/main, dirty trees a
#      previous run left behind) does NOT count. Without that gate the single fire
#      was spent at session START on stale state, and the marker then short-
#      circuited the REAL end of a long session. If no baseline exists (older
#      session, or SessionStart didn't run), fall back to the cruder absolute
#      check (any dirty tree / ahead branch / dirty tickets.md). Pure Q&A /
#      read-only sessions change nothing vs the baseline, so they stop silently.
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/workspace.sh
source "$SELF_ROOT/scripts/lib/workspace.sh" 2>/dev/null || source "$SELF_ROOT/lib/workspace.sh" 2>/dev/null || true
# shellcheck source=../lib/session-state.sh
source "$SELF_ROOT/scripts/lib/session-state.sh" 2>/dev/null || source "$SELF_ROOT/lib/session-state.sh" 2>/dev/null || true
MAIN="$META_ROOT"

# --- read the Stop hook stdin payload (session_id, stop_hook_active, cwd) ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
session_id="$(get session_id)"
cwd="$(get cwd)"
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

[ -n "$cwd" ] || cwd="$PWD"
[ -n "$session_id" ] || session_id="nosession"

# --- collision backstop (#73): a duplicate `## #N` heading in tickets.md means two filings reused
# one number. Surface it the moment a session ends — independent of (and before) the new-ticket
# reminder below, and NOT gated by the once-per-session marker, so a collision nags until fixed.
# stop_hook_active (handled above) prevents an in-turn loop. Run as a subprocess so the lint's set
# flags can't leak into this hook (which deliberately runs without -e).
lint="$SELF_ROOT/scripts/govern/lint-tickets.sh"
[ -x "$lint" ] || lint="$SELF_ROOT/govern/lint-tickets.sh"
if [ -x "$lint" ]; then
  if ! dups="$("$lint" "$MAIN/queue/tickets.md" 2>/dev/null)" && [ -n "${dups:-}" ]; then
    dups_flat="$(printf '%s' "$dups" | tr '\n' ' ')"
    reason="tickets.md has a DUPLICATE ## #N heading — two filings collided on one number (#73): \
${dups_flat}. Fix now: renumber the LATER duplicate to the live max + 1 \
(scripts/govern/file-ticket.sh prints the next safe number), commit, then stop. \
Do not start other work — this is the only blocker."
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"decision":"block","reason":"%s"}\n' "$esc"
    exit 0
  fi
fi

# --- validation-lint backstop: lint-validation-refs.sh guards TWO independent things — a dangling
# `.claude/context/validation/*.md` reference (#252: a founder-os layout migration can DELETE a
# summary while `features.md`/`direction.md`/`CLAUDE.md` still cite it as proof) AND the `validation/`
# flow-registry lint matrix (govern::flows_lint — glob/Evidence-ref/logs-path/PII checks). Surface it
# at session end: blocking, and UNgated by the once-per-session marker below, so it nags until fixed.
# Run as a subprocess so the lint's set flags can't leak into this hook.
#
# This used to wrap EVERY failure in the #252 dangling-ref framing + founder-os remediation
# ("git show <migration>^:<path>"), which misdiagnosed a FLOWS LINT FAIL (wrong path — this workspace
# uses validation/, not .claude/context/validation/ — wrong cause, wrong fix). Branch on the lint's
# own output shape instead of guessing: only the dangling-ref case gets that framing; anything else
# (flows-lint glob/PII/logs-ref failures, or a future lint addition) surfaces the lint's real message
# verbatim under a neutral wrapper.
vlint="$SELF_ROOT/scripts/govern/lint-validation-refs.sh"
[ -x "$vlint" ] || vlint="$SELF_ROOT/govern/lint-validation-refs.sh"
if [ -x "$vlint" ]; then
  if ! lint_out="$("$vlint" "$MAIN" 2>&1)" && [ -n "${lint_out:-}" ]; then
    lint_flat="$(printf '%s' "$lint_out" | tr '\n' ' ')"
    case "$lint_out" in
      *'DANGLING .claude/context/validation'*)
        reason="A .claude/context/validation/*.md evidence summary is MISSING but still cited (#252): \
${lint_flat} Fix now: restore the deleted summary (git show <migration>^:<path>) or correct the \
reference, commit, then stop. A migration likely orphaned it. This is the only blocker."
        ;;
      *)
        reason="validation lint failed at session end: ${lint_flat} Fix the issue above, commit, \
then stop. This is the only blocker."
        ;;
    esac
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"decision":"block","reason":"%s"}\n' "$esc"
    exit 0
  fi
fi

# --- once-per-session marker ---
marker="${TMPDIR:-/tmp}/metarepo-ticket-sweep-${session_id}"
[ -e "$marker" ] && exit 0

# --- resolve the repo root: a worktree (has worktree.env) or the main checkout ---
root="$cwd"
while [ "$root" != "/" ] && [ ! -f "$root/worktree.env" ] && [ ! -f "$root/queue/tickets.md" ]; do
  root="$(dirname "$root")"
done
[ -d "$root" ] || root="$MAIN"

# Did THIS session touch code? Compare the current state against the baseline the
# SessionStart hook (session-snapshot.sh) snapshotted, so pre-existing residue
# does not count. When no baseline exists, fall back to the cruder absolute check.
did_code_work() {
  local baseline="${TMPDIR:-/tmp}/metarepo-ticket-sweep-baseline-${session_id}"
  if [ ! -f "$baseline" ] || ! command -v ticket_sweep_state_fingerprint >/dev/null 2>&1; then
    # No baseline (session predates this hook, or SessionStart didn't run), or the
    # fingerprint lib isn't available: fall back to the absolute check. It over-
    # fires on residue, but over-firing is cheap; SILENTLY losing the reminder is
    # the failure mode we care about.
    did_code_work_absolute
    return
  fi
  # State changed since session start ⇒ work happened this session.
  [ "$(ticket_sweep_state_fingerprint "$MAIN" "$root")" != "$(cat "$baseline" 2>/dev/null)" ]
}

# Cruder fallback, used only when no SessionStart baseline exists: ANY dirty tree /
# ahead branch / dirty tickets.md, regardless of when it happened.
did_code_work_absolute() {
  # tickets.md itself dirty in the main checkout → work in progress.
  if [ -f "$MAIN/queue/tickets.md" ] && ! git -C "$MAIN" diff --quiet -- queue/tickets.md 2>/dev/null; then
    return 0
  fi
  local r dir
  for r in "${REPOS[@]:-}"; do
    dir="$root/$r"
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
    # uncommitted changes (staged or unstaged)?
    if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
      return 0
    fi
    # local commits ahead of origin/main?
    local ahead
    ahead=$(git -C "$dir" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && return 0
  done
  return 1
}

if ! did_code_work; then
  exit 0
fi

# Fire once: drop the marker, then block with the reconcile reason.
: > "$marker" 2>/dev/null || true

# --- flow-registry staleness advisory (validations Phase 3): a SOFT, never-blocking note folded into
# the reconcile reason. Report-only dry scan (no writes, no network — rides the origin/main refs the
# session already has) of which currently-validated flows this session's landed code moved past their
# validated SHA. Run in a subshell so common.sh's `set -e` / any error can't leak into this hook
# (which deliberately runs without -e); empty on any failure, so the advisory simply degrades to
# silence. The governor's persisting sweep records the actual STALE degrade later.
flows_note=""
if [ -f "$MAIN/validation/flows.md" ]; then
  staled_ids="$(
    GOVERN_WS_ROOT="$MAIN" GOVERN_TICKETS_FILE="$MAIN/queue/tickets.md"
    export GOVERN_WS_ROOT GOVERN_TICKETS_FILE
    source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
      || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
    command -v govern::flows_sweep_scan >/dev/null 2>&1 || exit 0
    govern::flows_sweep_scan "$MAIN" 2>/dev/null | tr '\n' ' '
  )"
  staled_ids="$(printf '%s' "${staled_ids:-}" | sed -E 's/ +$//; s/^ +//')"
  if [ -n "$staled_ids" ]; then
    n_staled="$(printf '%s' "$staled_ids" | wc -w | tr -d ' ')"
    flows_note="FLOW STALENESS (advisory, non-blocking): this session's landed code appears to STALE \
${n_staled} validated flow(s) — ${staled_ids}. No action needed now; the governor's staleness sweep \
records the STALE degrade on its next pass (or run /shiploop:flows). "
  fi
fi

# --- queue-isolation advisory (#46): a SOFT, never-blocking note folded into the reconcile reason.
# The queue admits exactly two scopes — this workspace's own sub-repos and the harness itself. A
# ticket whose **Where:** line references NEITHER is likely about an EXTERNAL tool/skill/product that
# merely shared this terminal (its follow-ups belong in its own tracker). govern::out_of_scope_tickets
# is allowlist-based (flags only on the ABSENCE of any in-scope marker; no Where line ⇒ never flagged),
# so a legit ticket is not caught. This NEVER blocks and NEVER auto-deletes — deleting is always the
# operator's call. Run in a subshell so common.sh's `set -e` can't leak into this hook (no -e here);
# empty on any failure, degrading to silence.
outscope_note=""
if [ -f "$MAIN/queue/tickets.md" ]; then
  outscope_ids="$(
    GOVERN_WS_ROOT="$MAIN" GOVERN_TICKETS_FILE="$MAIN/queue/tickets.md"
    export GOVERN_WS_ROOT GOVERN_TICKETS_FILE
    source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
      || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
    command -v govern::out_of_scope_tickets >/dev/null 2>&1 || exit 0
    govern::out_of_scope_tickets "$MAIN/queue/tickets.md" 2>/dev/null | cut -f1 | tr '\n' ' '
  )"
  outscope_ids="$(printf '%s' "${outscope_ids:-}" | sed -E 's/ +$//; s/^ +//')"
  if [ -n "$outscope_ids" ]; then
    outscope_note="QUEUE ISOLATION (advisory, non-blocking): ticket(s) #$(printf '%s' "$outscope_ids" | sed 's/ /, #/g') \
have a **Where:** targeting NEITHER a sub-repo NOR the harness — likely about an EXTERNAL tool/skill \
that shared this terminal. The queue admits only this project's sub-repos and the harness itself; an \
external tool's follow-ups belong in ITS OWN tracker. Consider migrating or deleting (operator's call — \
never auto-removed). "
  fi
fi

reason="${outscope_note}${flows_note}Before ending: reconcile tickets.md (root meta-repo). \
(1) NEW TICKETS — review what you touched/discovered this session. Any bug, gap, \
missing capability, or follow-up that is NOT already a ticket gets its own numbered \
## #N entry in $MAIN/queue/tickets.md (Severity / Where / Observed / Fix direction / Done when / Ref). \
A discovered gap ALWAYS goes to tickets.md, never learnings.md. \
(2) RESOLVED TICKETS — for any ticket whose fix PR you OPENED this session (PR opened = resolved, \
not merged), DELETE its entry from tickets.md now; promote any durable lesson to CLAUDE.md first, \
and name the PR number in the deletion commit. \
If there is genuinely nothing to file and nothing to delete, say so in one line and stop. \
Do not re-investigate or start new work — this is a bookkeeping pass only."

# JSON-escape the reason and emit the block decision.
esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"%s"}\n' "$esc"
exit 0
