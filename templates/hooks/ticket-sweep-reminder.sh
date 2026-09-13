#!/usr/bin/env bash
# Stop hook: when a session that did real code work is about to end, nudge once to
# reconcile tickets.md — fold any newly-discovered bug/gap into an open ticket (or file a new
# numbered one when the work is independently dispatchable),
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

# A dispatch worker (the caller sets GOVERN_RUN=1) must not reconcile the queue: its own
# prompt (governor/worker-prompt.md) explicitly forbids editing tickets.md, so blocking here would
# order it to do the one thing it's told not to do. Worktrees inherit the git-tracked root
# .claude/settings.json, so this hook fires inside worker sessions too unless it self-exempts.
[ -n "${GOVERN_RUN:-}" ] && exit 0

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

# --- collision backstop: a duplicate `## #N` heading in tickets.md means two filings reused
# one number. Surface it the moment a session ends — independent of (and before) the new-ticket
# reminder below, and NOT gated by the once-per-session marker, so a collision nags until fixed.
# stop_hook_active (handled above) prevents an in-turn loop. Run as a subprocess so the lint's set
# flags can't leak into this hook (which deliberately runs without -e).
lint="$SELF_ROOT/scripts/govern/lint-tickets.sh"
[ -x "$lint" ] || lint="$SELF_ROOT/govern/lint-tickets.sh"
if [ -x "$lint" ]; then
  if ! dups="$("$lint" "$MAIN/queue/tickets.md" 2>/dev/null)" && [ -n "${dups:-}" ]; then
    dups_flat="$(printf '%s' "$dups" | tr '\n' ' ')"
    reason="tickets.md has a DUPLICATE ## #N heading — two filings collided on one number: \
${dups_flat}. Renumber the LATER duplicate to live max+1 (file-ticket.sh prints the next safe \
number), commit, then stop. Only blocker — do not start other work."
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"decision":"block","reason":"%s"}\n' "$esc"
    exit 0
  fi
fi

# --- validation-lint backstop: lint-validation-refs.sh guards TWO independent things — a dangling
# `.claude/shiploop/validation/*.md` reference (a founder-os layout migration can DELETE a
# summary while `features.md`/`direction.md`/`CLAUDE.md` still cite it as proof) AND the `validation/`
# flow-registry lint matrix (govern::flows_lint — glob/Evidence-ref/logs-path/PII checks). Surface it
# at session end: blocking, and UNgated by the once-per-session marker below, so it nags until fixed.
# Run as a subprocess so the lint's set flags can't leak into this hook.
#
# This used to wrap EVERY failure in the dangling-ref framing + founder-os remediation
# ("git show <migration>^:<path>"), which misdiagnosed a FLOWS LINT FAIL (wrong path — this workspace
# uses validation/, not .claude/shiploop/validation/ — wrong cause, wrong fix). Branch on the lint's
# own output shape instead of guessing: only the dangling-ref case gets that framing; anything else
# (flows-lint glob/PII/logs-ref failures, or a future lint addition) surfaces the lint's real message
# verbatim under a neutral wrapper.
vlint="$SELF_ROOT/scripts/govern/lint-validation-refs.sh"
[ -x "$vlint" ] || vlint="$SELF_ROOT/govern/lint-validation-refs.sh"
if [ -x "$vlint" ]; then
  if ! lint_out="$("$vlint" "$MAIN" 2>&1)" && [ -n "${lint_out:-}" ]; then
    lint_flat="$(printf '%s' "$lint_out" | tr '\n' ' ')"
    case "$lint_out" in
      *'DANGLING .claude/shiploop/validation'*)
        reason="A .claude/shiploop/validation/*.md evidence summary is MISSING but still cited: \
${lint_flat} Restore it (git show <migration>^:<path>) or fix the reference, commit, then stop. \
Likely a migration orphaned it. Only blocker."
        ;;
      *)
        reason="validation lint failed at session end: ${lint_flat} Fix it, commit, then stop. \
Only blocker."
        ;;
    esac
    esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"decision":"block","reason":"%s"}\n' "$esc"
    exit 0
  fi
fi

# --- BLOCKING: a validation-shaped ticket resolved by hand, without a validation record (shiploop
# 1.19.2, the loop purge — B2b). Read this comment before touching the logic below: the OBVIOUS
# implementation ("any open validation-shaped ticket with no evidence file blocks") is wrong — that
# is the existing advisory nudge below (validation_note), and making IT blocking would refuse every
# session in a workspace that has any unvalidated validation ticket, forever, whether or not this
# session ever touched it.
#
# Block ONLY on RESOLUTION WITHOUT A RECORD: a validation-shaped `## #N` block that is present in
# origin/main (or HEAD if there is no remote / the fetch fails) but ABSENT from the working-tree
# tickets.md — i.e. THIS session removed it — with no matching
# .claude/shiploop/validation/ticket-<N>-*.md evidence file. A session that never touched the
# ticket is unaffected (the block is present on both sides, so no diff). A ticket resolved through
# resolve-ticket.sh already ran the same gate at land time and (on the happy path) already wrote
# the evidence file, so this never re-fires for that path — it exists for a HAND edit to
# tickets.md that deletes a validation ticket's block outside resolve-ticket.sh entirely.
#
# Escape hatch for a ticket deleted for a reason OTHER than validation (an operator decision to
# drop it, not a resolve): GOVERN_VALIDATION_GATE=0, named in the block message so it is
# discoverable at the moment it is needed. UNgated by the once-per-session marker below (like the
# two blocking checks above) so it re-fires on every Stop attempt until the record exists, the
# ticket comes back, or the kill switch is set.
if [ "${GOVERN_VALIDATION_GATE:-1}" != "0" ] && [ -f "$MAIN/queue/tickets.md" ]; then
  gate_out="$(
    GOVERN_WS_ROOT="$MAIN" GOVERN_TICKETS_FILE="$MAIN/queue/tickets.md"
    export GOVERN_WS_ROOT GOVERN_TICKETS_FILE
    source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
      || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
    command -v govern::is_validation_ticket >/dev/null 2>&1 || exit 0
    command -v govern::ticket_block >/dev/null 2>&1 || exit 0
    base_ref="HEAD"
    if git -C "$MAIN" remote get-url origin >/dev/null 2>&1 \
       && git -C "$MAIN" fetch -q origin main 2>/dev/null; then
      base_ref="origin/main"
    fi
    base_content="$(git -C "$MAIN" show "${base_ref}:queue/tickets.md" 2>/dev/null || true)"
    [ -n "$base_content" ] || exit 0
    base_tmp="$(mktemp)"
    printf '%s\n' "$base_content" > "$base_tmp"
    trap 'rm -f "$base_tmp"' EXIT
    base_ns="$(grep -oE '^##[[:space:]]+#[0-9]+' "$base_tmp" 2>/dev/null | grep -oE '[0-9]+' || true)"
    for n in $base_ns; do
      # Still present in the working tree → not something this session removed.
      grep -qE "^##[[:space:]]+#${n}([^0-9]|\$)" "$MAIN/queue/tickets.md" 2>/dev/null && continue
      block="$(govern::ticket_block "$n" "$base_tmp" 2>/dev/null || true)"
      govern::is_validation_ticket "$block" || continue
      compgen -G "$MAIN/.claude/shiploop/validation/ticket-$n-"'*.md' >/dev/null 2>&1 && continue
      printf '%s\n' "$n"
    done
  )"
  if [ -n "${gate_out:-}" ]; then
    gate_ids="$(printf '%s' "$gate_out" | tr '\n' ' ' | sed -E 's/ +$//')"
    reason="VALIDATION RECORD REQUIRED: ticket(s) #$(printf '%s' "$gate_ids" | sed 's/ /, #/g') \
looked like validation/spike tickets and were REMOVED from tickets.md this session, but no \
.claude/shiploop/validation/ticket-<N>-*.md record exists for them. Run /validated <N> for each to \
record the evidence, then stop. If this ticket was deleted for a reason OTHER than validation (an \
operator decision to drop it, not a resolve), set GOVERN_VALIDATION_GATE=0 for this session to skip \
this check. Only blocker — do not start other work."
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
if [ -f "$MAIN/.claude/shiploop/validation/flows.md" ]; then
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
    flows_note="FLOW STALENESS (advisory): landed code appears to STALE ${n_staled} flow(s) — \
${staled_ids}. Governor's staleness sweep records it next pass (or run /shiploop:flows). "
  fi
fi

# --- queue-isolation advisory: a SOFT, never-blocking note folded into the reconcile reason.
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
    outscope_note="QUEUE ISOLATION (advisory): #$(printf '%s' "$outscope_ids" | sed 's/ /, #/g') \
target neither a sub-repo nor the harness — likely an EXTERNAL tool's follow-up (its own tracker, \
not this queue). Migrate or delete at operator's call. "
  fi
fi

# --- validation-record nudge advisory (work item 5): a SOFT, never-blocking note folded into the
# reconcile reason. A validation-shaped OPEN ticket (govern::is_validation_ticket) with no matching
# .claude/shiploop/validation/ticket-<N>-*.md is "plausibly" one THIS session worked, since this
# whole reminder only fires once this session already did code work (did_code_work, above): a Stop
# hook has no per-ticket session attribution, so this is a coarse, ALWAYS-ADVISORY proxy: a false
# positive costs one extra line pointing at /validated, never a block. Kill switch:
# GOVERN_VALIDATION_NUDGE=0. Run in a subshell so common.sh's `set -e` can't leak into this hook (no
# -e here); empty on any failure, degrading to silence.
validation_note=""
if [ "${GOVERN_VALIDATION_NUDGE:-1}" != "0" ] && [ -f "$MAIN/queue/tickets.md" ]; then
  validation_ids="$(
    GOVERN_WS_ROOT="$MAIN" GOVERN_TICKETS_FILE="$MAIN/queue/tickets.md"
    export GOVERN_WS_ROOT GOVERN_TICKETS_FILE
    source "$SELF_ROOT/scripts/govern/lib/common.sh" 2>/dev/null \
      || source "$SELF_ROOT/govern/lib/common.sh" 2>/dev/null || exit 0
    command -v govern::tickets_missing_validation_doc >/dev/null 2>&1 || exit 0
    govern::tickets_missing_validation_doc "$MAIN/queue/tickets.md" "$MAIN" 2>/dev/null | tr '\n' ' '
  )"
  validation_ids="$(printf '%s' "${validation_ids:-}" | sed -E 's/ +$//; s/^ +//')"
  if [ -n "$validation_ids" ]; then
    validation_note="VALIDATION RECORD (advisory): #$(printf '%s' "$validation_ids" | sed 's/ /, #/g') \
look validation-shaped and open with no .claude/shiploop/validation/ticket-<N>-*.md evidence file yet. \
If you live-tested one this session, run /validated <N> to record the evidence durably. "
  fi
fi

reason="${outscope_note}${flows_note}${validation_note}Reconcile tickets.md before ending. \
(1) NEW: for each bug/gap/follow-up from this session not already tracked, first look for an OPEN \
ticket to fold it into (rewriting its body is fine); mint a new ## #N (Severity/Where/Observed/Fix \
direction/Done when/Ref) only when independently dispatchable — a different area, or shippable \
without touching another ticket. Never split one discussion's findings into tickets a single worker \
would fix in one PR. An operator rejection this session (\"that should be one ticket\", \"don't file \
that\") binds here too. \
(2) RESOLVED: for any ticket whose fix PR you opened this session, delete it from tickets.md now; \
promote a durable lesson to CLAUDE.md first only if settled/new/<=3 lines (else CLAUDE-APPENDIX.md); \
name the PR# in the deletion commit. \
Nothing to file/delete -> say so in one line and stop. Bookkeeping only, no new work."

# JSON-escape the reason and emit the block decision.
esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"%s"}\n' "$esc"
exit 0
