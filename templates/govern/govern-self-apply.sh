#!/usr/bin/env bash
# Guarded self-improvement APPLY (opt-in: GOVERN_SELF_APPLY=1, default off). Runs at run-end.
# Lets a fresh agent apply EXACTLY ONE small harness improvement, then enforces hard guards
# deterministically in bash (not by trusting the agent):
#   - the agent runs --permission-mode acceptEdits → it can edit files but CANNOT run bash
#     (git/rm/deploy would prompt → fail in headless), so it is contained to file edits.
#   - STRICT ALLOWLIST: only the core mechanism scripts may change. Any other changed path →
#     revert. (govern-bookkeep / govern-supervise / govern-improve / govern-self-apply itself /
#     lib/common.sh are deliberately OUT — they encode policy/bookkeeping the agent must not touch.)
#   - PROTECTED PATTERNS: a diff line touching a safety knob (hard-stops, bounds, permission mode,
#     merge allowlist) → revert, even within an allowed file.
#   - TEST-GATE: the full govern test suite must pass → else revert.
#   - pass → ONE atomic commit; any violation → full revert + escalation. Changes take effect on
#     the NEXT run (never edits a script mid-execution).
# Usage: govern-self-apply.sh <run-dir>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq; govern::require git
RUNDIR="${1:?run dir required}"
[[ "${GOVERN_SELF_APPLY:-0}" == "1" ]] || { govern::log "self-apply: disabled (GOVERN_SELF_APPLY=1 to enable)"; exit 0; }

ALLOWED="scripts/govern/select-ticket.sh scripts/govern/await-ci.sh scripts/govern/merge-pr.sh scripts/govern/spawn-worker.sh scripts/govern/run-loop.sh scripts/govern/dry-run.sh"
PROTECTED_PATTERNS='GOVERN_MERGE_REPOS|is_merge_repo|bypassPermissions|GOVERN_PERMISSION_MODE|permflag=|setting-sources|GOVERN_MAX_TICKETS|GOVERN_MAX_BAD_STREAK|GOVERN_MAX_RUNTIME|GOVERN_SELF_APPLY|destructive|"green" \|\| '

cd "$WS_ROOT"
# Refuse to run on a dirty harness tree (don't entangle the agent's edits with anything else).
if [[ -n "$(git status --porcelain scripts/govern governor .claude 2>/dev/null)" ]]; then
  govern::log "self-apply: harness tree not clean — skipping"; exit 0
fi

escalate() { # message
  # Route through the numeric escalation writer so the entry is a real `### #N` with an `Opened` stamp:
  # the lifecycle parser (govern::escalations_open_ndjson) only sees `### #N`, so the old free-form
  # `### self-improvement BLOCKED — …` heading was INVISIBLE to emit-pending / apply-answers / the
  # stale-ager — a write-only note. file_open_escalation also commits escalations.md same-step (#14),
  # so this blocked-self-improvement note can't linger uncommitted and abort the next run's rebase.
  local N; N="$(govern::next_ticket_number)"
  govern::file_open_escalation "$N" "self-apply BLOCKED" \
    "$1" \
    "apply the proposal in governor/improvements.md by hand if wanted, or discard it" \
    "apply-by-hand / discard"
}
revert() {
  # per-path so a non-matching pathspec (e.g. an empty .claude) can't abort the whole restore
  local p
  for p in scripts/govern governor .claude; do git checkout -- "$p" 2>/dev/null || true; done
  git ls-files --others --exclude-standard scripts/govern governor .claude 2>/dev/null | xargs -r rm -f
}

before="$(git status --porcelain | sort)"

prompt="GOVERN-SELF-APPLY. Apply EXACTLY ONE small, safe, high-value improvement to the governor
harness, chosen from governor/improvements.md. You may ONLY edit these files:
  $ALLOWED
Make a minimal edit. You must NOT change any safety rail (the hard-stops, the run bounds
GOVERN_MAX_*, the permission mode / bypassPermissions, the merge allowlist GOVERN_MERGE_REPOS,
the green-or-none merge gate, --setting-sources). Do NOT edit tests, common.sh, preferences.md,
settings.json, or any other file. Do NOT run git or any shell command — just edit the file(s).
If nothing is both safe and worthwhile, make NO change at all."

agent_cmd="${GOVERN_APPLY_AGENT_CMD:-}"
if [[ -n "$agent_cmd" ]]; then
  ( cd "$WS_ROOT" && eval "$agent_cmd" ) || true
else
  ( cd "$WS_ROOT" && "${GOVERN_CLAUDE_BIN:-claude}" -p "$prompt" --output-format stream-json --verbose \
      --setting-sources "${GOVERN_SETTING_SOURCES:-user}" --permission-mode acceptEdits \
      --model "${GOVERN_IMPROVE_MODEL:-sonnet}" >/dev/null 2>&1 ) || true
fi

after="$(git status --porcelain | sort)"
changed="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | awk '{print $2}' | sort -u)"
[[ -z "$changed" ]] && { govern::log "self-apply: no change made"; exit 0; }

# Guard 1 — strict allowlist (any changed path not in ALLOWED → revert).
for f in $changed; do
  ok=0; for a in $ALLOWED; do [[ "$f" == "$a" ]] && ok=1; done
  if [[ "$ok" -ne 1 ]]; then govern::log "self-apply BLOCKED: edited disallowed path '$f' — reverting"; revert; escalate "edited disallowed path $f"; exit 0; fi
done
# Guard 2 — protected safety-rail patterns in the diff.
if git diff -- $changed | grep -E '^[-+]' | grep -vE '^[-+]{3}' | grep -qE "$PROTECTED_PATTERNS"; then
  govern::log "self-apply BLOCKED: diff touches a safety-rail pattern — reverting"; revert; escalate "diff touched a safety-rail pattern"; exit 0
fi
# Guard 3 — test-gate (full suite must pass).
test_cmd="${GOVERN_SELFAPPLY_TEST_CMD:-}"
gate_ok=1
if [[ -n "$test_cmd" ]]; then eval "$test_cmd" || gate_ok=0
else for t in "$DIR"/test/test-*.sh; do ( bash "$t" >/dev/null 2>&1 ) || { gate_ok=0; break; }; done; fi
if [[ "$gate_ok" -ne 1 ]]; then govern::log "self-apply BLOCKED: test suite failed — reverting"; revert; escalate "self-edit failed the test suite"; exit 0; fi

# All guards pass → one atomic commit (takes effect next run).
git add $changed
git commit -q -m "chore(govern): guarded self-improvement — $(printf '%s' "$changed" | tr '\n' ' ')

Auto-applied by govern-self-apply.sh: allowlist + protected-pattern + test-gate all passed.

Co-Authored-By: Claude <noreply@anthropic.com>" || { govern::log "self-apply: commit failed — reverting"; revert; exit 0; }
govern::log "self-apply: committed 1 guarded improvement → $changed"
