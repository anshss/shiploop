#!/usr/bin/env bash
# advisor-consult.sh claim|record: design Layer 3 (.specs/2026-09-09-model-orchestration-design.md).
# A worker that reaches ONE fork it cannot resolve may buy a single scoped opus answer instead of
# guessing or failing outright.
#
# Same shape as gotchas-for-paths.sh (#125/#176): a thin CLI wrapper around the ONE implementation
# (govern::advisor_* in lib/common.sh) both worker lanes call. A consult is a LIVE decision only the
# running worker can make mid-session, and nothing is known in advance about whether or when one
# will fire, so unlike the gotchas mechanism there is no launcher-side injection at all: the
# headless worker and an interactive worker subagent both run THIS script themselves, the same way,
# at the moment they need it.
#
# Usage:
#   advisor-consult.sh claim <ticket-N> [--question "<scoped question>"] [--turn <n>]
#     Checks the remaining budget and prints ONE JSON decision line to stdout.
#       allow (exit 0): {"decision":"allow","consultId":N,"advisorModel":"...","maxTokens":N,
#                         "workerRemaining":N,"sessionRemaining":N}
#       deny  (exit 1): {"decision":"deny","reason":"disabled|worker-budget-exhausted|
#                         session-budget-exhausted","workerRemaining":N,"sessionRemaining":N}
#     A deny is not a cue to retry, reformulate, or consult anyway: Layer 4 is explicit that an
#     exhausted budget surfaces to the operator, it never buys a tier by itself.
#   advisor-consult.sh record <ticket-N> <consultId> --model <model> --tokens <n> --answer "<summary>"
#     Closes the entry `claim` opened: the model that answered, tokens used, and a short summary.
#     Best-effort observability, not a gate: always exits 0 once its arguments parse.
#
# GOVERN_ADVISOR=0 (default, the kill switch) makes `claim` always deny with reason "disabled" and
# write nothing: the whole mechanism is a no-op until an operator turns it on. GOVERN_ADVISOR_PER_WORKER
# (default 2) / GOVERN_ADVISOR_PER_SESSION (default 6) / GOVERN_ADVISOR_MAX_TOKENS (default 4000) are
# the three bounded-by-construction caps. GOVERN_ADVISOR_BUDGET, when set (spawn-worker.sh sets it
# from the ticket's precision grade, Layer 2: 0 for stated/scoped, GOVERN_ADVISOR_PER_WORKER's
# default for open), overrides the per-worker cap for this dispatch only; unset (the interactive
# lane, which has no launcher and no grade) falls back to GOVERN_ADVISOR_PER_WORKER directly rather
# than being permanently zero-budgeted.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

usage() {
  echo "usage: $(basename "$0") claim <ticket-N> [--question \"...\"] [--turn <n>]" >&2
  echo "       $(basename "$0") record <ticket-N> <consultId> --model <model> --tokens <n> --answer \"...\"" >&2
}

verb="${1:-}"
[[ -n "$verb" ]] || { usage; exit 2; }
shift

case "$verb" in
  claim)
    n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || { usage; exit 2; }
    shift
    question=""; turn=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --question) question="${2:-}"; shift 2 ;;
        --turn)     turn="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done
    govern::advisor_claim "$n" "$question" "$turn"
    ;;
  record)
    n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || { usage; exit 2; }
    shift
    cid="${1:-}"
    [[ "$cid" =~ ^[0-9]+$ ]] || { usage; exit 2; }
    shift
    model=""; tokens="0"; answer=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model)  model="${2:-}"; shift 2 ;;
        --tokens) tokens="${2:-}"; shift 2 ;;
        --answer) answer="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done
    govern::advisor_record "$n" "$cid" "$model" "$tokens" "$answer"
    ;;
  *)
    usage
    exit 2
    ;;
esac
