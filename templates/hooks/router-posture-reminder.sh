#!/usr/bin/env bash
# UserPromptSubmit hook: prime the ROUTER POSTURE once per session.
#
# Why this exists: the delegation rule in CLAUDE.md makes "delegate heavy work to a child Agent,
# keep the driver context thin" a HARD rule, but it's one item in a large file.
# Per-turn cost is proportional to THIS session's context size, which is re-sent
# in full every turn — so a driver that reads big files / runs verbose builds /
# investigates inline bloats the window and re-pays for it on every later turn.
# A live interactive transcript here measured 9.7 MB; a governor worker never
# gets near that because it's a throwaway sub-session. This hook surfaces the
# rule at the moment a task arrives so the session adopts the posture from the
# start.
#
# Fire-ONCE-per-session by design: the standing rule already lives in CLAUDE.md
# (loaded every turn at zero marginal cost), so re-injecting it on every prompt
# would just add tokens each turn — the very thing we're trying to cut. We prime
# once (marker keyed on session_id, mirroring ticket-sweep-reminder.sh) to set
# the posture, then stay quiet.
#
# Output contract: a UserPromptSubmit hook's stdout (on exit 0) is added to the
# model's context as additional guidance. Never block — always exit 0.
set -uo pipefail

# --- read the UserPromptSubmit stdin payload (session_id, prompt, cwd) ---
payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
session_id="$(get session_id)"
[ -n "$session_id" ] || session_id="nosession"

# --- once-per-session marker ---
marker="${TMPDIR:-/tmp}/metarepo-router-posture-${session_id}"
[ -e "$marker" ] && exit 0
: > "$marker" 2>/dev/null || true

cat <<'EOF'
[ROUTER POSTURE] Classify before acting: trivial (single answer/edit/command/known lookup) → inline. Heavier (multi-file investigation, codebase sweep, diagnosis, build/test, multi-file change) → delegate to an `Agent` worker (run_in_background if long); relay ONLY its verdict — don't Read big files or run verbose builds here. Multi-stage dependent steps → drive with a `Workflow` (final object only). Size children per CLAUDE.md's delegation rule.
EOF
exit 0
