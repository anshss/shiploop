#!/usr/bin/env bash
# ship.sh: the one command a worker runs to land its changes, from inside its own worktree.
#
# Publishing a change is mechanical, so a worker never improvises `git status`/`git log`/
# `git remote`/`gh pr` calls to work out what changed and where it goes. This script walks every sub-repo directory PLUS the worktree root itself, stages what changed, commits, pushes,
# and opens (or reuses) the PR, honoring the same public-repo branch/PR scheme
# deterministic-apply.sh already established (govern::ticket_branch / govern::repo_is_public).
#
# Usage:  ship.sh [--add <path>]... [--title <text>] [--body <text>] <N>[,<N>...]
#   <N>[,<N>...]   ticket number(s) this worktree resolves. More than one names a GROUP: one branch,
#                  one PR per sub-repo, keyed on the FIRST-named (primary) ticket.
#   --add <path>   an untracked file to stage too (repeatable, repo- or worktree-relative). Every
#                  OTHER untracked file is refused: a worker names what it created, this never
#                  guesses which untracked files belong in the commit.
#   --title/--body override the default (drawn from the primary ticket's own heading).
#
# Per sub-repo with changes: `git add -u` (tracked modifications) plus the named --add paths, commit,
# push, then reuse that repo's already-open PR on the branch or open one. Root-level changes (files
# changed directly under the worktree root, outside every sub-repo dir) are committed on the
# worktree's own detached HEAD only, never pushed, never a PR; the driver cherry-picks those commits
# onto main from the `rootScope` entry this script prints.
#
# A ticket number NEVER appears in a git commit message (unlike a PR title/body, a pushed commit
# can't be edited after the fact): hygiene the PUBLIC-REPO PR HYGIENE rule requires unconditionally.
# It appears in a PR's title/body only on a repo that is NOT public, matching deterministic-apply.sh;
# resolve-ticket.sh's own scrub is the backstop for whatever leaks through regardless.
#
# Never `gh pr edit`: its GraphQL query hard-fails on these repos, so PR body changes go through
# `gh api -X PATCH`.
#
# Idempotent: a re-run reuses an existing commit (nothing new staged), an already-pushed branch
# (push fast-forwards or no-ops), and the repo's already-open PR on that branch instead of a duplicate.
#
# `.dispatch-packet.md` is NEVER staged, even via --add: it is gitignored runtime state, not source.
# A workspace whose .gitignore predates the entry still ships: an untracked packet is skipped, never
# refused and never staged.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require git

ADD_PATHS=()
OPT_TITLE=""
OPT_BODY=""
TICKETS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add) ADD_PATHS+=("$2"); shift 2 ;;
    --title) OPT_TITLE="$2"; shift 2 ;;
    --body) OPT_BODY="$2"; shift 2 ;;
    -h|--help)
      echo "usage: ship.sh [--add <path>]... [--title <text>] [--body <text>] <N>[,<N>...]"
      exit 0
      ;;
    --) shift ;;
    -*) govern::die "unknown flag: $1" ;;
    *)
      if [[ -z "$TICKETS_ARG" ]]; then TICKETS_ARG="$1"; else govern::die "extra arg: $1"; fi
      shift
      ;;
  esac
done
[[ -n "$TICKETS_ARG" ]] || govern::die "usage: ship.sh [--add <path>]... [--title <text>] [--body <text>] <N>[,<N>...]"

IFS=',' read -r -a TICKET_NUMS <<< "$TICKETS_ARG"
for _t in "${TICKET_NUMS[@]}"; do
  [[ "$_t" =~ ^[0-9]+$ ]] || govern::die "not a ticket number: '$_t'"
done
PRIMARY="${TICKET_NUMS[0]}"
WORKTREE_PATH="$WS_ROOT"

# ── ticket text helpers ──────────────────────────────────────────────────────────────────────────
ticket_heading() { # N -> heading text, "" if the ticket isn't in TICKETS_FILE
  local n="$1"
  grep -m1 -E "^##[[:space:]]+#$n([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null \
    | sed -E "s/^##[[:space:]]+#${n}[[:space:]]*(—|-|,)?[[:space:]]*//"
}
# A ticket number must never survive into a git commit message (unlike a PR, a pushed commit can't
# be edited after the fact), so strip every named ticket's "#N" out of caller-supplied --title/--body
# before they reach `git commit`, regardless of repo visibility.
scrub_commit_text() {
  local s="$1" n
  for n in "${TICKET_NUMS[@]}"; do
    s="$(printf '%s' "$s" | sed -E "s/[[:space:]]*\(?#$n\)?//g")"
  done
  printf '%s' "$s"
}

DEFAULT_TITLE="$(ticket_heading "$PRIMARY")"
[[ -n "$DEFAULT_TITLE" ]] || DEFAULT_TITLE="resolve #$PRIMARY"
TITLE="${OPT_TITLE:-$DEFAULT_TITLE}"
DEFAULT_BODY="Resolves the linked ticket."
if [[ "${#TICKET_NUMS[@]}" -gt 1 ]]; then
  DEFAULT_BODY="Resolves a named group of tickets sharing measured file paths."
fi
BODY="${OPT_BODY:-$DEFAULT_BODY}"

COMMIT_SUBJECT="$(scrub_commit_text "$TITLE")"
COMMIT_BODY="$(scrub_commit_text "$BODY")"

# ── resolve every --add path to the dir (repo short name, or ROOT_KEY for the worktree root) it
# falls under. Bash 3.2 (macOS's own /bin/bash, and this codebase's floor) has no associative arrays, so the map is "key\trelpath" lines,
# looked up by grep, the same idiom flows-extract-merge.sh uses for the same reason. ─────────────
ROOT_KEY='@root'
ADD_LINES=""
resolve_add_path() { # <path> -> "<repo-or-ROOT_KEY>\t<dir-relative-path>"
  local p="$1" abs repo
  case "$p" in
    /*) abs="$p" ;;
    *)  abs="$WORKTREE_PATH/$p" ;;
  esac
  for repo in "${REPOS[@]}"; do
    case "$abs" in
      "$WORKTREE_PATH/$repo"/*)
        printf '%s\t%s\n' "$repo" "${abs#"$WORKTREE_PATH/$repo"/}"
        return 0
        ;;
    esac
  done
  printf '%s\t%s\n' "$ROOT_KEY" "${abs#"$WORKTREE_PATH"/}"
}
# named_for_dir <key> -> every --add'ed path under that dir, one per line ("" if none)
named_for_dir() { printf '%s\n' "$ADD_LINES" | awk -F'\t' -v k="$1" '$1==k{print $2}'; return 0; }
for _p in "${ADD_PATHS[@]+"${ADD_PATHS[@]}"}"; do
  _resolved="$(resolve_add_path "$_p")"
  _rel="${_resolved#*$'\t'}"
  [[ "$(basename "$_rel")" != ".dispatch-packet.md" ]] || govern::die "refusing to stage .dispatch-packet.md via --add: it is gitignored runtime state, never source"
  ADD_LINES="$ADD_LINES$_resolved"$'\n'
done

# ── candidate dirs: root (ROOT_KEY) + every configured sub-repo ──────────────────────────────────
DIR_KEYS=("$ROOT_KEY")
for _r in "${REPOS[@]}"; do DIR_KEYS+=("$_r"); done
dir_path_for() { [[ "$1" == "$ROOT_KEY" ]] && printf '%s' "$WORKTREE_PATH" || printf '%s/%s' "$WORKTREE_PATH" "$1"; return 0; }

# ── PASS 1: refuse before touching anything if an untracked file was not named via --add ─────────
REFUSALS=""
for _k in "${DIR_KEYS[@]}"; do
  _d="$(dir_path_for "$_k")"
  { [[ -d "$_d/.git" ]] || [[ -f "$_d/.git" ]]; } || continue
  _named="$(named_for_dir "$_k")"
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    _code="${_line:0:2}"; _f="${_line:3}"
    [[ "$_code" == "??" ]] || continue
    [[ "$(basename "$_f")" != ".dispatch-packet.md" ]] || continue
    grep -qxF "$_f" <<<"$_named" && continue
    _label="$_k"
    if [[ "$_label" == "$ROOT_KEY" ]]; then _label="<root>"; fi
    REFUSALS+="  $_label: $_f"$'\n'
  done < <(git -C "$_d" status --porcelain 2>/dev/null)
done
if [[ -n "$REFUSALS" ]]; then
  govern::die "untracked file(s) not named via --add (nothing staged, nothing committed):
$REFUSALS  -- name every new file explicitly with --add <path>, ship never guesses"
fi

# ── PASS 2: stage + commit + (sub-repo only) push + PR ────────────────────────────────────────────
PRS_JSON="[]"
PR_PRIMARY_JSON="null"
ROOT_COMMITS_JSON="[]"
ROOT_WORKTREE_NAME="$(basename "$WORKTREE_PATH")"

stage_dir() { # <dir> <key> -> rc 0 iff anything ended up staged
  local d="$1" k="$2" named nf
  named="$(named_for_dir "$k")"
  git -C "$d" add -u -- . >/dev/null 2>&1 || true
  while IFS= read -r nf; do
    [[ -n "$nf" ]] || continue
    git -C "$d" add -- "$nf"
  done <<< "$named"
  [[ -n "$(git -C "$d" diff --cached --name-only)" ]]
}

# Root (the worktree's own detached-at-main checkout): commit only, never push, never a PR.
if { [[ -d "$WORKTREE_PATH/.git" ]] || [[ -f "$WORKTREE_PATH/.git" ]]; } && [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]]; then
  if stage_dir "$WORKTREE_PATH" "$ROOT_KEY"; then
    git -C "$WORKTREE_PATH" commit -q -m "$COMMIT_SUBJECT" ${COMMIT_BODY:+-m "$COMMIT_BODY"}
    govern::log "root: committed on the worktree's detached HEAD ($(git -C "$WORKTREE_PATH" rev-parse --short HEAD))"
  fi
fi
# Report EVERY commit ahead of main on the root worktree, not just one this run made: a worker may
# call ship more than once, and the driver needs the full oldest-first list regardless.
if { [[ -d "$WORKTREE_PATH/.git" ]] || [[ -f "$WORKTREE_PATH/.git" ]]; }; then
  _root_base="$(git -C "$WORKTREE_PATH" rev-parse --verify -q origin/main 2>/dev/null || git -C "$WORKTREE_PATH" rev-parse --verify -q main 2>/dev/null || true)"
  if [[ -n "$_root_base" ]]; then
    ROOT_COMMITS_JSON="$(git -C "$WORKTREE_PATH" rev-list --reverse "$_root_base..HEAD" 2>/dev/null | jq -R . | jq -s '.' 2>/dev/null || echo '[]')"
  fi
fi

for _repo in "${REPOS[@]}"; do
  _dir="$(dir_path_for "$_repo")"
  { [[ -d "$_dir/.git" ]] || [[ -f "$_dir/.git" ]]; } || continue

  _base="$(govern::subrepo_default_branch "$_dir")"
  if [[ -n "$(git -C "$_dir" status --porcelain 2>/dev/null)" ]]; then
    if stage_dir "$_dir" "$_repo"; then
      git -C "$_dir" commit -q -m "$COMMIT_SUBJECT" ${COMMIT_BODY:+-m "$COMMIT_BODY"}
      govern::log "$_repo: committed ($(git -C "$_dir" rev-parse --short HEAD))"
    fi
  fi

  _ahead="$(git -C "$_dir" rev-list --count "origin/$_base..HEAD" 2>/dev/null || echo 0)"
  [[ "${_ahead:-0}" -gt 0 ]] || continue   # nothing for this repo at all (no staged diff, no prior commit)

  _branch="$(govern::ticket_branch "$PRIMARY" "$_repo")"
  govern::require gh
  _push_out="$(git -C "$_dir" push -u origin "HEAD:$_branch" 2>&1)" || govern::die "$_repo: git push failed: $(printf '%s' "$_push_out" | tail -3 | tr '\n' ' ')"
  govern::log "$_repo: pushed $_ahead commit(s) to $_branch"

  _slug="$(govern::repo_slug "$_repo")"
  _pr_title="$COMMIT_SUBJECT"
  _pr_body="$COMMIT_BODY"
  if ! govern::repo_is_public "$_repo"; then
    _refs="#${TICKET_NUMS[0]}"
    for ((_ti = 1; _ti < ${#TICKET_NUMS[@]}; _ti++)); do _refs+=", #${TICKET_NUMS[_ti]}"; done
    _pr_title="$_pr_title ($_refs)"
    _pr_body="$_pr_body

Ticket(s): $_refs."
  fi

  # Looked up per repo on this repo's own head branch, so a group spanning two sub-repos never
  # reports one repo's PR for the other.
  _found="$(gh pr list --repo "$_slug" --head "$_branch" --state open --json number,url,headRefName 2>/dev/null \
    | jq -c --arg b "$_branch" '[.[] | select(.headRefName == $b)][0] // empty' 2>/dev/null || true)"
  if [[ -n "$_found" ]]; then
    _pr_repo="$_repo"
    _pr_num="$(jq -r '.number' <<<"$_found")"
    _pr_url="$(jq -r '.url // ""' <<<"$_found")"
    govern::log "$_repo: reusing already-open PR $_pr_repo#$_pr_num"
  else
    _draft_flag=()
    govern::pr_draft && _draft_flag=(--draft)
    _pr_out="$(cd "$_dir" && gh pr create --repo "$_slug" --base "$_base" --head "$_branch" \
                --title "$_pr_title" --body "$_pr_body" ${_draft_flag[@]+"${_draft_flag[@]}"} 2>&1)" || govern::die "$_repo: gh pr create failed: $(printf '%s' "$_pr_out" | tail -3 | tr '\n' ' ')"
    _pr_url="$(printf '%s\n' "$_pr_out" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -1 || true)"
    [[ -n "$_pr_url" ]] || govern::die "$_repo: could not parse a PR URL out of: $_pr_out"
    _pr_num="${_pr_url##*/}"
    _pr_repo="$_repo"
    govern::log "$_repo: opened $_pr_url"
  fi

  PRS_JSON="$(jq -c --arg repo "$_pr_repo" --argjson num "$_pr_num" --arg url "$_pr_url" \
    '. + [{repo:$repo, number:$num, url:$url}]' <<<"$PRS_JSON")"
  if [[ "$PR_PRIMARY_JSON" == "null" ]]; then
    PR_PRIMARY_JSON="$(jq -c --arg repo "$_pr_repo" --argjson num "$_pr_num" --arg url "$_pr_url" -n '{repo:$repo, number:$num, url:$url}')"
  fi
done

# ── report skeleton ────────────────────────────────────────────────────────────────────────────
TICKETS_JSON="null"
if [[ "${#TICKET_NUMS[@]}" -gt 1 ]]; then
  TICKETS_JSON="$(printf '%s\n' "${TICKET_NUMS[@]}" | jq -R 'tonumber | {ticket: ., status: "resolved", note: ""}' | jq -s '.')"
fi
ROOT_SCOPE_JSON="null"
if [[ "$(jq 'length' <<<"$ROOT_COMMITS_JSON" 2>/dev/null || echo 0)" -gt 0 ]]; then
  ROOT_SCOPE_JSON="$(jq -c --arg wt "$ROOT_WORKTREE_NAME" --argjson commits "$ROOT_COMMITS_JSON" -n '{worktree:$wt, commits:$commits}')"
fi

jq -c --argjson pr "$PR_PRIMARY_JSON" --argjson prs "$PRS_JSON" --argjson rootScope "$ROOT_SCOPE_JSON" --argjson tickets "$TICKETS_JSON" -n \
  '{status:"resolved", pr:$pr, prs:$prs, rootScope:$rootScope, tickets:$tickets,
    lessonPatch:null, newTickets:[], crossRefs:{overlaps:[],dependsOn:[]}, migration:null, validation:null, escalation:null}'
