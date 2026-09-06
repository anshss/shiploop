#!/usr/bin/env bash
# bench/local-gh.sh — a minimal, purely-local `gh` shim for the shiploop benchmark arm.
#
# bench/run.sh's offline guard strips every git remote before any arm spawns, so a real `gh` CLI
# would have nothing to reach anyway — but the shiploop arm still needs its worker's `gh pr create`
# and the governor's own `gh pr checks/view/merge` to DO something, or the loop can never actually
# land a fix and bench/arms.sh's write-back has nothing to copy back. This script is that something:
# bench::install_local_gh puts its directory first on PATH for the run-loop.sh subshell, so every
# `gh` call in that subprocess tree resolves here instead. It backs pr create/list/checks/view/merge
# with a flat JSONL ledger (BENCH_GH_LEDGER) and plain local git operations against
# BENCH_GH_REPO_DIR — no push, no network, no GitHub account, ever: `gh pr create` never needs
# the branch to have been pushed anywhere, it just reads local git state.
#
# The exact surface implemented is deliberately narrow — exactly what the shipped governor scripts
# call in a single-repo, --serial, PR-ticket-ref-skipped, merge-guard-bypassed run (see the
# `_GOVERN_ASSUME_MERGE_ALLOWED=1` / `GOVERN_PR_TICKET_REF=1` / pre-seeded `.repo-visibility` knobs
# bench::arm_shiploop sets, which are what keep the real surface this small). Anything unhandled
# exits 1 rather than fabricating a plausible-looking success.
#
# Required env: BENCH_GH_REPO_DIR (the sub-repo's scaffolded working copy), BENCH_GH_DEFAULT_BRANCH
# (the local branch bench::prepare_workdir pointed at the backlog's pinned ref), BENCH_GH_LEDGER (a
# JSONL file; created on first use).
set -euo pipefail

: "${BENCH_GH_REPO_DIR:?local-gh: BENCH_GH_REPO_DIR is required}"
: "${BENCH_GH_DEFAULT_BRANCH:?local-gh: BENCH_GH_DEFAULT_BRANCH is required}"
: "${BENCH_GH_LEDGER:?local-gh: BENCH_GH_LEDGER is required}"
[[ -f "$BENCH_GH_LEDGER" ]] || : > "$BENCH_GH_LEDGER"

_die() { printf 'local-gh: %s\n' "$1" >&2; exit 1; }

_next_number() { echo $(( $(wc -l <"$BENCH_GH_LEDGER" | tr -d ' ') + 1 )); }

# Last ledger line for PR <n> (a merge rewrites the whole file in place, so "last" == current).
_pr_row() { jq -c --argjson n "$1" 'select(.number == $n)' "$BENCH_GH_LEDGER" 2>/dev/null | tail -1; }

_open_prs_json() { jq -sc '[ .[] | select(.state == "OPEN") ]' "$BENCH_GH_LEDGER" 2>/dev/null; }

cmd_create() { # gh pr create --title T --body B [--base B] [--head H] [--draft] [--repo ...] ...
  local title="" body="" base="$BENCH_GH_DEFAULT_BRANCH" head="" draft=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --title=*) title="${1#*=}"; shift ;;
      --body) body="$2"; shift 2 ;;
      --body=*) body="${1#*=}"; shift ;;
      --body-file) body="$(cat "$2" 2>/dev/null || true)"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --base=*) base="${1#*=}"; shift ;;
      --head) head="$2"; shift 2 ;;
      --head=*) head="${1#*=}"; shift ;;
      --draft) draft=true; shift ;;
      --repo) shift 2 ;;
      --repo=*) shift ;;
      --fill|--fill-verbose|--assignee|--label|--reviewer) shift ;;
      *) shift ;;
    esac
  done
  # No --head: infer from CWD, exactly what real `gh pr create` does when run from inside a repo —
  # the worker is expected to be cd'd into its own worktree/ticket branch when it calls this.
  [[ -n "$head" ]] || head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$head" && "$head" != "HEAD" ]] || _die "pr create: could not determine the head branch (no --head, and CWD is not on a named branch)"
  local n url
  n="$(_next_number)"
  url="local-bench-pr://$n"
  jq -nc --argjson n "$n" --arg h "$head" --arg b "$base" --arg t "$title" --arg u "$url" --argjson d "$draft" \
    '{number:$n, headRefName:$h, baseRefName:$b, title:$t, url:$u, state:"OPEN", draft:$d}' >>"$BENCH_GH_LEDGER"
  printf '%s\n' "$url"
}

cmd_list() { # gh pr list --repo ... --state open --json number,url,headRefName
  _open_prs_json
}

cmd_checks() { # gh pr checks <PR> --repo ... --json bucket
  # No CI is configured anywhere in a scaffolded bench workspace — the golden-test-patch oracle runs
  # AFTER the arm, entirely outside the governor's view — so this is always checkless, honestly:
  # a real workspace with no CI provider gets the identical "none" outcome from await-ci.sh.
  printf '[]\n'
}

cmd_view() { # gh pr view <PR> [--repo ...] --json f1,f2 [-q '.expr']
  local pr="${1:?pr number required}"; shift
  local fields="" jqexpr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) fields="$2"; shift 2 ;;
      --json=*) fields="${1#*=}"; shift ;;
      -q) jqexpr="$2"; shift 2 ;;
      -q=*) jqexpr="${1#*=}"; shift ;;
      --repo) shift 2 ;;
      --repo=*) shift ;;
      *) shift ;;
    esac
  done
  local row; row="$(_pr_row "$pr")"
  [[ -n "$row" ]] || _die "pr view: no local PR #$pr"
  local obj="{}" f IFS=','
  read -ra fs <<<"$fields"
  for f in "${fs[@]}"; do
    case "$f" in
      statusCheckRollup) obj="$(jq -c '. + {statusCheckRollup: []}' <<<"$obj")" ;;
      headRefName)       obj="$(jq -c --argjson r "$row" '. + {headRefName: $r.headRefName}' <<<"$obj")" ;;
      state)             obj="$(jq -c --argjson r "$row" '. + {state: $r.state}' <<<"$obj")" ;;
      url)               obj="$(jq -c --argjson r "$row" '. + {url: $r.url}' <<<"$obj")" ;;
      number)            obj="$(jq -c --argjson r "$row" '. + {number: $r.number}' <<<"$obj")" ;;
    esac
  done
  if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" <<<"$obj"; else jq -c '.' <<<"$obj"; fi
}

cmd_merge() { # gh pr merge <PR> --repo ... --squash --delete-branch
  local pr="${1:?pr number required}"
  local row; row="$(_pr_row "$pr")"
  [[ -n "$row" ]] || _die "pr merge: no local PR #$pr"
  local head base
  head="$(jq -r '.headRefName' <<<"$row")"
  base="$(jq -r '.baseRefName' <<<"$row")"
  git -C "$BENCH_GH_REPO_DIR" rev-parse --verify "$head" >/dev/null 2>&1 \
    || _die "pr merge: local branch '$head' does not exist in $BENCH_GH_REPO_DIR"
  ( cd "$BENCH_GH_REPO_DIR" \
    && git checkout -q "$base" \
    && git merge -q --squash "$head" \
    && git -c user.email=bench@local -c user.name=bench-local-gh commit -q \
         -m "merge $head into $base (local bench gh shim, PR #$pr)" ) \
    || _die "pr merge: local squash-merge of $head into $base failed (conflict?)"
  local tmp; tmp="$(mktemp)"
  jq -c --argjson n "$pr" 'if .number == $n then .state = "MERGED" else . end' "$BENCH_GH_LEDGER" >"$tmp" \
    && mv "$tmp" "$BENCH_GH_LEDGER"
  return 0
}

cmd_api() { # gh api repos/<slug>/pulls/<n>/files [--paginate] [--jq '...']
  shift
  case "${1:-}" in
    */pulls/*/files) printf '[]\n' ;;   # a benchmark session never has a spec/plan file to flag
    *) _die "api: unhandled path '${1:-}'" ;;
  esac
}

case "${1:-}" in
  pr)
    sub="${2:-}"
    # Drop BOTH "pr" and the subcommand: each cmd_* below receives only its own arguments (the PR
    # number and flags), never the two dispatch tokens that got it there.
    shift 2 2>/dev/null || shift "$#"
    case "$sub" in
      create)        cmd_create "$@" ;;
      list)          cmd_list "$@" ;;
      checks)        cmd_checks "$@" ;;
      view)          cmd_view "$@" ;;
      merge)         cmd_merge "$@" ;;
      update-branch) exit 0 ;;   # no-op: nothing to rebase away from in a fresh single-branch clone
      *) _die "unhandled: gh pr $sub $*" ;;
    esac
    ;;
  api) cmd_api "$@" ;;
  repo) exit 1 ;;   # forces govern::repo_is_public's fail-safe (private) if this is ever reached
  --version) printf 'gh version 0.0.0-bench-local-shim\n' ;;
  *) _die "unhandled: gh $*" ;;
esac
