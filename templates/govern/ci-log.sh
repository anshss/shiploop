#!/usr/bin/env bash
# ci-log.sh <repo> <pr> — print a BOUNDED excerpt of the failing CI job's log for a PR.
#
# §4.6 "verify in CI's environment". Workers verify on macOS; CI runs Linux (#13). A PR that is
# correct locally fails on a portability difference — a `sed -i` without a backup arg, a BSD-vs-GNU
# flag, a case-insensitive filesystem — and the governor dispatches a SECOND FULL WORKER for something
# entirely deterministic. That redispatch already happens (`GOVERN_FIX_CI` in run-loop.sh's
# merge_pr_for_ticket), but the re-dispatched worker is handed the SAME ticket prompt as the first
# one: `GOVERN_FIX_CI` is read in exactly one place (govern::retry_class, to pin the retry class to
# `ci` so the tier is not raised) and nowhere else. So the second worker rediscovers the CI failure
# from scratch, at full price, when the answer is sitting in a log file.
#
# This script is the missing input. It is DETERMINISTIC — `gh` only, zero model calls — and
# fail-open: any problem prints nothing and exits 1, so a caller that cannot get a log simply
# dispatches the worker exactly as it does today.
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
