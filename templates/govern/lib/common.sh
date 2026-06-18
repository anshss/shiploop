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

# Per-ticket worker-log directory (#75). RUN-SCOPED when GOVERN_RUN_DIR is set (run-loop exports
# it = $LOG_ROOT/run-<ts>), so a re-run of ticket N writes to a fresh run-<ts>/ticket-N/ and can
# NEVER read a PRIOR run's stale worker.jsonl. Falls back to the legacy flat $LOG_ROOT/ticket-N/
# only for a standalone spawn-worker invocation (tests / manual) where no run is in scope.
govern::worker_logdir() { # ticket -> dir
  local n="$1"
  if [[ -n "${GOVERN_RUN_DIR:-}" ]]; then echo "$GOVERN_RUN_DIR/ticket-$n"; else echo "$LOG_ROOT/ticket-$n"; fi
}

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

# Extract ONLY the leading token of a Disposition field — the first whitespace-delimited
# word, before any explanatory parenthetical (`_(...)_` or `(...)`). The disposition is
# ANCHORED to this leading token so a clarifying parenthetical that names another canonical
# token (e.g. `keep-open _(deliberately NOT do-the-work)_`, `defer (not do-the-work)`) is
# NOT misclassified by norm_disposition's anywhere-in-string match (#87). Returns "" if blank.
govern::disposition_lead_token() { # raw -> leading token (may be "")
  local d="$1"
  d="${d#"${d%%[![:space:]]*}"}"   # strip leading whitespace
  d="${d%%[[:space:]]*}"           # take up to the first whitespace (drops " _(...)_ ", " (...)")
  d="${d%%(*}"                     # drop a "(" attached with no space, e.g. defer(x)
  d="${d%%_*}"                     # drop a "_(" markdown wrapper attached with no space
  printf '%s' "$d"
}

# Canonicalize a free-text disposition into one of: do-the-work | defer | keep-open
# (empty for unrecognized so the caller can leave the entry untouched). Tolerant of
# operator hand-edits / synonyms; the relay writes the canonical token directly.
# NOTE: this matches a canonical token ANYWHERE in the input — so when classifying a
# structured Disposition FIELD, anchor first via govern::disposition_lead_token (#87).
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

# ── concurrency primitives (#41: safe parallel govern drivers on disjoint tickets) ──
# mkdir is atomic on POSIX, so an empty dir is a portable mutex. Both helpers reclaim a
# STALE lock (holder crashed) so a dead driver can't wedge the queue forever.
govern::_lock_age() { # lockdir -> seconds since mtime (0 if absent)
  local m; m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
  echo $(( $(date +%s) - m ))
}
# Blocking acquire: spin up to timeout_s. Returns 0 acquired, 1 timed out. Caller releases.
govern::lock_acquire() { # lockdir [timeout_s=60] [stale_s=300]
  local lock="$1" timeout="${2:-60}" stale="${3:-300}" waited=0
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  while ! mkdir "$lock" 2>/dev/null; do
    [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]] && { rmdir "$lock" 2>/dev/null && continue; }
    sleep 1; waited=$((waited+1)); [[ "$waited" -ge "$timeout" ]] && return 1
  done
  return 0
}
# Non-blocking try: claim once. Returns 0 claimed, 1 held by a live other holder.
govern::lock_try() { # lockdir [stale_s=4200]
  local lock="$1" stale="${2:-4200}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  mkdir "$lock" 2>/dev/null && return 0
  [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]] && { rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null && return 0; }
  return 1
}
govern::lock_release() { rmdir "$1" 2>/dev/null || true; }

# ── TokenJam cross-session run tagging (OTel resource attributes) ────────────
# Build the OTEL_RESOURCE_ATTRIBUTES string for a governor-spawned claude session so TokenJam groups
# EVERY session of one run (per-ticket workers + supervisor + self-improve) under a single
# `tokenjam.run_id` "Run". APPENDS to any INHERITED attributes (an onboarding / per-terminal claude
# wrapper may already set service.name / service.namespace / service.instance.id) — never clobbering
# them. The run id comes from TJ_RUN_ID (exported by run-loop.sh) or, for a standalone invocation, the
# persisted run-id file. service.instance.id is set to $1 (a distinct per-session label) ONLY when one
# isn't already present in the inherited attrs. Prints the assembled string; callers pass it to the
# child via `env OTEL_RESOURCE_ATTRIBUTES=...` — it is NEVER exported into the governor's own shell.
govern::otel_attrs() { # <instance-label> -> "k=v,k=v,..."
  local label="${1:-}" rid="${TJ_RUN_ID:-}" rfile attrs="${OTEL_RESOURCE_ATTRIBUTES:-}"
  if [[ -z "$rid" ]]; then
    rfile="${GOVERN_RUN_ID_FILE:-$GOVERNOR_DIR/.run-id}"
    [[ -s "$rfile" ]] && rid="$(tr -d '[:space:]' < "$rfile" 2>/dev/null || true)"
  fi
  [[ -n "$rid" ]] && attrs="${attrs:+$attrs,}tokenjam.run_id=$rid"
  [[ -n "$label" && "$attrs" != *"service.instance.id="* ]] && attrs="${attrs:+$attrs,}service.instance.id=$label"
  printf '%s' "$attrs"
}

# ── monotonic ticket numbering (#54, #73) ───────────────────────────────────
# THE single source of truth for "what's the next tickets.md number". Both the governor's
# auto-filing (govern-bookkeep) AND any manual filing (operator/relay sessions, /resolve sweeps,
# scripts/govern/file-ticket.sh) MUST route through here so a number is never silently reused.
#
# govern::ticket_filemax — highest `## #N` heading number in a file (0 if none). Scans ONE file:
# tickets.md and the parked queue are independent serial lists, so never cross-check them.
govern::ticket_filemax() { # [tickets-file] -> N
  local f="${1:-$TICKETS_FILE}" m
  m="$(grep -oE '^## #[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
  echo "${m:-0}"
}

# govern::next_ticket_number — allocate the next number: max(highest `## #N` in tickets.md,
# persisted high-water mark in governor/.ticket-seq) + 1, then bump .ticket-seq to it. A number is
# therefore NEVER reused — not after the highest ticket is resolved+deleted (#54), and not by a
# manual filing that never read/bumped the seq (#73). The read+bump is serialized under the bookkeep
# lock so two concurrent filers (a govern driver and an operator sweep) can't read the same max and
# collide on one number. Reentrant: a caller already holding the bookkeep lock (govern-bookkeep does)
# sets GOVERN_BOOKKEEP_LOCK_HELD=1 to skip re-acquiring (the mkdir mutex is NOT reentrant — a second
# acquire from the same process would spin to timeout). Prints the allocated number to stdout.
govern::next_ticket_number() { # [tickets-file] -> N
  local tickets_file="${1:-$TICKETS_FILE}"
  local seq_file="${GOVERN_TICKET_SEQ_FILE:-$GOVERNOR_DIR/.ticket-seq}"
  local lock="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
  local got_lock=0
  if [[ "${GOVERN_BOOKKEEP_LOCK_HELD:-0}" != "1" ]]; then
    if govern::lock_acquire "$lock" 60 300; then got_lock=1
    else govern::log "next_ticket_number: bookkeep lock busy >60s — proceeding (degraded)"; fi
  fi
  local hwm filemax maxn
  hwm="$( [[ -f "$seq_file" ]] && tr -dc '0-9' < "$seq_file" 2>/dev/null || echo 0)"; hwm="${hwm:-0}"
  filemax="$(govern::ticket_filemax "$tickets_file")"
  maxn=$(( hwm > filemax ? hwm : filemax ))
  maxn=$((maxn+1))
  printf '%s\n' "$maxn" > "$seq_file" 2>/dev/null || true
  [[ "$got_lock" == "1" ]] && govern::lock_release "$lock"
  printf '%s\n' "$maxn"
}

# govern::duplicate_ticket_headings — cheap collision detector (#73): print each ticket number that
# appears more than once as a `## #N` heading in the file (with its count), one per line. Returns 0
# (silent) when clean, 1 when any duplicate exists. The Stop hook / lint-tickets.sh treat a non-zero
# return as a fault to surface immediately. Scans ONE file (see ticket_filemax).
govern::duplicate_ticket_headings() { # [tickets-file]
  local f="${1:-$TICKETS_FILE}" dups n
  [[ -f "$f" ]] || return 0
  dups="$(grep -oE '^## #[0-9]+' "$f" | grep -oE '[0-9]+' | sort -n | uniq -d || true)"
  [[ -n "$dups" ]] || return 0
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    printf '#%s ×%s\n' "$n" "$(grep -cE "^## #${n}([^0-9]|\$)" "$f")"
  done <<<"$dups"
  return 1
}

# ── not-govern-automatable markers (#92) ────────────────────────────────────
# A ticket whose BODY carries a bold "not govern-automatable" marker
# (**NOT govern-automatable…**, **requires web-UI…**, **handle interactively…**) cannot be
# resolved by a headless CLI worker — selecting it just burns a worker / fast-fails every run
# until an operator manually `--exclude`s it. This helper is the SINGLE source of truth for that
# set: select-ticket.sh excludes them from selection, run-loop.sh logs the human-readable why
# (select-ticket's stderr is suppressed, so the log must come from the loop).
# Prints one "N<TAB>reason" line per flagged ticket (reason = the canonical marker keyword).
# Bold-ANCHORED on purpose: the marker must appear as `**marker…` so a ticket that merely
# DISCUSSES automatability in prose is NOT matched — only a real `**marker**` directive whose
# bold span STARTS with the marker phrase. Reads $1 (defaults to TICKETS_FILE).
govern::not_automatable_tickets() { # [tickets-file] -> "N\treason" lines
  local f="${1:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  awk '
    /^## #[0-9]+/ { cur=$0; sub(/^## #/,"",cur); sub(/[^0-9].*/,"",cur); emitted=0; next }
    cur!="" && !emitted {
      low=tolower($0)
      if      (low ~ /\*\*[ \t]*not[ \t]+govern-automatable/) m="NOT govern-automatable"
      else if (low ~ /\*\*[ \t]*requires[ \t]+web-?ui/)       m="requires web-UI"
      else if (low ~ /\*\*[ \t]*handled?[ \t]+interactively/) m="handle interactively"
      else m=""
      if (m!="") { printf "%s\t%s\n", cur, m; emitted=1 }
    }
  ' "$f"
}

# Is $1 an auto-mergeable repo? (delegates to workspace.sh)
govern::is_merge_repo() { wsp_is_merge_repo "$1"; }

# owner/repo slug + local checkout dir for a short repo name (both delegate to
# workspace.sh, where any cross-owner / out-of-tree overrides live). Default slug
# is "$GITHUB_ORG/<repo>"; default localdir is "$WS_ROOT/<repo>". merge-pr.sh uses
# these so a repo on a different owner / checked out elsewhere still merges + has
# its lingering local ticket-<N> branch cleaned up.
govern::repo_slug()     { wsp_repo_slug "$1"; }
govern::repo_localdir() { wsp_repo_localdir "$1"; }

# Find an already-open PR for ticket $1. The standard head is "ticket-<N>" (worktree:new), but a
# worker may have named its branch e.g. "fix/ticket-<N>-..." (#55) — so we match an exact
# "ticket-<N>" head FIRST, then fall back to ANY open-PR head CONTAINING "ticket-<N>" at a digit
# boundary (so "ticket-12" never matches "ticket-120"). Prints "repo number url" if found — lets a
# re-run resume instead of opening a duplicate PR, AND lets a same-run worker that opened a PR but
# returned a bad report still be adopted as resolved instead of recorded "failed".
govern::find_pr() {
  local n="$1" repo j row
  command -v gh >/dev/null 2>&1 || return 1
  # Search every sub-repo (REPOS is the union of merge + frontend, always
  # non-empty — avoids expanding a possibly-empty array under set -u on bash 3.2).
  for repo in "${REPOS[@]}"; do
    j="$(gh pr list --repo "$GITHUB_ORG/$repo" --state open --json number,url,headRefName 2>/dev/null || echo '[]')"
    row="$(jq -c --arg n "$n" '
      ( [ .[] | select(.headRefName == ("ticket-" + $n)) ][0] )
      // ( [ .[] | select(.headRefName | test("(^|[^0-9])ticket-" + $n + "([^0-9]|$)")) ][0] )
      // empty' <<<"$j" 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      printf '%s %s %s\n' "$repo" "$(jq -r '.number' <<<"$row")" "$(jq -r '.url // ""' <<<"$row")"
      return 0
    fi
  done
  return 1
}

# govern::ticket_present_on_origin — cross-driver re-selection guard for parallel drivers
# (GOVERN_ALLOW_CONCURRENT=1, #41). After a FRESH fetch, is a `## #N` block still present in
# origin/main's tickets.md? When two drivers share one origin/main, a second driver may have
# resolved+deleted #N (and pushed) AFTER this driver last pulled, so this driver's LOCAL
# tickets.md (what select-ticket read) is stale and still lists the done ticket. The run loop
# calls this right before spawning so it never burns a worker (or opens a duplicate PR / re-merges)
# on an already-resolved ticket — the per-ticket claim lock is a local-FS mutex that can't see
# another driver's origin push. Returns 0 = present (spawn), 1 = absent (skip). FAIL-OPEN
# (returns 0) when there's no origin, the fetch fails (offline), the file is unreadable, or
# GOVERN_NO_PUSH=1 — never block selection on an environment that can't verify against origin.
govern::ticket_present_on_origin() { # <repo-dir> <N>
  local d="$1" n="$2" rel content
  [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] || return 0
  git -C "$d" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$d" fetch -q origin main 2>/dev/null || return 0
  rel="$(basename "$TICKETS_FILE")"
  content="$(git -C "$d" show "origin/main:$rel" 2>/dev/null)" || return 0
  printf '%s\n' "$content" | grep -qE "^##[[:space:]]+#$n([^0-9]|\$)" && return 0
  return 1
}

# ── commit a tracked meta/runtime file to main (ported from harness #111 via #112) ──────────────
# Stage ONE tracked meta/runtime file, commit it (pathspec-scoped — never sweeps up unrelated staged
# changes), and publish to origin/main, keeping local main == origin/main. Used by the WRITER of a
# tracked governor runtime artifact (govern-improve.sh's governor/improvements.md) so it never lingers
# UNCOMMITTED — an uncommitted tracked file makes a later `git pull --rebase` on the main checkout
# (e.g. govern-bookkeep.sh's pre-edit origin sync, step 0) abort with "cannot pull with rebase: You
# have unstaged changes", a failure easily misread as a merge conflict. Mirrors bookkeep's commit+CAS-
# push: if origin advanced under us, rebase our append-only commit and retry; NEVER force-push (the
# #105 ff-only/no-force invariant that test-no-force-push.sh locks). Guarded + non-fatal — no-op
# outside a git repo or when there's nothing to commit; commits locally but skips the push under
# GOVERN_NO_PUSH=1 or with no origin (tests / offline). Always returns 0.
# Usage: govern::commit_meta_to_main <repo-dir> <relpath> <msg>
govern::commit_meta_to_main() {
  local d="$1" rel="$2" msg="$3" _a
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ( cd "$d"
    git add -- "$rel" 2>/dev/null || true
    git diff --cached --quiet -- "$rel" 2>/dev/null && exit 0   # nothing staged for $rel → no commit
    git commit -q -m "$msg" -- "$rel" || exit 0
    if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
      for _a in 1 2 3 4 5; do
        git push origin HEAD:main >/dev/null 2>&1 && break
        git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
      done
    fi )
  return 0
}

# ── infra/auth-outage detection (#90) ───────────────────────────────────────
# An infra outage (expired OAuth token, API unreachable, network down) kills a worker with a
# transport-level error BEFORE it can emit any report — on the surface IDENTICAL to a genuine
# ticket-fault failure. Recording it as a ticket `failed` (a) pollutes the cross-run #60 history
# (two such runs for the same ticket would FALSELY auto-escalate it as a systemic blocker) and
# (b) misleads govern-improve (it would analyse an auth outage as if the tickets were hard). These
# helpers let the loop tell the two apart: tag the outage distinctly (status:"infra"), skip the
# history record, and halt with a re-auth signal instead of the generic bad-streak message.
#
# The signature set is deliberately NARROW — auth (401 / invalid credentials / expired token) and
# transport (API unreachable / connection refused / socket / DNS / network) — and is only ever
# matched against the worker's AUTHORITATIVE result event (why the session ended) or the CLI's
# explicit "API Error:" stream lines, never arbitrary ticket content, so ordinary worker output
# can't trip it. Observed signatures: "API Error: Unable to connect to API (FailedToOpenSocket)" /
# "(ConnectionRefused)" and "401 Invalid authentication credentials".
GOVERN_INFRA_ERROR_RE='401[^A-Za-z0-9]*(Invalid authentication|Unauthorized)|Invalid authentication credentials|invalid x-api-key|authentication_error|OAuth token (has )?expired|token (has )?expired|Unable to connect to API|FailedToOpenSocket|Connection ?Refused|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENETUNREACH|getaddrinfo (ENOTFOUND|EAI_AGAIN)|Could not resolve host|network is unreachable'

# Print a short human signature of an infra/auth outage if the worker's stream ($1 = worker.jsonl)
# shows one in its final (error) result event or an explicit "API Error:" line; print nothing
# otherwise. Always returns 0 — the caller branches on whether the output is non-empty.
govern::infra_error_signature() { # worker-jsonl -> signature|""
  local jsonl="${1:-}" msg
  [[ -n "$jsonl" && -f "$jsonl" ]] || return 0
  # Authoritative: the LAST result event, only when it ended in an error.
  msg="$(grep '"type":"result"' "$jsonl" 2>/dev/null | tail -1 \
        | jq -r 'select(.is_error==true) | .result // empty' 2>/dev/null || true)"
  if [[ -n "$msg" ]] && printf '%s' "$msg" | grep -qiE "$GOVERN_INFRA_ERROR_RE"; then
    printf '%s' "$msg" | tr -d '\r' | tr '\n' ' ' | cut -c1-160; return 0
  fi
  # Fallback: the CLI prints "API Error: ..." lines into the stream even without a clean result.
  msg="$(grep -oiE 'API Error:[^"]*' "$jsonl" 2>/dev/null | grep -iE "$GOVERN_INFRA_ERROR_RE" | tail -1 || true)"
  [[ -n "$msg" ]] && printf '%s' "$msg" | tr -d '\r' | tr '\n' ' ' | cut -c1-160
  return 0
}

# ── tolerant worker-report extraction (#66) ─────────────────────────────────
# The strict contract is "the worker's final message is ONLY a single JSON object", but a worker
# that DID the work sometimes drifts to "JSON + trailing prose" (or writes prose into report.json).
# Requiring the WHOLE text to `jq empty`-parse then turns real work into a recorded `failed` (#66).
# These helpers make extraction tolerant: pull the LAST balanced {...} object that carries a
# `status` field out of arbitrary text, validating each candidate with jq. Happy path (the whole
# text is one clean object) still short-circuits, so the strict contract stays the fast path.

# Emit every top-level balanced {...} object found in stdin, each followed by a 0x1e (record
# separator — a control char JSON can't carry unescaped, so it never collides with content).
# String/escape-aware: braces inside JSON strings are not counted. Nested objects stay inside
# their parent (we only cut when depth returns to 0), so each emitted chunk is a whole object.
govern::_json_objects() {
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; ins = 0; esc = 0; start = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (ins) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { ins = 0 }
          continue
        }
        if (c == "\"") { ins = 1; continue }
        if (c == "{") { if (depth == 0) start = i; depth++ }
        else if (c == "}") {
          if (depth > 0) {
            depth--
            if (depth == 0) { printf "%s", substr(buf, start, i - start + 1); printf "%c", 30 }
          }
        }
      }
    }
  '
}

# Read arbitrary text on stdin (report.json content, or a worker .result message that may be
# "JSON + trailing prose"); print the chosen contract report — the LAST balanced object that
# parses AND has a `status` field. Prints nothing and returns 1 if no such object exists.
govern::extract_report() {
  local raw cand best=""
  raw="$(cat)"
  [[ -n "$raw" ]] || return 1
  # Happy path: the whole text is EXACTLY one valid object with a status field → emit verbatim.
  # (-s slurps the entire input into an array: length==1 rejects "JSON + trailing prose" and
  # multi-object streams, which fall through to the scanner so the LAST status object wins.)
  if printf '%s' "$raw" | jq -e -s 'length==1 and (.[0]|type=="object") and (.[0]|has("status"))' >/dev/null 2>&1; then
    printf '%s' "$raw"; return 0
  fi
  # Otherwise scan out balanced objects and keep the last one that is a valid status-bearing report.
  while IFS= read -r -d $'\x1e' cand; do
    [[ -n "$cand" ]] || continue
    if printf '%s' "$cand" | jq -e 'has("status")' >/dev/null 2>&1; then best="$cand"; fi
  done < <(printf '%s' "$raw" | govern::_json_objects)
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}
