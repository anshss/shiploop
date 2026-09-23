#!/usr/bin/env bash
# verify-filter.sh — run a verification command and let only INFORMATIVE bytes into context.
#
# Why: a worker session is an edit→test→edit→test loop, and `Bash` returns ~65% of all tool bytes in
# that session. A PASSING test run's output carries near-zero information, yet once it lands in the
# transcript it is re-sent on EVERY subsequent turn — the cost is accumulation across turns, not any
# single large result. This wrapper PREVENTS those bytes from entering; it is deliberately NOT a
# post-hoc truncator. (Capping tool results was explicitly rejected: the result-size distribution has
# no upper tail, so a 100 KB cap saves ~0%.) A FAILING run is the opposite — its output is the whole
# point — so failures are passed through, bounded only at the tail.
#
# The wrapped command's exit code is reproduced EXACTLY. This is load-bearing: callers branch on it.
#
# Usage:
#   verify-filter.sh -- <cmd> [args...]
#   verify-filter.sh <cmd> [args...]        # `--` optional
#
# Env:
#   GOVERN_VERIFY_FILTER=1|0            1 (default) filter; 0 = transparent pass-through, verbatim.
#   GOVERN_VERIFY_FILTER_MAX_LINES=200  tail bound applied to FAILING output only.
#
# Zero model invocations. Deterministic.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh is sourced BEST-EFFORT, unlike every sibling's hard `. lib/common.sh`. This wrapper is
# invoked from inside worker worktrees and from CI shells where scripts/lib/workspace.sh may not
# resolve; common.sh runs under `set -e`, so a hard source would abort the wrapper and swallow the
# wrapped command's exit code — the one thing this script must never do. Nothing here needs a
# govern:: helper, so degrading to "no common.sh" is fully correct.
# shellcheck source=lib/common.sh
# stderr is silenced too: a failed source would otherwise print a bash "no such file" line INTO the
# wrapped command's output stream — noise from a dependency this script does not actually need.
if [[ -f "$DIR/lib/common.sh" ]]; then . "$DIR/lib/common.sh" 2>/dev/null || true; fi

[[ "${1:-}" == "--" ]] && shift
[[ $# -gt 0 ]] || { echo "usage: verify-filter.sh [--] <cmd> [args...]" >&2; exit 2; }

# Transparent mode: become the command. No temp file, no wrapper semantics at all.
if [[ "${GOVERN_VERIFY_FILTER:-1}" != "1" ]]; then
  exec "$@"
fi

MAX_LINES="${GOVERN_VERIFY_FILTER_MAX_LINES:-200}"
[[ "$MAX_LINES" =~ ^[0-9]+$ ]] || MAX_LINES=200

# Capture to a temp FILE, never an in-memory variable: a long-running command must not be buffered
# unboundedly by this wrapper. Cleaned up on every exit path (normal, error, signal).
VF_TMP="$(mktemp "${TMPDIR:-/tmp}/govern-verify-filter.XXXXXX")"
trap 'rm -f "$VF_TMP" 2>/dev/null || true' EXIT INT TERM HUP

# Render the command for the summary line, bounded so a giant argv can't itself flood context.
vf::cmd_label() { # -> label
  local label
  label="$*"
  if [[ "${#label}" -gt 120 ]]; then label="${label:0:117}..."; fi
  printf '%s' "$label"
  return 0
}

CMD_LABEL="$(vf::cmd_label "$@")"

start="$SECONDS"
rc=0
# `set +e` around the run only — a non-zero exit here is DATA, not an error for this script.
set +e
"$@" >"$VF_TMP" 2>&1
rc=$?
set -e
elapsed=$(( SECONDS - start ))

# awk END{print NR} counts a trailing partial line correctly, unlike `wc -l`.
total_lines="$(awk 'END{print NR+0}' "$VF_TMP" 2>/dev/null || printf '0')"

if [[ "$rc" -eq 0 ]]; then
  printf 'PASS: %s — %s lines suppressed, %ss\n' "$CMD_LABEL" "$total_lines" "$elapsed"
  exit 0
fi

if [[ "$total_lines" -gt "$MAX_LINES" ]]; then
  printf -- '--- output truncated: showing the LAST %s of %s lines (GOVERN_VERIFY_FILTER_MAX_LINES) ---\n' \
    "$MAX_LINES" "$total_lines"
  tail -n "$MAX_LINES" "$VF_TMP"
else
  cat "$VF_TMP"
fi
printf 'FAIL(%s): %s — %s lines, %ss\n' "$rc" "$CMD_LABEL" "$total_lines" "$elapsed"
exit "$rc"
