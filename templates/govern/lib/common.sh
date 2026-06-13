#!/usr/bin/env bash
# Shared helpers for the governor harness. Source, don't execute. Generic — all
# per-workspace values come from scripts/lib/workspace.sh, so /meta-repo:setup
# never edits this file.
set -euo pipefail

# Workspace root = three levels up from scripts/govern/lib/
GOVERN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${GOVERN_WS_ROOT:-$(cd "$GOVERN_LIB_DIR/../../.." && pwd)}"

# Pull repo list, org, and the auto-merge allowlist from the one config file.
# shellcheck source=../../lib/workspace.sh
source "$WS_ROOT/scripts/lib/workspace.sh"

GOVERNOR_DIR="$WS_ROOT/governor"
PREFERENCES_FILE="${GOVERN_PREFERENCES_FILE:-$GOVERNOR_DIR/preferences.md}"
ESCALATIONS_FILE="${GOVERN_ESCALATIONS_FILE:-$GOVERNOR_DIR/escalations.md}"
WORKER_PROMPT_FILE="${GOVERN_WORKER_PROMPT_FILE:-$GOVERNOR_DIR/worker-prompt.md}"
SUPERVISOR_PROMPT_FILE="${GOVERN_SUPERVISOR_PROMPT_FILE:-$GOVERNOR_DIR/supervisor-prompt.md}"
TICKETS_FILE="${GOVERN_TICKETS_FILE:-$WS_ROOT/tickets.md}"
# Manual-only defer queue the governor NEVER selects from (#62: a terminal-disposition escalation
# answer auto-migrates a ticket here so tickets.md stays the live govern-workable set).
TICKETS_PARKED_FILE="${GOVERN_TICKETS_PARKED_FILE:-$WS_ROOT/tickets-parked.md}"
# Driver→relay escalation hand-off (#62) — regenerated every run-end, gitignored runtime state.
PENDING_FILE="${GOVERN_PENDING_FILE:-$GOVERNOR_DIR/pending-escalations.json}"
LOG_ROOT="${GOVERN_LOG_ROOT:-$WS_ROOT/logs/govern}"

# Auto-mergeable repos (green-or-no-checks CI) come from workspace.sh. Frontend =
# everything else (PR-only).
GOVERN_FRONTEND_REPOS=()
for _r in "${REPOS[@]}"; do
  wsp_is_merge_repo "$_r" || GOVERN_FRONTEND_REPOS+=("$_r")
done
unset _r

govern::log() { printf '[govern %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
govern::die() { printf '[govern ERROR] %s\n' "$*" >&2; exit 1; }

govern::require() {
  command -v "$1" >/dev/null 2>&1 || govern::die "missing required tool: $1"
}

# ── escalation lifecycle (#62) ──────────────────────────────────────────────
# Parse the entries under "## Open" in escalations.md into NDJSON (one object per
# line) so the emit/apply scripts share ONE deterministic parser instead of each
# re-implementing markdown parsing. Fields are read line-oriented (each `- **X:**`
# is a single-line value — exactly how run-loop.sh writes a park block). Emits:
#   {ticket,title,reason,question,options,answer,disposition,makeRule}
# Reads $1 (defaults to ESCALATIONS_FILE). Prints nothing if the file/section is empty.
govern::escalations_open_ndjson() { # [escalations-file]
  local file="${1:-$ESCALATIONS_FILE}"
  [[ -f "$file" ]] || return 0
  awk '
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"",s); return s }
    function flush(){
      if(have){
        printf "{\"ticket\":%s,\"title\":\"%s\",\"reason\":\"%s\",\"question\":\"%s\",\"options\":\"%s\",\"answer\":\"%s\",\"disposition\":\"%s\",\"makeRule\":\"%s\"}\n", \
          t, jesc(title), jesc(reason), jesc(question), jesc(options), jesc(answer), jesc(disp), jesc(rule)
      }
      have=0; title="";reason="";question="";options="";answer="";disp="";rule=""
    }
    BEGIN{ in_open=0; have=0 }
    /^## Open/ { if(in_open) flush(); in_open=1; next }
    /^## /     { if(in_open) flush(); in_open=0; next }
    in_open && /^### +#[0-9]+/ {
      flush(); have=1
      t=$0; sub(/^### +#/,"",t); sub(/[^0-9].*/,"",t)
      title=$0; sub(/^### +#[0-9]+[^A-Za-z0-9]*/,"",title)
      next
    }
    in_open && have {
      line=$0
      if      (match(line,/^- \*\*Reason:\*\* ?/))            reason=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Question:\*\* ?/))          question=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Options:\*\* ?/))           options=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Answer:\*\* ?/))            answer=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Disposition:\*\* ?/))       disp=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Make this a rule\?:\*\* ?/)) rule=substr(line,RLENGTH+1)
    }
    END{ if(in_open) flush() }
  ' "$file"
}

# Is an Answer/Disposition field still the unfilled placeholder (or empty)?  The
# park template writes `_(operator)_`; treat any value containing it (or blank) as
# "operator has not answered yet".  Used to keep apply idempotent + pending honest.
govern::is_placeholder() { # value
  local v="$1"
  [[ -z "$v" ]] && return 0
  # Match the `_(operator...` stub regardless of what follows (the Disposition placeholder embeds
  # the option words, e.g. `_(operator: do-the-work | defer | keep-open)_`, so don't require `)`).
  case "$v" in *"(operator"*) return 0;; esac
  return 1
}

# Canonicalize a free-text disposition into one of: do-the-work | defer | keep-open
# (empty for unrecognized so the caller can leave the entry untouched). Tolerant of
# operator hand-edits / synonyms; the relay writes the canonical token directly.
govern::norm_disposition() { # raw -> canonical|""
  local d; d="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' ' ')"
  d=" $d "
  case "$d" in
    *" do the work "*|*" dothework "*|*" unpark "*|*" un park "*|*" retry "*|*" work it "*|*" resolve "*|*" redo "*) echo "do-the-work";;
    *" defer "*|*" defer indefinitely "*|*" wont do "*|*" won t do "*|*" keep manual "*|*" close "*|*" park "*|*" parked "*|*" no "*) echo "defer";;
    *" keep open "*|*" keepopen "*|*" wait "*|*" pending "*) echo "keep-open";;
    *) echo "";;
  esac
}

# Is $1 an auto-mergeable repo? (delegates to workspace.sh)
govern::is_merge_repo() { wsp_is_merge_repo "$1"; }

# Find an already-open PR for ticket $1 (branch standardized to "ticket-<N>" by
# worktree:new). Prints "repo number url" if found — lets a re-run resume instead
# of opening a duplicate PR.
govern::find_pr() {
  local n="$1" repo j num
  command -v gh >/dev/null 2>&1 || return 1
  # Search every sub-repo (REPOS is the union of merge + frontend, always
  # non-empty — avoids expanding a possibly-empty array under set -u on bash 3.2).
  for repo in "${REPOS[@]}"; do
    j="$(gh pr list --repo "$GITHUB_ORG/$repo" --head "ticket-$n" --state open --json number,url 2>/dev/null || echo '[]')"
    num="$(jq -r '.[0].number // empty' <<<"$j" 2>/dev/null || true)"
    if [[ -n "$num" ]]; then
      printf '%s %s %s\n' "$repo" "$num" "$(jq -r '.[0].url // ""' <<<"$j")"
      return 0
    fi
  done
  return 1
}
