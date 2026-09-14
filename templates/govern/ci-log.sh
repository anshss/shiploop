#!/usr/bin/env bash
# ci-log.sh <repo> <pr> — print a BOUNDED excerpt of the failing CI job's log for a PR.
#
# Workers verify on macOS; CI runs Linux. A PR that is correct locally fails on a portability
# difference: a `sed -i` without a backup arg, a BSD-vs-GNU flag, a case-insensitive filesystem.
# and the reader of a bare refusal has no evidence of which one it was.
#
# `resolve-ticket.sh` calls this script on a red-CI refusal and prints its output on stderr
# alongside the refusal, so the advisor reading the refusal sees the actual failure instead of
# re-dispatching a worker to rediscover it from scratch.
#
# This script is the missing input. It is DETERMINISTIC — `gh` only, zero model calls — and
# fail-open: any problem prints nothing and exits 1, so a caller that cannot get a log is left with
# exactly the refusal it would have printed without this script.
#
# Env:
#   GOVERN_CI_LOG_MAX_LINES=120   tail bound on the excerpt (the whole point is bytes, not completeness)
#   GOVERN_GH_BIN=gh              gh binary
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

REPO="${1:-}"
PR="${2:-}"
[[ -n "$REPO" && -n "$PR" ]] || { printf 'usage: ci-log.sh <repo> <pr>\n' >&2; exit 2; }

GH_BIN="${GOVERN_GH_BIN:-gh}"
MAX_LINES="${GOVERN_CI_LOG_MAX_LINES:-120}"
MAX_LINES="${MAX_LINES//[^0-9]/}"; [[ -n "$MAX_LINES" ]] || MAX_LINES=120

command -v "$GH_BIN" >/dev/null 2>&1 || exit 1

slug="$(govern::repo_slug "$REPO" 2>/dev/null || true)"
[[ -n "$slug" ]] || exit 1

# The failing check's run id. `gh pr checks --json` gives the check name + its link; the run id is the
# numeric component of that link. Taking the FIRST failing check is deliberate — one failure's log is
# the signal; concatenating every failing job's log would reintroduce exactly the byte problem this
# whole design is about.
link="$("$GH_BIN" pr checks "$PR" --repo "$slug" --json bucket,link \
        --jq 'map(select(.bucket=="fail")) | .[0].link // empty' 2>/dev/null || true)"
[[ -n "$link" ]] || exit 1

run_id="$(printf '%s' "$link" | sed -nE 's#.*/runs/([0-9]+).*#\1#p')"
[[ -n "$run_id" ]] || exit 1

# `gh run view --log-failed` prints only the failing STEPS, which is already the filtered form — the
# same "prevent bytes entering, don't truncate after" shape as verify-filter.sh. Tail-bound it anyway:
# a genuinely broken job can still emit thousands of lines.
log="$("$GH_BIN" run view "$run_id" --repo "$slug" --log-failed 2>/dev/null | tail -n "$MAX_LINES" || true)"
[[ -n "${log//[[:space:]]/}" ]] || exit 1

printf '## Failing CI log — %s PR #%s (run %s)\n\n' "$REPO" "$PR" "$run_id"
printf 'This is the ACTUAL failure from CI'"'"'s environment (Linux), not your local one. You verified on\n'
printf 'this machine and it passed; CI disagreed. Read this before re-running anything locally — the\n'
printf 'difference is the bug. Last %s lines of the failing step(s):\n\n' "$MAX_LINES"
printf '```\n%s\n```\n' "$log"
exit 0
