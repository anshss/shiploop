#!/usr/bin/env bash
# advisor-consult.sh claim|record: gate and log a worker's advisor consult.
# A worker that reaches ONE fork it cannot resolve may buy a single scoped opus answer instead of
# guessing or failing outright.
#
# Same shape as gotchas-for-paths.sh: a thin CLI wrapper around the ONE implementation
# (govern::advisor_* in lib/common.sh) both worker lanes call. A consult is a LIVE decision only the
# running worker can make mid-session, and nothing is known in advance about whether or when one
# will fire, so unlike the gotchas mechanism there is no launcher-side injection at all: the
# headless worker and an interactive worker subagent both run THIS script themselves, the same way,
# at the moment they need it.
#
# Usage:
#   advisor-consult.sh claim <ticket-N> [--question "<scoped question>"] [--turn <n>]
#     Checks the remaining budget and prints ONE JSON decision line to stdout.
#       allow (exit 0): {"decision":"allow","consultId":N,"maxTokens":N,
#                         "workerRemaining":N,"sessionRemaining":N}
#     There is deliberately no model field here. An `allow` authorises ASKING the advisor session
#     that wrote the proposal, never SPAWNING one: nothing ever spawns an advisor.
#       deny  (exit 1): {"decision":"deny","reason":"disabled|worker-budget-exhausted|
#                         session-budget-exhausted","workerRemaining":N,"sessionRemaining":N}
#     A deny is not a cue to retry, reformulate, or consult anyway: an exhausted budget surfaces
#     to the operator, it never buys a tier by itself.
#   advisor-consult.sh record <ticket-N> <consultId> --model <model> --tokens <n> --answer "<summary>"
#     Closes the entry `claim` opened: the model that answered, tokens used, and a short summary.
#     Best-effort observability, not a gate: always exits 0 once its arguments parse.
#
# GOVERN_ADVISOR=0 (default, the kill switch) makes `claim` always deny with reason "disabled" and
# write nothing: the whole mechanism is a no-op until an operator turns it on. GOVERN_ADVISOR_PER_WORKER
# (default 2) / GOVERN_ADVISOR_PER_SESSION (default 6) / GOVERN_ADVISOR_MAX_TOKENS (default 4000) are
# three of the bounded-by-construction caps. GOVERN_ADVISOR_BUDGET, when set, overrides the per-worker
# cap for this dispatch only, scaled by how well-specified the work is (NEVER zero — every grade gets
# at least one consult): GOVERN_ADVISOR_PER_WORKER_OPEN's default 3, plain GOVERN_ADVISOR_PER_WORKER's
# default 2 for scoped, GOVERN_ADVISOR_PER_WORKER_STATED's default 1. The headless launcher
# (spawn-worker.sh) sets it from the ticket's precision grade before the live spawn; the interactive
# lane has no launcher, so its own worker (`.claude/agents/worker.md`) sets it inline on the
# `claim` invocation itself, after reading the grade off the ticket the same way. Unset (grade
# genuinely unreadable) falls back to plain GOVERN_ADVISOR_PER_WORKER, the same nonzero default
# every grade is built on top of.
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
