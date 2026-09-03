#!/usr/bin/env bash
# Guard test for router-posture-guard.sh's GOVERN_RUN exemption (#95).
#
# This PreToolUse hook nudges the DRIVER to delegate heavy inline work (a large Read, a verbose
# build/dev/install run) instead of doing it inline. It already exempted a governor worker
# (GOVERN_RUN set) at the very top of the script, before tool_name/command are even parsed, but
# that exemption had no test coverage. Worth locking down: the Bash-command regex substring-matches
# "npm run build" ANYWHERE in the command string, so a worker's own MANDATED validation wrapper
# (verify-filter.sh -- npm run build) would otherwise trip a false-positive warn telling the worker
# to delegate a command it was explicitly told to run itself.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# GOVERN_HOOKS_DIR (from assert.sh) resolves whichever layout we're in (#255): templates/hooks
# in the template repo, <root>/scripts in a scaffolded workspace.
GUARD="$GOVERN_HOOKS_DIR/router-posture-guard.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not present (guard needs it too)"; exit 77; }

export TMPDIR; TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

# Write the payload to a REAL FILE and feed the guard via `<` redirection, never a pipe: the
# GOVERN_RUN=1 case exits at line 35, before it ever reads stdin, and a pipe writer left with
# nowhere to write (a reader that closed early) gets SIGPIPE, which trips `set -e pipefail` in
# THIS test script. A file has no such reader-side lifecycle; redirection sidesteps it entirely.
payload() { # <command> <outfile>
  python3 -c '
import json, sys
print(json.dumps({
  "tool_name": "Bash",
  "transcript_path": "/tmp/sess/transcript.jsonl",
  "session_id": "routertest",
  "tool_input": {"command": sys.argv[1]},
}))
' "$1" > "$2"
}

PL="$TMPDIR/payload.json"

# ── 1. Without GOVERN_RUN, the regex DOES substring-match inside the wrapped command, proving
#        the false positive is real, not hypothetical.
payload 'verify-filter.sh -- npm run build' "$PL"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL")"
assert_contains "$out" "ROUTER POSTURE" \
  "no GOVERN_RUN: verify-filter-wrapped 'npm run build' trips the regex (false positive, confirmed)"

# ── 2. Under GOVERN_RUN=1 (a dispatch worker running its own mandated validation command), the
#        guard exits silently before the regex is ever evaluated: the false positive above never
#        reaches the worker.
out="$(GOVERN_RUN=1 bash "$GUARD" < "$PL")"
assert_eq "$out" "" "GOVERN_RUN=1: silent even for a command that substring-matches the regex"

# ── 3. Sanity: an unrelated command is silent either way (never a false negative on the exemption).
payload 'echo hello' "$PL"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL")"
assert_eq "$out" "" "no GOVERN_RUN + unrelated command: silent (nothing to warn about)"

assert_done
