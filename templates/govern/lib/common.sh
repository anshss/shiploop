#!/usr/bin/env bash
# Shared helpers for the governor harness. Source, don't execute. Generic — all
# per-workspace values come from scripts/lib/workspace.sh, so /shiploop:setup
# never edits this file.
set -euo pipefail

# Workspace root = three levels up from scripts/govern/lib/
GOVERN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="${GOVERN_WS_ROOT:-$(cd "$GOVERN_LIB_DIR/../../.." && pwd)}"

# Pull repo list, org, and the auto-merge allowlist from the one config file.
# Export META_ROOT=WS_ROOT first so the localdir helper (wsp_repo_localdir) honors a GOVERN_WS_ROOT
# test override and is NOT polluted by an inherited META_ROOT from the environment (the governor
# exports META_ROOT for its own run — without this pin, a hermetic test's seeded workspace.sh, which
# defaults `META_ROOT="${META_ROOT:-$T}"`, would resolve repo localdirs against the outer workspace
# and the merge-pr.sh #76 branch-cleanup backstop would silently no-op).
export META_ROOT="$WS_ROOT"
# shellcheck source=../../lib/workspace.sh
source "$WS_ROOT/scripts/lib/workspace.sh"

# Flow-registry substrate (validations feature). Sourced here so every govern:: consumer (bookkeep,
# run-loop, file-ticket, spawn-worker, lint) inherits the flow parser + cas_edit + lint helpers.
# Guarded on existence so a workspace scaffolded before this module shipped simply runs without it.
[[ -f "$GOVERN_LIB_DIR/flows.sh" ]] && source "$GOVERN_LIB_DIR/flows.sh"

GOVERNOR_DIR="$WS_ROOT/governor"
PREFERENCES_FILE="${GOVERN_PREFERENCES_FILE:-$GOVERNOR_DIR/preferences.md}"
ESCALATIONS_FILE="${GOVERN_ESCALATIONS_FILE:-$GOVERNOR_DIR/escalations.md}"
WORKER_PROMPT_FILE="${GOVERN_WORKER_PROMPT_FILE:-$GOVERNOR_DIR/worker-prompt.md}"
SUPERVISOR_PROMPT_FILE="${GOVERN_SUPERVISOR_PROMPT_FILE:-$GOVERNOR_DIR/supervisor-prompt.md}"
# The live + parked queues live in one folder at the meta-repo root: queue/. Override QUEUE_DIR to
# relocate the whole folder; the individual GOVERN_*_FILE overrides still win per-file (the tests
# point them at temp dirs).
QUEUE_DIR="${GOVERN_QUEUE_DIR:-$WS_ROOT/queue}"
TICKETS_FILE="${GOVERN_TICKETS_FILE:-$QUEUE_DIR/tickets.md}"
# Local ledger for the externalization lane (Low tickets filed as public issues). Only written when the
# lane runs; read at run-start by tickets_already_issues so a partially-healed filing (issue on GitHub
# but ledger not yet updated) still de-dups its ticket. Under queue/ alongside tickets.md.
EXTERNALIZED_FILE="${GOVERN_EXTERNALIZED_FILE:-$QUEUE_DIR/externalized.md}"
# Staging queue for the externalization REVIEW gate: eligible Low tickets are MOVED here (out of the
# live tickets.md) and held for one operator approval before any public issue is filed — the governor
# never auto-publishes. Same block format as tickets.md; the governor never SELECTS work from it.
EXTERNALIZE_REVIEW_FILE="${GOVERN_EXTERNALIZE_REVIEW_FILE:-$QUEUE_DIR/tickets-externalize-review.md}"
# Manual-only defer queue the governor NEVER selects from (#62: a terminal-disposition escalation
# answer auto-migrates a ticket here so tickets.md stays the live govern-workable set).
TICKETS_PARKED_FILE="${GOVERN_TICKETS_PARKED_FILE:-$QUEUE_DIR/tickets-parked.md}"
# Driver→relay escalation hand-off (#62) — regenerated every run-end, gitignored runtime state.
PENDING_FILE="${GOVERN_PENDING_FILE:-$GOVERNOR_DIR/pending-escalations.json}"
# Cross-run wait-for-merge / dependency deferrals (#119). Persists supervisor "defer #N until PR #M
# merges" advice (in-memory skipThisRun #57 evaporated at run-end) so a blocked ticket stays skipped
# across runs until its blocker lands. Per-machine runtime state (like ticket-history.jsonl) — gitignored.
PENDING_WAITS_FILE="${GOVERN_PENDING_WAITS_FILE:-$GOVERNOR_DIR/pending-waits.json}"
LOG_ROOT="${GOVERN_LOG_ROOT:-$WS_ROOT/logs/govern}"

# Per-ticket worker-log directory (#75). RUN-SCOPED when GOVERN_RUN_DIR is set (run-loop exports
# it = $LOG_ROOT/run-<ts>), so a re-run of ticket N writes to a fresh run-<ts>/ticket-N/ and can
# NEVER read a PRIOR run's stale worker.jsonl. Falls back to the legacy flat $LOG_ROOT/ticket-N/
# only for a standalone spawn-worker invocation (tests / manual) where no run is in scope.
govern::worker_logdir() { # ticket -> dir
  local n="$1"
  if [[ -n "${GOVERN_RUN_DIR:-}" ]]; then echo "$GOVERN_RUN_DIR/ticket-$n"; else echo "$LOG_ROOT/ticket-$n"; fi
}

# Auto-mergeable repos (green-or-no-checks CI) come from workspace.sh's
# GOVERN_MERGE_REPOS. Frontend (PR-only) = the sub-repos NOT in that allowlist,
# derived from REPOS. `harness` / a cross-owner skill-template repo live OUTSIDE
# $REPOS, so they never land here — they stay merge-universe-only. Space-separated
# to match the PR-search loops below.
GOVERN_FRONTEND_REPOS=""
for _r in "${REPOS[@]}"; do
  wsp_is_merge_repo "$_r" || GOVERN_FRONTEND_REPOS+="${GOVERN_FRONTEND_REPOS:+ }$_r"
done
unset _r

# #272: repos that represent SELF-REFERENTIAL governor/harness work (the #115 churn class — a run
# where most of the tickets were "port into templates" / harness self-improvement with near-zero
# PRODUCT value) rather than shipped product value. A resolved ticket whose PR(s) ALL target these
# repos is scored as "self-referential churn" by the ROI health summary (govern-health.sh). By
# DEFAULT this is the merge UNIVERSE (GOVERN_MERGE_REPOS) MINUS the product sub-repos ($REPOS) — i.e.
# exactly the auto-merge repos that live OUTSIDE $REPOS (the meta-repo itself + any skill-template
# repo on another owner). Everything in $REPOS (backend / frontend / …) is product work. Override
# GOVERN_SELFREF_REPOS (space-separated) to curate the set explicitly.
_govern_selfref_default=""
for _r in ${GOVERN_MERGE_REPOS:-}; do
  _in_repos=0
  for _x in "${REPOS[@]}"; do [[ "$_r" == "$_x" ]] && { _in_repos=1; break; }; done
  [[ "$_in_repos" == "1" ]] || _govern_selfref_default+="${_govern_selfref_default:+ }$_r"
done
GOVERN_SELFREF_REPOS="${GOVERN_SELFREF_REPOS:-$_govern_selfref_default}"
unset _r _x _in_repos _govern_selfref_default
govern::is_selfref_repo() { # repo -> 0 if self-referential (harness/templates), 1 otherwise
  local r="$1" x; for x in $GOVERN_SELFREF_REPOS; do [[ "$r" == "$x" ]] && return 0; done; return 1
}

# Shared safety-rail knob identifiers (#331). govern-self-apply.sh and govern-improve-triage.sh both
# need to recognize the same protected knobs; keeping the list in ONE place stops a rail added to one
# but not the other from leaving the knob unprotected in the other:
#   • govern-self-apply.sh greps the applied DIFF (case-sensitively) for these + its own diff-shape
#     guards (`destructive`, the merge-gate `"green" ||` clause).
#   • govern-improve-triage.sh greps each PROPOSAL LINE (case-INsensitively) for these + the
#     human-readable rail PHRASES the improve-reviewer writes ("auto-merge", "hard-stop", …).
# Only genuinely shared knob names live here; each script appends its own extras (see there). Alternation
# for `grep -E`; every token is a literal identifier (no regex metachars), so it composes safely with `|`.
GOVERN_PROTECTED_PATTERNS='GOVERN_MERGE_REPOS|is_merge_repo|bypassPermissions|GOVERN_PERMISSION_MODE|permflag|setting-sources|GOVERN_MAX_TICKETS|GOVERN_MAX_BAD_STREAK|GOVERN_MAX_RUNTIME|GOVERN_SELF_APPLY'

govern::log() { printf '[govern %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
govern::die() { printf '[govern ERROR] %s\n' "$*" >&2; exit 1; }

govern::require() {
  command -v "$1" >/dev/null 2>&1 || govern::die "missing required tool: $1"
}

# ── queue-folder location helpers ────────────────────────────────────────────
# The queue files live in queue/ (a subfolder), so dirname "$TICKETS_FILE" is the queue dir, NOT the
# meta-repo root. Anything that needs the ROOT (preflight reconcile, a root-level lessonPatch, or
# `git show <ref>:<path>`) must resolve it explicitly. These two helpers are the single source of truth.

# The meta-repo root = the git toplevel that owns the queue folder. Correct whether tickets.md sits in
# queue/ (production) or directly at the override dir (tests put it at the temp repo root); falls back
# to the queue dir itself when it isn't a git repo (non-git test fixtures).
govern::meta_root() { # -> abs path of the meta-repo root
  local qd; qd="$(dirname "$TICKETS_FILE")"
  git -C "$qd" rev-parse --show-toplevel 2>/dev/null || ( cd "$qd" && pwd )
}

# Repo-root-relative path of the tickets file (e.g. "queue/tickets.md", or "tickets.md" when it sits at
# the root) — for `git show <ref>:<path>` and root-anchored `git add`, where a bare basename would miss
# the queue/ prefix.
govern::tickets_relpath() { # -> path relative to the meta-repo root
  local qd prefix; qd="$(dirname "$TICKETS_FILE")"
  prefix="$(cd "$qd" 2>/dev/null && git rev-parse --show-prefix 2>/dev/null || true)"
  printf '%s%s' "$prefix" "$(basename "$TICKETS_FILE")"
}

# Fail CLOSED if a commit dir didn't resolve to a real git work-tree (#28). A commit dir is derived as
# `$(cd "$(dirname "$TICKETS_FILE")" && pwd)`; when that directory is MISSING the substitution yields an
# EMPTY string, and a later `cd "$commit_dir"` becomes `cd ""` — a no-op that leaves git running against
# the CURRENT working directory, so bookkeep could commit/push into the WRONG repo. Call this right after
# deriving any such commit dir, BEFORE any `cd`/git on it.
govern::assert_commit_dir() { # <dir>
  local d="${1:-}"
  [[ -n "$d" ]] && git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 \
    || govern::die "refusing to commit: '$d' is not a git work-tree (TICKETS_FILE='$TICKETS_FILE' — its dir missing?). A bare cd here would hit the CURRENT repo (#28)."
}

# ── escalation lifecycle (#62) ──────────────────────────────────────────────
# Parse the entries under "## Open" in escalations.md into NDJSON (one object per
# line) so the emit/apply scripts share ONE deterministic parser instead of each
# re-implementing markdown parsing. Fields are read line-oriented (each `- **X:**`
# is a single-line value — exactly how run-loop.sh writes a park block). Emits:
#   {ticket,title,opened,reason,question,options,answer,disposition,makeRule}
# Reads $1 (defaults to ESCALATIONS_FILE). Prints nothing if the file/section is empty.
govern::escalations_open_ndjson() { # [escalations-file]
  local file="${1:-$ESCALATIONS_FILE}"
  [[ -f "$file" ]] || return 0
  # #331: a NEW entry heading requires the `— ` title separator every writer emits (file_open_escalation
  # + run-loop's park block both print `### #N — <title>`). A bare `### #42` ref an operator pastes into
  # a multi-line Reason/Answer body therefore is NOT mistaken for a new entry. Then validate each emitted
  # object with jq before it reaches any caller, so a jesc-escaping regression can't silently ship
  # malformed NDJSON (a bad line is dropped with a stderr warning rather than corrupting a consumer's jq).
  awk '
    function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"",s); return s }
    function flush(){
      if(have){
        printf "{\"ticket\":%s,\"title\":\"%s\",\"opened\":\"%s\",\"reason\":\"%s\",\"question\":\"%s\",\"options\":\"%s\",\"answer\":\"%s\",\"disposition\":\"%s\",\"makeRule\":\"%s\",\"kind\":\"%s\"}\n", \
          t, jesc(title), jesc(opened), jesc(reason), jesc(question), jesc(options), jesc(answer), jesc(disp), jesc(rule), jesc(kind)
      }
      have=0; title="";opened="";reason="";question="";options="";answer="";disp="";rule="";kind=""
    }
    BEGIN{ in_open=0; have=0 }
    /^## Open/ { if(in_open) flush(); in_open=1; next }
    /^## /     { if(in_open) flush(); in_open=0; next }
    in_open && /^### +#[0-9]+ +— / {
      flush(); have=1
      t=$0; sub(/^### +#/,"",t); sub(/[^0-9].*/,"",t)
      title=$0; sub(/^### +#[0-9]+[^A-Za-z0-9]*/,"",title)
      next
    }
    in_open && have {
      line=$0
      if      (match(line,/^- \*\*Opened:\*\* ?/))            opened=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Kind:\*\* ?/))              kind=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Reason:\*\* ?/))            reason=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Question:\*\* ?/))          question=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Options:\*\* ?/))           options=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Answer:\*\* ?/))            answer=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Disposition:\*\* ?/))       disp=substr(line,RLENGTH+1)
      else if (match(line,/^- \*\*Make this a rule\?:\*\* ?/)) rule=substr(line,RLENGTH+1)
    }
    END{ if(in_open) flush() }
  ' "$file" | govern::_ndjson_validate
}

# Pass through only lines that parse as one JSON object; warn + drop anything malformed. jq is already a
# hard dependency of every escalations_open_ndjson consumer, but degrade safe if it's somehow absent
# (pass the raw stream through) rather than blanking every entry. #331.
govern::_ndjson_validate() {
  if ! command -v jq >/dev/null 2>&1; then cat; return 0; fi
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if printf '%s\n' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s\n' "$line"
    else
      printf '[govern WARN] escalations parser dropped malformed NDJSON: %s\n' "$line" >&2
    fi
  done
}

# Is an Answer/Disposition field still the unfilled placeholder (or empty)?  The
# park template writes `_(operator)_`; treat any value containing it (or blank) as
# "operator has not answered yet".  Used to keep apply idempotent + pending honest.
govern::is_placeholder() { # value
  local v="$1"
  [[ -z "$v" ]] && return 0
  # Match the `_(operator...` stub regardless of what follows (the Disposition placeholder embeds
  # the option words, e.g. `_(operator: do-the-work | defer | mitigated | keep-open)_`, so don't require `)`).
  case "$v" in *"(operator"*) return 0;; esac
  return 1
}

# Does escalations.md already carry an OPEN `### #N` escalation for ticket $1? Used to make the #120
# permanent-park nudge ONE-TIME: while a prior recommendation still sits under "## Open" awaiting the
# operator (or was kept open), don't re-file it. Returns 0 if an open entry exists, 1 otherwise.
govern::has_open_escalation() { # ticket -> 0 if an open ### #N entry exists
  local t="$1" hit
  [[ "$t" =~ ^[0-9]+$ ]] || return 1
  hit="$(govern::escalations_open_ndjson 2>/dev/null \
         | jq -r --argjson t "$t" 'select(.ticket == $t) | .ticket' 2>/dev/null | head -1)"
  [[ -n "$hit" ]]
}

# Is there already an OPEN escalation of a given Kind? The externalization review gate uses this to
# keep exactly ONE questionnaire open across runs (dedupe by `- **Kind:**`, not by ticket number,
# since one questionnaire spans many staged tickets — the sync-port "identity is a field, not #N"
# pattern). Prints the anchor ticket number of the first match; rc 0 if one exists, 1 otherwise.
govern::has_open_escalation_kind() { # kind -> prints anchor #N; rc 0 if an open entry of that kind exists
  local kind="$1" hit
  [[ -n "$kind" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  hit="$(govern::escalations_open_ndjson 2>/dev/null \
         | jq -r --arg k "$kind" 'select(.kind == $k) | .ticket' 2>/dev/null | head -1)"
  [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
  return 1
}

# Insert a standard escalation block under the "## Open" header in escalations.md (append to EOF if
# the header is absent). Writes the SAME field structure run-loop.sh's park path writes — Reason /
# Question / Options / Answer / Disposition / Make-this-a-rule — so escalations-apply-answers.sh can
# process the operator's Disposition (do-the-work | defer | mitigated | keep-open) at the next run-start.
# Args: ticket title reason question options [kind] [disposition-hint]. Live-only side effect — callers
# gate on mode. Optional trailing args (backward-compatible; existing 5-arg callers unchanged):
#   kind — writes a `- **Kind:** <kind>` line (escalations_open_ndjson emits it) so a bespoke lane
#          (e.g. externalize-review) can find + dispatch its own escalation without colliding with the
#          generic park lane.
#   disposition-hint — replaces the default Disposition placeholder help text (e.g. the review gate's
#          "approve-all | decide-later | move-back:<ids>") so the operator sees the right choices.
govern::file_open_escalation() { # N title reason question options [kind] [disp-hint]
  local N="$1" title="$2" reason="$3" question="$4" options="$5" kind="${6:-}" disphint="${7:-}" blk tmp kindline
  blk="$(mktemp)"
  kindline=""; [[ -n "$kind" ]] && kindline="- **Kind:** $kind"$'\n'
  [[ -n "$disphint" ]] || disphint="operator: do-the-work | defer | mitigated | keep-open"
  # #312: stamp `Opened` (date; run id if the caller exported one) so govern-health.sh can age it.
  printf '\n### #%s — %s\n- **Opened:** %s%s\n%s- **Reason:** %s\n- **Question:** %s\n- **Options:** %s\n- **Answer:** _(operator)_\n- **Disposition:** _(%s)_\n- **Make this a rule?:** _(operator)_\n' \
    "$N" "$title" "$(date +%F)" "${TJ_RUN_ID:+ (run $TJ_RUN_ID)}" "$kindline" "$reason" "$question" "$options" "$disphint" > "$blk"
  if grep -q '^## Open' "$ESCALATIONS_FILE" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v bf="$blk" '{print} /^## Open/ && !done {while ((getline l < bf) > 0) print l; close(bf); done=1}' \
      "$ESCALATIONS_FILE" > "$tmp" && mv "$tmp" "$ESCALATIONS_FILE"
  else
    cat "$blk" >> "$ESCALATIONS_FILE" 2>/dev/null || true
  fi
  rm -f "$blk"
  # #14: an escalations.md writer must COMMIT its append SAME-STEP — an uncommitted tracked
  # escalations.md makes the NEXT run's preflight `git pull --rebase` abort on a dirty tree, which the
  # governor misreports as a rebase conflict and self-blocks its own start (the recurring-orphan class).
  # commit_meta_to_main is scoped to escalations.md, CAS/rebase-safe, push-guarded, and a no-op outside
  # a git repo, so this is the single choke point that keeps every file_open_escalation caller clean.
  govern::_commit_escalations "file escalation #$N ($title)"
}

# Commit ONLY escalations.md to main via the CAS-safe path (#14). Derives the repo root + repo-relative
# path from $ESCALATIONS_FILE so it works whether escalations.md sits at governor/ (production) or an
# override dir (tests). No-op (returns 0) outside a git repo. Shared by every escalations.md writer.
govern::_commit_escalations() { # <commit-subject-tail>
  local subj="$1" edir eroot erel
  edir="$(dirname "$ESCALATIONS_FILE")"
  eroot="$(git -C "$edir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$eroot" ]] || return 0
  erel="$(git -C "$edir" rev-parse --show-prefix 2>/dev/null)$(basename "$ESCALATIONS_FILE")"
  govern::commit_meta_to_main "$eroot" "$erel" "docs(governor): $subj"
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

# Canonicalize a free-text disposition into one of: do-the-work | kill | defer | mitigated | keep-open
# (empty for unrecognized so the caller can leave the entry untouched). `kill` (validations Phase 5) is
# the operator's disposition on a measured-INEFFECTIVE flow: delete the feature — apply-answers files a
# removal ticket and the sweep tombstones the flow on its PR. Matched BEFORE mitigated/defer so its
# tokens never fall through. Tolerant of
# operator hand-edits / synonyms; the relay writes the canonical token directly.
# NOTE: this matches a canonical token ANYWHERE in the input — so when classifying a
# structured Disposition FIELD, anchor first via govern::disposition_lead_token (#87).
# `mitigated` (#121): the situation is already acceptable / harm is zero — close the ticket as
# accepted-current-state. Mechanically like `defer` (leaves the live queue) but NOT parked as
# still-todo; the apply step removes the block from tickets.md and resolves the escalation with a
# "resolved — mitigated" note (see escalations-apply-answers.sh). Matched BEFORE defer so its
# synonyms (e.g. "accept current state", "harm already zero") never fall through to defer.
govern::norm_disposition() { # raw -> canonical|""
  local d; d="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' ' ')"
  d=" $d "
  case "$d" in
    *" do the work "*|*" dothework "*|*" unpark "*|*" un park "*|*" retry "*|*" work it "*|*" resolve "*|*" redo "*) echo "do-the-work";;
    *" kill "*|*" killit "*|*" tombstone "*) echo "kill";;
    *" mitigated "*|*" mitigate "*|*" accept current state "*|*" accept as is "*|*" accepted "*|*" already acceptable "*|*" harm zero "*|*" harm already zero "*) echo "mitigated";;
    *" defer "*|*" defer indefinitely "*|*" wont do "*|*" won t do "*|*" keep manual "*|*" close "*|*" park "*|*" parked "*|*" no "*) echo "defer";;
    *" keep open "*|*" keepopen "*|*" wait "*|*" pending "*) echo "keep-open";;
    # Externalization review-gate dispositions — LAST so a generic answer that also happens to name a
    # canonical token above wins there. apply-answers only ACTS on these for a Kind==externalize-review
    # escalation, so over-matching a non-externalize answer here is harmless (it falls through to
    # keep-open there). `move-back:1,5` → `move back 1 5` after the non-alnum collapse, so `move back`
    # matches; the id payload is parsed from the RAW field by the caller, not from this token.
    *" approve all "*|*" approveall "*|*" externalize all "*|*" file all "*|*" approve "*) echo "approve-all";;
    *" move back "*|*" moveback "*|*" send back "*) echo "move-back";;
    *" decide later "*|*" decidelater "*|*" decide "*) echo "decide-later";;
    *) echo "";;
  esac
}

# ── concurrency primitives (#41: safe parallel govern drivers on disjoint tickets) ──
# mkdir is atomic on POSIX, so an empty dir is a portable mutex. The holder pid is recorded
# INSIDE the lock dir so stale reclaim is PID-liveness-aware: a lock whose holder is still
# alive is NEVER stolen, even if its mtime clock-ages past the stale window (a genuine ticket
# can run > default stale window: worker + await-ci + CI-fix re-dispatch + conflict-resolve).
# Only when the recorded holder pid is DEAD (crashed driver) or the pid file is missing do
# we fall back to the mtime stale window as a backstop.
govern::_lock_age() { # lockdir -> seconds since mtime (0 if absent)
  # GNU stat first (Linux, CI), then BSD stat (macOS). Order matters: on GNU stat,
  # `stat -f %m file` treats `-f` as --file-system and prints multi-line "File: …"
  # noise on stdout while exiting non-zero — the subshell would then concatenate that
  # with the fallback's numeric output, breaking the arithmetic below.
  local m; m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  # Belt-and-suspenders: strip any non-digits that snuck through, so a partial stdout
  # from a stat variant we don't recognize can never poison the arithmetic.
  m="${m//[!0-9]/}"; [[ -n "$m" ]] || m=0
  echo $(( $(date +%s) - m ))
}
# Read the holder pid recorded inside a claim/bookkeep lock dir. Returns "" when absent
# (a pre-#pid-liveness lock or a partial write from a killed acquire).
govern::_lock_holder_read() { # lockdir -> pid|""
  [[ -f "$1/holder" ]] || return 0
  tr -dc '0-9' < "$1/holder" 2>/dev/null || true
}
# Stamp the current pid into the lock dir. Best-effort — mkdir succeeded so the dir exists;
# a failed write just leaves the lock pid-less (falls back to the mtime stale window).
govern::_lock_stamp_pid() { # lockdir
  printf '%s\n' "$$" > "$1/holder" 2>/dev/null || true
}
# Is a lock reclaimable? Yes iff no holder pid is recorded (mtime fallback) OR the recorded
# pid is dead. Callers gate an mtime-stale reclaim on this so a LIVE holder is never stolen.
govern::_lock_holder_dead() { # lockdir -> 0 (dead / no holder), 1 (alive)
  local hpid; hpid="$(govern::_lock_holder_read "$1")"
  [[ -n "$hpid" ]] || return 0
  kill -0 "$hpid" 2>/dev/null && return 1 || return 0
}
# Refresh the lock's mtime so its "age" measures time since the last heartbeat, NOT time
# since acquire. Called from the run-loop main loop per iteration so a long-running claim
# (worker + await-ci + fix re-dispatch) never appears stale.
govern::lock_heartbeat() { # lockdir
  [[ -d "$1" ]] && { touch "$1" 2>/dev/null || true; }
}
# Parse a YYYY-MM-DD date into epoch seconds, portably across BSD (macOS) and GNU date.
# Prints the epoch on success; returns 1 (prints nothing) on a malformed/empty date.
govern::date_to_epoch() { # YYYY-MM-DD -> epoch
  local d="${1:-}"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null || date -d "$d" +%s 2>/dev/null
}
# Blocking acquire: spin up to timeout_s. Returns 0 acquired, 1 timed out. Caller releases.
# Reclaims a stale lock ONLY when the recorded holder pid is dead (or missing) AND mtime is
# past the stale window — never steals from a still-alive holder.
govern::lock_acquire() { # lockdir [timeout_s=60] [stale_s=300]
  local lock="$1" timeout="${2:-60}" stale="${3:-300}" waited=0
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  while ! mkdir "$lock" 2>/dev/null; do
    if govern::_lock_holder_dead "$lock" && [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]]; then
      rm -rf "$lock" 2>/dev/null && continue
    fi
    sleep 1; waited=$((waited+1)); [[ "$waited" -ge "$timeout" ]] && return 1
  done
  govern::_lock_stamp_pid "$lock"
  return 0
}
# Non-blocking try: claim once. Returns 0 claimed, 1 held by a live other holder.
# Default stale raised to worst-case ticket wall-clock so an unheartbeated long ticket doesn't
# false-trip; the pid-liveness check above the mtime fallback is the LOAD-BEARING invariant here.
govern::lock_try() { # lockdir [stale_s=18000]
  local lock="$1" stale="${2:-18000}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then govern::_lock_stamp_pid "$lock"; return 0; fi
  if govern::_lock_holder_dead "$lock" && [[ "$(govern::_lock_age "$lock")" -gt "$stale" ]]; then
    rm -rf "$lock" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then govern::_lock_stamp_pid "$lock"; return 0; fi
  fi
  return 1
}
# Release: rm -rf (not rmdir) because the lock now holds a `holder` file.
govern::lock_release() { rm -rf "$1" 2>/dev/null || true; }

# ── Worker process-tree teardown (#242) ─────────────────────────────────────
# Killing the governor (Stop / SIGTERM) used to leave its spawn-worker.sh + child worker process
# (and any grandchildren it spawned) ALIVE — reparented to init, needing a manual `kill -9` sweep; a
# worker orphaned mid-task can keep a billable resource alive. The fix has two layers, both wired here:
#   1. the worker process is launched under `set -m` so it leads its OWN process group (pgid==pid),
#      so a SINGLE `kill -- -pid` reaches the whole subtree at once, even descendants that reparent.
#   2. these helpers tear that subtree down on EVERY stop path (timeout watchdog, spawn-worker
#      INT/TERM/EXIT trap, run-loop INT/TERM/EXIT trap).
#
# _kill_tree_walk recursively signals a pid's live descendants (pgrep -P) before the pid itself —
# the belt-and-suspenders fallback that still reaches a child which escaped into its own group.
govern::_kill_tree_walk() { # pid signal
  local pid="$1" sig="$2" c
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  for c in $(pgrep -P "$pid" 2>/dev/null); do govern::_kill_tree_walk "$c" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}
# kill_tree: TERM the whole subtree of LEADER pid (process group first — reaches reparented kin —
# then a pid-tree walk for anything in its own group), wait up to grace_s for the leader to die,
# then KILL whatever is left the same two ways. Best-effort throughout; safe if pid is already gone.
govern::kill_tree() { # leader_pid [grace_s=5]
  local pid="$1" grace="${2:-5}" i=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -TERM -"$pid" 2>/dev/null || true   # whole process group (set -m leader)
  govern::_kill_tree_walk "$pid" TERM
  while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt "$grace" ]]; do sleep 1; i=$((i+1)); done
  kill -KILL -"$pid" 2>/dev/null || true
  govern::_kill_tree_walk "$pid" KILL
}

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
# ── shared ticket-block parser (single source of truth) ─────────────────────
# Historically each caller re-parsed tickets.md block boundaries differently: spawn-worker /
# govern-bookkeep bounded at the FIRST `^---$` (which a bare `---` inside a ticket body truncates
# — worker prompt gets a short block, bookkeep delete leaves orphaned body lines); select-ticket /
# not_automatable / ticket_deps bounded at the next `## #` heading, but the heading regex requires
# an exact `## #N ` (single space), so `##  #N` (double-space) or `## #N—Title` (em-dash, no space)
# breaks recognition. These helpers are the SINGLE source of truth: block boundary = next tolerant
# `^##[[:space:]]+#<digits>` heading OR EOF; a bare `---` inside the body is treated as content,
# not a boundary; the block INCLUDES its trailing `---` separator so `_delete` doesn't leave
# orphaned separators.
#
# govern::ticket_block — print the whole block for ticket $1 from its heading through the last
# line before the next `## #<digits>` heading (or EOF). Includes the trailing `---` separator
# if one is present. Reads $2 (default TICKETS_FILE). Empty output if the ticket isn't found.
govern::ticket_block() { # N [tickets-file]
  local n="$1" f="${2:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  awk -v n="$n" '
    /^##[[:space:]]+#[0-9]+/ {
      if ($0 ~ ("^##[[:space:]]+#" n "([^0-9]|$)")) { grab=1; print; next }
      if (grab) exit
    }
    grab { print }
  ' "$f"
}

# govern::ticket_block_delete — rewrite $2 (default TICKETS_FILE) with ticket $1's block removed:
# the heading line, its body, and the trailing `---` separator that belongs to this block. The
# separator is consumed with the block so we never leave a doubled-separator artifact. A bare
# `---` inside the body no longer terminates the delete early (the boundary is the next `## #`
# heading, not the first `---`). Silent no-op if the ticket isn't present. Uses tmp+mv so the
# original file is never truncated mid-write.
govern::ticket_block_delete() { # N [tickets-file]
  local n="$1" f="${2:-$TICKETS_FILE}" tmp
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp)"
  awk -v n="$n" '
    /^##[[:space:]]+#[0-9]+/ {
      if ($0 ~ ("^##[[:space:]]+#" n "([^0-9]|$)")) { grab=1; next }
      grab=0
    }
    grab { next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp" 2>/dev/null
}

# ── PR hygiene: strip the internal ticket-id + surface leaked spec files ─────────────────────────
# The internal ticket number (#N) is a LOCAL-queue id — meaningless (and noise) on a public repo.
# The worker doctrine forbids it in the PR title/body, but a headless LLM worker sometimes emits it
# anyway, so this is the DETERMINISTIC backstop: after a PR is known, PATCH its title+body to drop
# references to THIS ticket's number. We match ticket-ref SHAPES ("Fix #N:", "fix(#N):", "(#N)", bare
# "#N") for the exact number N, with a trailing non-digit boundary so #6 never touches #60. `gh pr
# edit` can be broken repo-wide by the classic-Projects deprecation, so we PATCH via the REST API.
# Commit SUBJECTS can also carry #N, but rewriting pushed history = force-push = a hard-stop, so those
# stay prompt-enforced only; title+body is what renders most prominently.
govern::_strip_ticket_ref() { # text N -> text with #N ticket-refs removed + tidied
  local t="$1" n="$2"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s' "$t"; return 0; }
  # Wrapper forms first, then bare #N (trailing boundary via a captured non-digit char, BSD-sed safe).
  t="$(printf '%s' "$t" | sed -E \
    -e "s/[Ff]ix\(#$n\):?[[:space:]]*//g" \
    -e "s/[Ff]ix #$n:[[:space:]]*//g" \
    -e "s/[[:space:]]*\(#$n\)//g" \
    -e "s/#$n([^0-9]|$)/\1/g")"
  # Tidy: collapse runs of spaces, trim, drop a now-dangling leading ':' / em-dash.
  printf '%s' "$t" | sed -E 's/[[:space:]]{2,}/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^[:—-][[:space:]]*//'
}

govern::scrub_pr_ticket_ref() { # slug pr N   (slug = owner/repo)
  local slug="$1" pr="$2" n="$3" j cur body newt newb
  command -v gh >/dev/null 2>&1 || return 0
  [[ -n "$slug" && -n "$pr" && "$n" =~ ^[0-9]+$ ]] || return 0
  # Fetch the raw PR object and extract locally with DEFENSIVE jq — a non-object response (an error
  # payload, a rate-limit body, or a test stub) must no-op the scrub, never spill a jq "cannot index
  # array" error. (Relying on gh's own `--jq` masked this: a stub/odd gh that ignores --jq returns the
  # raw shape, and a bare `.t` on a non-object then errors.)
  j="$(gh api "repos/$slug/pulls/$pr" 2>/dev/null || true)"
  printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1 || return 0
  cur="$(printf '%s' "$j" | jq -r '.title // ""' 2>/dev/null || true)"
  body="$(printf '%s' "$j" | jq -r '.body // ""' 2>/dev/null || true)"
  newt="$(govern::_strip_ticket_ref "$cur" "$n")"
  newb="$(govern::_strip_ticket_ref "$body" "$n")"
  [[ "$newt" == "$cur" && "$newb" == "$body" ]] && return 0    # nothing leaked — idempotent no-op
  if gh api -X PATCH "repos/$slug/pulls/$pr" -f title="$newt" -f body="$newb" >/dev/null 2>&1; then
    govern::log "scrubbed internal ticket-id #$n from $slug#$pr title/body (local id, not for the public repo)"
  else
    govern::log "WARN could not scrub #$n from $slug#$pr via REST — operator: edit the PR to drop the #$n reference"
  fi
}

# Surface (do NOT auto-rewrite) any Claude spec/plan/design artifact that leaked into a PR's diff.
# Those belong in the ROOT harness (.specs/ / .plans/ are gitignored per repo); they must never land
# in a public sub-repo PR. Every non-merge repo is PR-only (a human merges), so a loud WARN + the file
# list is enough to get them stripped in review — we don't force-push a worker's branch. Prints
# offending paths, one per line.
govern::pr_spec_files() { # slug pr -> offending paths
  local slug="$1" pr="$2"
  command -v gh >/dev/null 2>&1 || return 0
  [[ -n "$slug" && -n "$pr" ]] || return 0
  gh api "repos/$slug/pulls/$pr/files" --paginate --jq '.[].filename' 2>/dev/null \
    | grep -E '(^|/)\.(specs|plans)/|(^|/)[0-9]{4}-[0-9]{2}-[0-9]{2}-.*-(design|spec|plan)\.md$' || true
}

# ── externalization lane: Low-severity OSS-repo tickets → public GitHub Issues ───────────────────
# Print one bare ticket number per OPEN ticket eligible for externalization. Eligibility is PRINCIPLED,
# not just (Low + Where-mentions-target) — a Low ticket qualifies ONLY when ALL hold (#75):
#   1. **Severity:** Low, AND
#   2. its **Where:** references the OSS sub-repo (GOVERN_EXTERNALIZE_SUBREPO), AND
#   3. its Where does NOT target the HARNESS (scripts/ governor/ queue/ workspace.sh meta-repo harness) —
#      a governor-internals ticket must never become a public "good first issue", even if its Where also
#      names the OSS sub-repo (e.g. "meta-repo harness — scripts/govern/…; surfaced on <oss> ticket"), AND
#   4. it is NOT a VALIDATION / SPIKE / decision ticket (heading contains VALIDATION|SPIKE, a
#      `**Type:** … validation/spike` line, or `live-verif`) — those are internal product decisions with
#      empirical-run deliverables, not contributor tasks, and can leak internal strategy.
# Block-scoped — every field is read ONLY within ticket #N's own block (heading → its trailing `---`).
#
# THE load-bearing detail on (2): the Where match EXCLUDES sibling sub-repos whose name merely CONTAINS
# the OSS name as a substring (e.g. `myproject-website` ⊃ `myproject`). We strip every such sibling
# (derived from REPOS) out of the Where line FIRST, then test the remainder for the OSS name.
#
# No GOVERN_EXTERNALIZE_SUBREPO set → the lane is off → this helper returns nothing (opt-in gate).
govern::externalize_candidates() { # [tickets-file] -> eligible ticket numbers, one per line
  local f="${1:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  local target="${GOVERN_EXTERNALIZE_SUBREPO:-}" r
  [[ -n "$target" ]] || return 0
  # Sibling sub-repos whose name CONTAINS the target as a substring — strip these before testing.
  local siblings=()
  for r in "${REPOS[@]}"; do
    [[ "$r" != "$target" && "$r" == *"$target"* ]] && siblings+=("$r")
  done
  # Harness markers: if the Where names any of these, the ticket is governor-internal → never externalize.
  local hmarkers="scripts/ governor/ queue/ workspace.sh meta-repo harness"
  awk -v target="$target" -v siblings="${siblings[*]:-}" -v hmarkers="$hmarkers" '
    function flush() { if (cur!="" && sev=="low" && oss==1 && harness==0 && valid==0 && never==0) print cur }
    BEGIN { ns=split(siblings, sib, " "); nh=split(hmarkers, HM, " ") }
    /^## #[0-9]+/ {
      flush(); cur=$0; sub(/^## #/,"",cur); sub(/[^0-9].*/,"",cur); sev=""; oss=0; harness=0; valid=0; never=0
      # (4) validation/spike, or a maintainer-DECISION ticket ("… — decide X vs Y"), in the heading
      if ($0 ~ /VALIDATION|SPIKE/ || tolower($0) ~ /decide /) valid=1
      next
    }
    cur!="" {
      low=tolower($0)
      if ($0 ~ /^\*\*Severity:\*\*/) { if (low ~ /low/) sev="low" }
      # (5) operator opt-OUT: a `**Externalize:** never` field (set by the review gate move-back path)
      # permanently excludes the ticket from staging, so a rejected ticket never re-stages.
      else if ($0 ~ /^\*\*Externalize:\*\*/) { if (low ~ /never/) never=1 }
      else if ($0 ~ /^\*\*Where:\*\*/) {
        w=$0
        for (i=1;i<=ns;i++) if (sib[i]!="") gsub(sib[i], "", w)
        if (index(w, target) > 0) oss=1            # (2) targets the OSS sub-repo
        wl=tolower(w)
        for (i=1;i<=nh;i++) if (HM[i]!="" && index(wl, HM[i])>0) harness=1   # (3) harness-scoped → exclude
      }
      # (4) body-based validation markers
      if (low ~ /^\*\*type:\*\*.*(validation|spike)/ || low ~ /live-verif/) valid=1
    }
    END { flush() }
  ' "$f"
}

# ── externalization: label-apply permission rejection (#26) ──────────────────
# `gh issue create --label …` is a COMPOSITE op: it creates the issue (URL on stdout, exit 0) and
# THEN applies the labels in a separate GraphQL `addLabelsToLabelable` mutation. When the authed gh
# account has only `pull` on the repo (no triage/push), GitHub CREATES the issue but REJECTS the
# label step — and that rejection lands ONLY on stderr while the URL is still returned. Discarding
# stderr (`2>/dev/null`) and inferring success from a non-empty URL therefore logs `filed` while
# every label was silently dropped. This regex matches that label-permission rejection so the lane
# can distinguish "filed + labeled" from "filed but labels REJECTED — account lacks Triage on repo".
GOVERN_LABEL_PERM_ERROR_RE='addLabelsToLabelable|could not add label|fail(ed)? to (add|apply) label|labels? (were|was) not (added|applied)|Resource not accessible|Must have (admin|write|triage|push)|requires (admin|write|triage|push)'

# Does gh's create stderr ($1) show the issue was filed but its LABELS were rejected on a permission
# gap? Returns 0 (label rejection present) / 1 (none). Safe on empty input. Always case-insensitive.
govern::label_apply_rejected() { # gh-create-stderr -> 0 if a label-permission rejection is present
  local err="${1:-}"
  [[ -n "$err" ]] || return 1
  printf '%s' "$err" | grep -qiE "$GOVERN_LABEL_PERM_ERROR_RE"
}

# ── pre-run: tickets that already exist as a PUBLIC GitHub issue (reserved for outside contributors) ──
# Issues on GOVERN_EXTERNALIZE_REPO are seeded for EXTERNAL contributors; the internal governor must
# not ALSO work a ticket that's already published as one. Matches each open ticket against LIVE open
# issues by NORMALIZED-title equality (lowercase, non-alnum→space, trim) — conservative on purpose
# (an exact-normalized match, not fuzzy overlap, so a legit ticket is never wrongly skipped) — and
# against the externalized ledger by #N (the partial-heal edge where a filed ticket lingers here).
# Prints "N<TAB>url" per matched ticket. Read-only; one gh call. Empty when gh/jq absent or no match.
govern::tickets_already_issues() { # [tickets-file] -> "N\turl" lines
  local f="${1:-$TICKETS_FILE}" repo="${GOVERN_EXTERNALIZE_REPO:-}" issues=""
  [[ -f "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [[ -n "$repo" ]] && command -v gh >/dev/null 2>&1; then
    issues="$(gh issue list --repo "$repo" --state open --limit 500 --json title,url \
      --jq '.[] | ((.title|ascii_downcase|gsub("[^a-z0-9]+";" ")|gsub("^ +| +$";"")) + "\t" + .url)' 2>/dev/null || true)"
  fi
  # Ledger: a #N still present here despite being recorded externalized (partial-heal edge).
  local led=""
  [[ -f "${EXTERNALIZED_FILE:-}" ]] && led="$(grep -oE '^- #[0-9]+ ' "$EXTERNALIZED_FILE" 2>/dev/null | grep -oE '[0-9]+' || true)"
  # Pass issues/led via the ENVIRONMENT, not `-v`: awk's -v assignment can't carry embedded newlines
  # (a newline terminates the value), and both are multi-line. ENVIRON handles newlines fine.
  _GV_ISSUES="$issues" _GV_LED="$led" awk '
    BEGIN {
      n=split(ENVIRON["_GV_ISSUES"], L, "\n"); for(i=1;i<=n;i++){ p=index(L[i],"\t"); if(p){ IU[substr(L[i],1,p-1)]=substr(L[i],p+1) } }
      m=split(ENVIRON["_GV_LED"], LD, "\n"); for(i=1;i<=m;i++) if(LD[i]!="") LED[LD[i]]=1
    }
    /^## #[0-9]+ —/ {
      num=$0; sub(/^## #/,"",num); sub(/ .*/,"",num)
      title=$0; sub(/^## #[0-9]+ —[[:space:]]*/,"",title)
      t=tolower(title); gsub(/[^a-z0-9]+/," ",t); gsub(/^ +| +$/,"",t)
      if (t in IU)      { print num "\t" IU[t]; next }
      if (num in LED)   { print num "\t(recorded in externalized ledger)" }
    }
  ' "$f"
}

# ── advisory: tickets targeting NEITHER the project NOR the harness (isolation backstop) ─────────
# The queue admits exactly two scopes: this workspace's own sub-repos (REPOS) and the harness itself
# (scripts/ governor/ queue/ hooks/ workspace.sh/ CLAUDE.md/ meta-repo). A ticket whose **Where:**
# line references NONE of those is likely about EXTERNAL tooling that merely shared the terminal.
# This is a SOFT advisory — allowlist-based (flag only on the ABSENCE of any in-scope marker on the
# Where line), so a legit ticket that targets a sub-repo but happens to mention an external tool is
# NOT flagged. No Where line ⇒ never flagged. Prints "N<TAB>Where-text"; the caller decides how to
# surface it (never a hard fault — deleting the ticket is always the operator's call). Read-only.
govern::out_of_scope_tickets() { # [tickets-file] -> "N\twhere" lines
  local f="${1:-$TICKETS_FILE}" r markers="scripts/ governor/ queue/ workspace.sh claude.md meta-repo harness .omc"
  [[ -f "$f" ]] || return 0
  for r in "${REPOS[@]}"; do markers="$markers ${r}"; done
  _GV_MARKERS="$markers" awk '
    BEGIN{ n=split(tolower(ENVIRON["_GV_MARKERS"]), M, /[ ]+/) }
    /^## #[0-9]+/ { if(cur!="" && wl!="" && !inscope) print cur "\t" wl; cur=$0; sub(/^## #/,"",cur); sub(/[^0-9].*/,"",cur); inscope=0; wl=""; next }
    cur!="" && $0 ~ /^\*\*Where:\*\*/ {
      wl=$0; sub(/^\*\*Where:\*\*[[:space:]]*/,"",wl); gsub(/`/,"",wl)
      low=tolower($0)
      for(i=1;i<=n;i++){ if(M[i]!="" && index(low,M[i])>0){ inscope=1; break } }
    }
    END{ if(cur!="" && wl!="" && !inscope) print cur "\t" wl }
  ' "$f"
}

# ── validation gate decision (#67 + #73) ─────────────────────────────────────
# Given a worker's resolved report for a VALIDATION-type ticket, decide the gate action. Pure — no
# side effects; the caller applies it. Prints exactly one of:
#   park-no-evidence — the live test was NOT run (ranLiveTest!=true or empty evidence)  [#67]
#   park-gate-failed — the test RAN but its OWN gate FAILED (gatePassed==false, a measured negative);
#                      the ship-vs-kill disposition is the operator's, not the worker's              [#73]
#   resolve          — gate passed, or no explicit gate (gatePassed absent → "unknown" → auto-resolve)
# NB: jq's `//` treats false as null, so `.gatePassed // "unknown"` would MISREAD a failed gate as
# "unknown"; we branch on the boolean explicitly. Absent gatePassed ⇒ "unknown" ⇒ resolve, so pre-#73
# workers and non-gated validations are unaffected.
govern::validation_gate_action() { # report-json -> park-no-evidence | park-gate-failed | resolve
  local report="$1" ranlive eviden gatepass
  ranlive="$(printf '%s' "$report" | jq -r '.validation.ranLiveTest // false' 2>/dev/null || echo false)"
  eviden="$(printf '%s' "$report" | jq -r '.validation.evidence // ""' 2>/dev/null || true)"
  gatepass="$(printf '%s' "$report" | jq -r 'if .validation.gatePassed == false then "false" elif .validation.gatePassed == true then "true" else "unknown" end' 2>/dev/null || echo unknown)"
  if [[ "$ranlive" != "true" || -z "$eviden" ]]; then echo "park-no-evidence"
  elif [[ "$gatepass" == "false" ]]; then echo "park-gate-failed"
  else echo "resolve"; fi
}

govern::not_automatable_tickets() { # [tickets-file] -> "N\treason" lines
  local f="${1:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  awk '
    /^##[[:space:]]+#[0-9]+/ { cur=$0; sub(/^##[[:space:]]+#/,"",cur); sub(/[^0-9].*/,"",cur); emitted=0; next }
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

# govern::sync_port_collision_tickets — tickets that touch a file with an OPEN
# sync-port manual-port escalation (#314). Each open `sync-port:` escalation carries a
# structured `- **Files:** <space-separated live paths>` line (written by sync-port.sh's
# file_sync_escalation) naming the harness files whose port is mid-flight on a `sync-auto-*`
# branch. Selecting a ticket that edits one of those exact paths THIS run risks colliding
# with that in-progress manual port (the #309 sync-port-branch collision the supervisor
# caught only by reading both by hand). Exclude such a ticket the same way
# not_automatable_tickets() does — it stays in tickets.md and becomes selectable again the
# moment the sync-port escalation resolves (branch merged, entry moves out of `## Open`).
# Match is on the FULL path token as written in the Files line (substring within the ticket
# block), so a ticket that merely mentions a bare basename does not false-collide.
# Emits "N\t<first colliding path>" lines (tab-separated), like not_automatable_tickets.
govern::sync_port_collision_tickets() { # [tickets-file] [escalations-file] -> "N\tpath" lines
  local tf="${1:-$TICKETS_FILE}" ef="${2:-$ESCALATIONS_FILE}"
  # -s on the escalations file: an EMPTY escalations file would collapse the two-file FNR==NR
  # split (NR never advances), mis-parsing the first ticket line — and it can carry no collisions
  # anyway, so short-circuit.
  [[ -f "$tf" && -s "$ef" ]] || return 0
  # Single two-file pass (escalations THEN tickets) — carries the path set in an awk array so it
  # survives BSD awk (no newline-bearing -v allowed). First file builds PATH_SET from every OPEN
  # sync-port escalation's Files: line; second file emits N\t<path> for the first path a ticket
  # block contains.
  awk '
    FNR==NR {
      if ($0 ~ /^## Open/)     { in_open=1; next }
      if ($0 ~ /^## Resolved/) { in_open=0; next }
      if ($0 ~ /^## /)         { in_open=0; next }
      if (in_open && $0 ~ /^### +#[0-9]+/) { is_sync=($0 ~ /sync-port:/); next }
      if (in_open && is_sync && $0 ~ /^- \*\*Files:\*\*/) {
        line=$0; sub(/^- \*\*Files:\*\* */,"",line)
        n=split(line, a, /[ \t]+/)
        for (i=1;i<=n;i++) if (a[i]!="") PATH_SET[a[i]]=1
      }
      next
    }
    /^##[[:space:]]+#[0-9]+/ {
      if (cur!="" && hit!="") printf "%s\t%s\n", cur, hit
      cur=$0; sub(/^##[[:space:]]+#/,"",cur); sub(/[^0-9].*/,"",cur); hit=""; next
    }
    cur!="" && hit=="" {
      for (p in PATH_SET) if (index($0,p)>0) { hit=p; break }
    }
    END { if (cur!="" && hit!="") printf "%s\t%s\n", cur, hit }
  ' "$ef" "$tf"
}

# ── chronically-skipped NA tickets → permanent-disposition nudge (#120) ──────
# The #92 selector auto-skips a "NOT govern-automatable" ticket every run — correct, but on its own
# the ticket churns a skip note forever and never leaves the live queue. We persist a per-ticket
# count of CONSECUTIVE runs each NA ticket is auto-skipped so the loop can, after K runs, file ONE
# escalation recommending the operator escalate+defer it permanently (migrate to tickets-parked.md),
# instead of re-noting it every run. Per-machine runtime state (like ticket-history.jsonl) — gitignored.
NA_SKIP_FILE="${GOVERN_NA_SKIP_FILE:-$GOVERNOR_DIR/na-skip-counts.json}"

# Increment ticket $1's consecutive auto-skip count; print the new count (>=1). Prints 0 (no-op)
# without jq. Creates the file if absent.
govern::na_skip_bump() { # ticket -> new count
  local t="$1" f="$NA_SKIP_FILE" cur tmp
  command -v jq >/dev/null 2>&1 || { echo 0; return 0; }
  [[ "$t" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  cur="$([[ -s "$f" ]] && cat "$f" || echo '{"counts":{}}')"
  tmp="$f.tmp.$$"
  if printf '%s' "$cur" | jq -c --arg t "$t" '.counts[$t] = ((.counts[$t] // 0) + 1)' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
    jq -r --arg t "$t" '.counts[$t] // 0' "$f" 2>/dev/null || echo 0
  else
    rm -f "$tmp" 2>/dev/null || true; echo 0
  fi
}

# Drop count entries for any ticket NOT in the given current-NA set (comma-WRAPPED, e.g. ",45,72,"),
# so a ticket that becomes automatable / gets resolved resets its streak and never triggers a stale
# nudge later. Pass "," to reset everything (no NA tickets this run). No-op without jq.
govern::na_skip_prune() { # ",N,N," (current NA set, comma-wrapped)
  local set="$1" f="$NA_SKIP_FILE" tmp
  command -v jq >/dev/null 2>&1 || return 0
  [[ -s "$f" ]] || return 0
  tmp="$f.tmp.$$"
  if jq -c --arg set "$set" \
       '{counts: ((.counts // {}) | with_entries(.key as $k | select($set | contains("," + $k + ","))))}' \
       "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Is $1 an auto-mergeable repo? (delegates to workspace.sh)
govern::is_merge_repo() { wsp_is_merge_repo "$1"; }

# ── Trust ladder (GOVERN_AUTONOMY) ──────────────────────────────────────────
# observe → workers open DRAFT PRs; governor never merges (work visible, inert).
# pr-only → workers open normal PRs; governor never merges (a human merges).
# auto    → full autonomy: governor auto-merges green/none-CI allowlisted PRs (pre-ladder behavior).
# BACKWARD COMPAT (load-bearing): an ABSENT or EMPTY knob — a workspace.sh scaffolded before the
# ladder shipped never sets GOVERN_AUTONOMY — resolves to `auto`, so existing installs are UNCHANGED.
# The scaffold TEMPLATE seeds `pr-only` for new adopters (workspace.sh). An unrecognized value also
# degrades to `auto` — the ladder never SILENTLY disables a configured install on a typo; a real
# downshift is an explicit `observe`/`pr-only`.
govern::autonomy() {
  case "${GOVERN_AUTONOMY:-}" in
    observe|pr-only|auto) printf '%s' "$GOVERN_AUTONOMY" ;;
    *) printf 'auto' ;;
  esac
}
# 0 (true) iff the governor may auto-merge in the current mode (auto only).
govern::automerge_enabled() { [[ "$(govern::autonomy)" == "auto" ]]; }
# 0 (true) iff workers should open PRs as DRAFTS (observe mode only).
govern::pr_draft() { [[ "$(govern::autonomy)" == "observe" ]]; }
# Local-first repo (no deployed prod DB → additive migrations self-apply as shipped code). Opt-in via
# GOVERN_LOCAL_FIRST_REPOS in workspace.sh; a workspace.sh that predates the knob (or doesn't define
# the helper) is treated as "no local-first repos", so the branch is a pure no-op there.
govern::is_local_first_repo() { command -v wsp_is_local_first_repo >/dev/null 2>&1 && wsp_is_local_first_repo "$1"; }

# owner/repo slug + local checkout dir for a short repo name (both delegate to
# workspace.sh, where any cross-owner / out-of-tree overrides live). Default slug
# is "$GITHUB_ORG/<repo>"; default localdir is "$WS_ROOT/<repo>". merge-pr.sh uses
# these so a repo on a different owner / checked out elsewhere still merges + has
# its lingering local ticket-<N> branch cleaned up.
govern::repo_slug()     { wsp_repo_slug "$1"; }
govern::repo_localdir() { wsp_repo_localdir "$1"; }

# ── auto-merge safety guard (external-PR protection) ────────────────────────
# Three independent, FAIL-CLOSED checks the auto-merge path (merge-pr.sh + every other `gh pr merge`
# caller) MUST pass before the `gh pr merge` is even attempted. Rationale: once the workspace's sub-
# repos go public, an external contributor's PR — or a compromised branch push that happens to be
# green — must NEVER be auto-merged, regardless of CI. Human merges via gh/web are unaffected: this
# guard sits ONLY in the governor's auto-merge path.
#   1. **PR author == workspace gh login** — the PR was opened by the authenticated `gh api user`
#      (the workspace owner / governor bot). Different login → block (`external-author`).
#   2. **Head repo == base repo** — the PR is NOT from a fork. Same login on a fork clone is not
#      enough; a fork PR is unconditionally rejected (`fork-pr`).
#   3. **Head branch matches governor pattern** — the branch was named by the governor's own worker
#      (`ticket-<N>` on a private repo, or the neutral `sl-<hex>` scheme on a PUBLIC repo — see
#      govern::neutral_branch) or the sync-port lane (`sync-auto-*`). Extend GOVERN_MERGE_BRANCH_RE if
#      you add another governor-owned naming scheme. Mismatch → `bad-branch`.
# Any gh/jq/lookup error is treated as a block (`lookup-failed`) — a transient GitHub outage NEVER
# degrades into a blind merge.
GOVERN_MERGE_BRANCH_RE="${GOVERN_MERGE_BRANCH_RE:-^(ticket-[0-9]+|sync-auto-.*)$}"
# Public-repo variant: the SAME governor-owned patterns PLUS the neutral `sl-<hex>` scheme a worker
# uses on a public repo (so no internal ticket-id leaks in the branch name). Applied by the guard
# ONLY when the target repo resolves PUBLIC (govern::repo_is_public); a private repo keeps
# GOVERN_MERGE_BRANCH_RE unchanged, so this NEVER weakens the private-repo guard. `ticket-<N>` is
# still accepted on public repos too, so an in-flight PR opened before a repo went public still merges.
# NB: assigned via a conditional (not `${VAR:-default}`) because the `{12}` quantifier's `}` would
# otherwise terminate the parameter-expansion default early and mangle the regex.
[[ -n "${GOVERN_MERGE_BRANCH_RE_PUBLIC:-}" ]] || GOVERN_MERGE_BRANCH_RE_PUBLIC='^(sl-[0-9a-f]{12}|ticket-[0-9]+|sync-auto-.*)$'

# ── public-repo neutral branch scheme ───────────────────────────────────────
# On a PUBLIC repo the governor must not expose an internal ticket id anywhere an outsider can see it
# — `ticket-42` implies a private tracker. So a worker on a public repo names its branch with an
# OPAQUE, DETERMINISTIC token instead: `sl-<12 hex>` where the hex is derived from the ticket number.
# Deterministic ⇒ the governor recovers the branch for ticket N by recomputing it (no extra state);
# opaque ⇒ an outsider cannot read N off the branch. git-hash-object is used purely as a portable,
# always-present (git is a hard dep) hash — NOT for any git object; the salt keeps it from colliding
# with a bare sha of the number. 12 hex = 48 bits, so cross-ticket collisions are negligible.
govern::neutral_branch() { # <N> -> stdout: sl-<12hex>
  local n="$1" h
  h="$(printf 'shiploop-neutral-branch:%s' "$n" | git hash-object --stdin 2>/dev/null | cut -c1-12)"
  [[ "$h" =~ ^[0-9a-f]{12}$ ]] || { printf 'ticket-%s' "$n"; return 1; }  # hash unavailable → safe fallback
  printf 'sl-%s' "$h"
}

# Per-run, per-repo visibility. `GOVERN_PUBLIC_REPOS` (space-separated SHORT names) is the deterministic
# override and WINS over detection; when a repo isn't listed there, auto-detect via `gh repo view`.
# Result cached in a run-scoped file so a 100-PR pass calls `gh repo view` at most once per repo.
# FAIL-SAFE: any gh failure / unrecognized value ⇒ treated as PRIVATE (rc 1) = current behavior, so an
# API hiccup never flips a repo's branch mechanics; it only risks NOT scrubbing a leak (cosmetic), which
# the unconditional title/body scrub backstops anyway. Logged once per repo on the unknown path.
_GOVERN_VIS_CACHE="${GOVERN_VIS_CACHE:-${GOVERN_RUN_DIR:-$GOVERNOR_DIR}/.repo-visibility}"
govern::repo_is_public() { # <repo-short-name> -> rc 0 public, 1 private/internal/unknown
  local repo="$1" r v slug raw
  [[ -n "$repo" ]] || return 1
  for r in ${GOVERN_PUBLIC_REPOS:-}; do [[ "$r" == "$repo" ]] && return 0; done
  if [[ -f "$_GOVERN_VIS_CACHE" ]]; then
    v="$(awk -v k="$repo" '$1==k{print $2; exit}' "$_GOVERN_VIS_CACHE" 2>/dev/null || true)"
  fi
  if [[ -z "${v:-}" ]]; then
    command -v gh >/dev/null 2>&1 || return 1
    slug="$(govern::repo_slug "$repo" 2>/dev/null || true)"
    [[ -n "$slug" ]] || return 1
    raw="$(gh repo view "$slug" --json visibility -q .visibility 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)"
    case "$raw" in
      public|private|internal) v="$raw" ;;
      *) v="unknown"; govern::log "repo-visibility lookup for '$repo' failed (gh) — treating as PRIVATE (current behavior); set GOVERN_PUBLIC_REPOS to override" ;;
    esac
    mkdir -p "$(dirname "$_GOVERN_VIS_CACHE")" 2>/dev/null || true
    printf '%s %s\n' "$repo" "$v" >> "$_GOVERN_VIS_CACHE" 2>/dev/null || true
  fi
  [[ "$v" == "public" ]]
}

# The branch name a worker should use for ticket N on a given repo: neutral `sl-<hex>` on a PUBLIC
# repo, the classic `ticket-<N>` on a private repo. Used to (a) instruct the worker and (b) recover
# the expected head for PR discovery.
govern::ticket_branch() { # <N> <repo> -> stdout: branch name
  local n="$1" repo="$2"
  if govern::repo_is_public "$repo"; then govern::neutral_branch "$n"; else printf 'ticket-%s' "$n"; fi
}

# Workspace gh-login cache. Resolved lazily on first call and reused for the rest of the run so a
# 100-PR pass doesn't hit `gh api user` 100 times. A test can pre-seed _GOVERN_OWN_LOGIN=acme to skip
# the round-trip entirely (kept underscore-prefixed to signal "test seam", NOT a public knob).
govern::_own_login() { # -> stdout: login (empty on error). rc 0 on success, 1 on lookup failure.
  if [[ -n "${_GOVERN_OWN_LOGIN:-}" ]]; then printf '%s' "$_GOVERN_OWN_LOGIN"; return 0; fi
  command -v gh >/dev/null 2>&1 || return 1
  local u; u="$(gh api user --jq .login 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$u" ]] || return 1
  _GOVERN_OWN_LOGIN="$u"
  printf '%s' "$u"
}

# THE guard. Print block reason to stdout on failure (empty on allow). Return 0 = allow, 1 = block.
# Called by every auto-merge site (merge-pr.sh today; grep `pr_automerge_allowed` if you add another).
# Test seam: _GOVERN_ASSUME_MERGE_ALLOWED=1 short-circuits the guard to "allow" — used by tests that
# aren't exercising the guard itself so their existing gh stubs don't need new api-user / api-pulls
# handlers. Production code must NEVER set this; it is intentionally an opt-OUT, not opt-in, so a
# forgetful downstream test can only be MORE strict, not less.
govern::pr_automerge_allowed() { # <repo> <pr> -> [reason on stdout on block]; rc 0 allow, 1 block
  local repo="$1" pr="$2" slug j own author head base_owner head_owner
  [[ "${_GOVERN_ASSUME_MERGE_ALLOWED:-0}" == "1" ]] && return 0
  command -v gh >/dev/null 2>&1 || { printf 'lookup-failed'; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'lookup-failed'; return 1; }
  slug="$(govern::repo_slug "$repo" 2>/dev/null || true)"
  [[ -n "$slug" ]] || { printf 'lookup-failed'; return 1; }
  own="$(govern::_own_login 2>/dev/null || true)"
  [[ -n "$own" ]] || { printf 'lookup-failed'; return 1; }
  # One REST call for author + head-branch + head/base owners. Defensive: a non-object response (gh
  # error payload, rate-limit body, unstubbed test) MUST fail-closed rather than jq-error under set -e.
  j="$(gh api "repos/$slug/pulls/$pr" 2>/dev/null || true)"
  printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1 || { printf 'lookup-failed'; return 1; }
  author="$(printf '%s' "$j" | jq -r '.user.login // ""' 2>/dev/null || true)"
  head="$(printf '%s' "$j" | jq -r '.head.ref // ""' 2>/dev/null || true)"
  base_owner="$(printf '%s' "$j" | jq -r '.base.repo.owner.login // ""' 2>/dev/null || true)"
  head_owner="$(printf '%s' "$j" | jq -r '.head.repo.owner.login // ""' 2>/dev/null || true)"
  # Any empty field ⇒ the PR object was malformed / partial ⇒ fail-closed. Never merge on ambiguity.
  [[ -n "$author" && -n "$head" && -n "$base_owner" && -n "$head_owner" ]] || { printf 'lookup-failed'; return 1; }
  # Order: author (who opened it) FIRST — the primary invariant. Then fork (defense-in-depth for a
  # spoofed fork owner name). Then branch pattern (final structural check).
  [[ "$author"     == "$own"        ]] || { printf 'external-author'; return 1; }
  [[ "$head_owner" == "$base_owner" ]] || { printf 'fork-pr';         return 1; }
  # Branch pattern: a PUBLIC repo additionally accepts the neutral `sl-<hex>` scheme (no ticket-id in
  # the branch name); a private repo uses the unchanged RE, so this branch never weakens for it.
  local _bre="$GOVERN_MERGE_BRANCH_RE"
  govern::repo_is_public "$repo" && _bre="$GOVERN_MERGE_BRANCH_RE_PUBLIC"
  [[ "$head" =~ $_bre ]] || { printf 'bad-branch';   return 1; }
  return 0
}

# Find an already-open PR for ticket $1. The standard head is "ticket-<N>" (worktree:new), but a
# worker may have named its branch e.g. "fix/ticket-<N>-..." (#55) — so we match an exact
# "ticket-<N>" head FIRST, then fall back to ANY open-PR head CONTAINING "ticket-<N>" at a digit
# boundary (so "ticket-12" never matches "ticket-120"). Prints "repo number url" if found — lets a
# re-run resume instead of opening a duplicate PR, AND lets a same-run worker that opened a PR but
# returned a bad report still be adopted as resolved instead of recorded "failed".
govern::find_pr() {
  local n="$1" repo j row nb
  command -v gh >/dev/null 2>&1 || return 1
  # A public repo's head is the neutral `sl-<hex>` (deterministic from N); recompute it once and match
  # it alongside the classic `ticket-<N>` head so mixed-visibility workspaces resolve either scheme.
  nb="$(govern::neutral_branch "$n" 2>/dev/null || true)"
  # Search the whole merge UNIVERSE (GOVERN_MERGE_REPOS) plus the frontend repos —
  # NOT just $REPOS — so a PR on a cross-owner repo that is in the allowlist but not
  # a sub-repo (e.g. the meta-repo itself / a skill-template repo) is still found.
  # repo_slug resolves each name to its owner/repo (honoring cross-owner overrides).
  for repo in $GOVERN_MERGE_REPOS $GOVERN_FRONTEND_REPOS; do
    j="$(gh pr list --repo "$(govern::repo_slug "$repo")" --state open --json number,url,headRefName 2>/dev/null || echo '[]')"
    row="$(jq -c --arg n "$n" --arg nb "$nb" '
      ( [ .[] | select(.headRefName == ("ticket-" + $n)) ][0] )
      // ( [ .[] | select($nb != "" and .headRefName == $nb) ][0] )
      // ( [ .[] | select(.headRefName | test("(^|[^0-9])ticket-" + $n + "([^0-9]|$)")) ][0] )
      // empty' <<<"$j" 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      printf '%s %s %s\n' "$repo" "$(jq -r '.number' <<<"$row")" "$(jq -r '.url // ""' <<<"$row")"
      return 0
    fi
  done
  # the sub-repo allowlist above never includes the meta-repo/harness remote itself, so a
  # HARNESS-scope ticket's PR (pushed to the meta-repo's own origin, or to
  # GOVERN_UPSTREAM_HARNESS_REPO) was invisible here — this feeds BOTH the pre-spawn resume check
  # (run-loop.sh's "found existing PR — resuming") and the #55 same-run adoption safety net, so a
  # crashed-and-resumed (or malformed-report) harness worker got silently re-spawned or recorded
  # failed despite a clean, already-open PR. Fall back to the harness slug(s) directly.
  local slug
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    j="$(gh pr list --repo "$slug" --state open --json number,url,headRefName 2>/dev/null || echo '[]')"
    row="$(jq -c --arg n "$n" --arg nb "$nb" '
      ( [ .[] | select(.headRefName == ("ticket-" + $n)) ][0] )
      // ( [ .[] | select($nb != "" and .headRefName == $nb) ][0] )
      // ( [ .[] | select(.headRefName | test("(^|[^0-9])ticket-" + $n + "([^0-9]|$)")) ][0] )
      // empty' <<<"$j" 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      printf '%s %s %s\n' "${slug##*/}" "$(jq -r '.number' <<<"$row")" "$(jq -r '.url // ""' <<<"$row")"
      return 0
    fi
  done < <(govern::harness_repo_slugs 2>/dev/null)
  return 1
}

# Merge-first repo order (auto-merge repos before frontend), so a multi-repo ticket's live backend
# always merges before any frontend sibling (anti-pattern #5-safe). Emits the full merge UNIVERSE
# (GOVERN_MERGE_REPOS — may include cross-owner repos outside $REPOS) then the derived frontend repos.
govern::_repos_merge_first() {
  local r
  for r in $GOVERN_MERGE_REPOS $GOVERN_FRONTEND_REPOS; do printf '%s\n' "$r"; done
}

# #129: like find_pr, but enumerate EVERY open PR whose head matches ticket-<N> across ALL repos
# (merge + frontend) — not just the first. A worker for a multi-repo ticket may open N PRs; find_pr
# returned only the first repo's, so the siblings were orphaned unmerged. Prints one
# "repo<TAB>number<TAB>url" line per matching open PR, in merge-then-frontend order (backend-first,
# anti-pattern #5-safe). Empty if none.
govern::find_all_prs() {
  local n="$1" repo j rows nb
  command -v gh >/dev/null 2>&1 || return 0
  nb="$(govern::neutral_branch "$n" 2>/dev/null || true)"
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    j="$(gh pr list --repo "$(govern::repo_slug "$repo")" --state open --json number,url,headRefName 2>/dev/null || echo '[]')"
    rows="$(jq -r --arg n "$n" --arg nb "$nb" --arg repo "$repo" '
      [ .[] | select(.headRefName == ("ticket-" + $n) or ($nb != "" and .headRefName == $nb) or (.headRefName | test("(^|[^0-9])ticket-" + $n + "([^0-9]|$)"))) ]
      | .[] | "\($repo)\t\(.number)\t\(.url // "")"' <<<"$j" 2>/dev/null || true)"
    [[ -n "$rows" ]] && printf '%s\n' "$rows"
  done < <(govern::_repos_merge_first)
}

# #129: the FULL, deduped, backend-first PR set for ticket $1 — the worker-reported PR(s) in the
# report JSON $2 (the single `.pr` PLUS the multi-PR `.prs[]` array) UNION every open ticket-<N>
# head discovered across all repos. Deduped by repo#number (first occurrence wins, preserving its
# url) and emitted in merge-then-frontend order so the live backend always merges before any
# frontend sibling (anti-pattern #5). Prints "repo<TAB>number<TAB>url" lines; empty if the ticket
# has no PR at all.
govern::collect_ticket_prs() {
  local n="$1" report="$2" reported discovered all repo
  reported="$(printf '%s' "$report" | jq -r '
    ([ .pr ] + (.prs // []))
    | map(select(. != null and ((.repo // "") != "") and ((.number // "") | tostring | length > 0)))
    | .[] | "\(.repo)\t\(.number)\t\(.url // "")"' 2>/dev/null || true)"
  discovered="$(govern::find_all_prs "$n" 2>/dev/null || true)"
  all="$(printf '%s\n%s\n' "$reported" "$discovered" | awk -F'\t' 'NF>=2 && !seen[$1"#"$2]++')"
  [[ -n "$all" ]] || return 0
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    printf '%s\n' "$all" | awk -F'\t' -v r="$repo" '$1==r'
  done < <(govern::_repos_merge_first)
  # the merge-first walk above only knows the configured sub-repo allowlist
  # (REPOS/GOVERN_MERGE_REPOS/GOVERN_FRONTEND_REPOS), so a HARNESS-scope ticket's reported PR — repo
  # is the meta-repo's own remote, never a member of that allowlist — was silently dropped from the
  # "FULL" set this function promises, even though it was sitting right there in `all`. That silent
  # drop is what let a clean worker resolve (status:"resolved", a real open harness PR) fall through
  # with no PR recognized downstream. Re-scan `all` for any row matching a known harness slug and
  # emit it too, re-verified still-open via `gh pr view` (harness rows skip the normal
  # find_all_prs/gh-list re-confirmation `discovered` gets, so verify them here instead of trusting
  # the worker's JSON blind).
  printf '%s\n' "$all" | while IFS=$'\t' read -r repo num _url; do
    [[ -n "$repo" ]] || continue
    govern::is_harness_repo "$repo" && govern::harness_pr_verify "$repo" "$num"
  done || true
  # The loop's own exit status is the last iteration's `is_harness_repo && harness_pr_verify` chain —
  # 1 whenever the ticket's rows include no harness repo (the common case). Under a caller's `set -e`
  # (govern-supervise.sh, run-loop.sh, this file's own test suite) that nonzero would abort the WHOLE
  # calling script right here, before this function's own `return 0` below ever runs — the `|| true`
  # neutralizes the loop's exit status so callers always see a clean 0 from this function regardless
  # of whether a harness row was found.
  return 0
}

# owner/repo slugs recognized as "the harness/meta-repo" — the root repo's OWN git origin
# (the common case: a governor-dispatched HARNESS-scope ticket's PR targets this repo itself) plus
# GOVERN_UPSTREAM_HARNESS_REPO if configured (the /shiploop:push hub — a workspace may route some
# harness work there instead). Neither is ever a member of REPOS/GOVERN_MERGE_REPOS/
# GOVERN_FRONTEND_REPOS, so every lookup keyed off that allowlist is blind to both.
govern::harness_repo_slugs() { # -> owner/repo lines
  local root rslug
  root="$(govern::meta_root 2>/dev/null || true)"
  if [[ -n "$root" ]] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    rslug="$(git -C "$root" remote get-url origin 2>/dev/null \
      | sed -E 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?$#\2#')"
    [[ -n "$rslug" && "$rslug" == */* ]] && printf '%s\n' "$rslug"
  fi
  [[ -n "${GOVERN_UPSTREAM_HARNESS_REPO:-}" ]] && printf '%s\n' "$GOVERN_UPSTREAM_HARNESS_REPO"
}

# Is short-name/slug $1 a recognized harness/meta-repo target (matches a bare repo name OR a full
# owner/repo slug from govern::harness_repo_slugs)? rc 0 yes, 1 no.
govern::is_harness_repo() { # repo -> 0/1
  local r="$1" slug
  [[ -n "$r" ]] || return 1
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    case "$slug" in "$r"|*"/$r") return 0 ;; esac
  done < <(govern::harness_repo_slugs)
  return 1
}

# Verify a reported PR against a harness/meta-repo slug DIRECTLY via `gh pr view` — bypassing the
# sub-repo-name allowlist scan entirely (that scan is what drops it). Prints
# "repo<TAB>number<TAB>url" and returns 0 only if $1 matches a known harness slug AND gh confirms the
# PR is still OPEN there; returns 1 (prints nothing) otherwise.
govern::harness_pr_verify() { # repo number -> "repo\tnumber\turl"
  local repo="$1" num="$2" slug matched="" state url
  command -v gh >/dev/null 2>&1 || return 1
  [[ -n "$repo" && -n "$num" ]] || return 1
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    case "$slug" in "$repo"|*"/$repo") matched="$slug"; break ;; esac
  done < <(govern::harness_repo_slugs)
  [[ -n "$matched" ]] || return 1
  state="$(gh pr view "$num" --repo "$matched" --json state -q '.state' 2>/dev/null || true)"
  [[ "$state" == "OPEN" ]] || return 1
  url="$(gh pr view "$num" --repo "$matched" --json url -q '.url' 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$repo" "$num" "$url"
}

# ── cross-run wait-for-merge / dependency deferrals (#119) ───────────────────
# skipThisRun (#57) defers a ticket for the CURRENT run only (in-memory excludes), so a supervisor
# "defer #N until PR #M merges" advisory vanished at run-end and the selector re-picked the blocked
# ticket next run (re-deriving — or failing to re-derive — the same conflict). These helpers persist
# such waits to governor/pending-waits.json and re-evaluate them at every run-start, so the deferral
# SURVIVES across runs and auto-clears only once the blocker actually lands.

# Remove value $2 from a comma-list $1; print the cleaned list (no surrounding commas, "" if empty).
govern::csv_remove() { # list value -> cleaned-list
  local list=",${1}," v="$2"; list="${list//,$v,/,}"; list="${list#,}"; list="${list%,}"; printf '%s' "$list"
}

# Print a PR's state — OPEN | MERGED | CLOSED — or "" when it can't be verified (no gh, offline,
# unknown PR/repo). The caller treats "" as "still blocking" (fail-CLOSED) so a transient network
# blip never silently evaporates a persisted wait — the whole point of #119.
govern::pr_state() { # repo pr -> STATE|""
  local repo="$1" pr="$2"
  command -v gh >/dev/null 2>&1 || return 0
  gh pr view "$pr" --repo "$(govern::repo_slug "$repo")" --json state -q .state 2>/dev/null || true
}

# NOTE (#116) — if you ever need to RETARGET an open PR's base branch here (e.g. a dependency-reorder
# in select-ticket.sh, or a base reconciliation after preflight-main.sh moves origin/main under an
# in-flight PR), do NOT use `gh pr edit --base`. On these repos it resolves the PR through gh's GraphQL
# `projectCards` query, which now hard-fails with `GraphQL: Projects (classic) is being deprecated …
# (repository.pullRequest.projectCards)` and leaves the base UNCHANGED — silently, since the rest of
# the edit still succeeds. Use the REST endpoint, which takes no projectCards and applies reliably:
#     gh api -X PATCH "repos/$(govern::repo_slug "$repo")/pulls/$pr" -f "base=$new_base"
# (A `govern::retarget_pr_base` helper implementing exactly this was removed 2026-07-06 as unused dead
# code — no caller ever needed it; re-add it with a stub test the day a real caller does.)

# Dependency numbers a ticket DECLARES via a body line like `**Depends on:** #K` (or `Depends on: #K,
# #J`), PLUS implicit deps declared FROM THE OTHER SIDE: any OTHER ticket whose body carries a
# `**Blocks:** #N, #M` line naming this ticket is treated as an implicit blocker (#N "blocks" this
# ticket ⇒ this ticket "depends on" #N). This lets a single blocker declare the edge once instead of
# every dependent having to add its own `**Depends on:**` marker (#309). Prints one bare number per
# dep (deduped order-preserving). The `**Depends on:**` scan reads #N's block only — bounded by the
# next `## #` heading — so a later ticket's declared deps never leak in; the `**Blocks:**` scan reads
# every OTHER block (that's the point) but only emits a blocker when its Blocks line names #N exactly
# (numeric compare, so #12 never matches #1). Reads $2 (def TICKETS_FILE).
govern::ticket_deps() { # N [tickets-file] -> dep numbers, one per line
  local n="$1" f="${2:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  awk -v n="$n" '
    # Track the number of the ticket block currently being scanned, so a **Blocks:** line can be
    # attributed to the blocker ticket that declares it. `cur == n` ⇔ we are inside #N own block.
    match($0, /^##[[:space:]]+#[0-9]+/) {
      cur=substr($0, RSTART, RLENGTH); sub(/^##[[:space:]]+#/, "", cur)
      inblk=(cur==n); next
    }
    # (A) deps #N DECLARES itself: `**Depends on:** #K` inside its own block.
    inblk {
      low=tolower($0)
      if (low ~ /depends[ \t]+on/) {
        s=$0
        while (match(s,/#[0-9]+/)) {
          d=substr(s,RSTART+1,RLENGTH-1); if (!seen[d]++) print d
          s=substr(s,RSTART+RLENGTH)
        }
      }
    }
    # (B) implicit deps from a BLOCKER: another ticket #cur declaring a `**Blocks:** ... #N ...` line.
    # Matched on the BOLD marker (`**Blocks:**` / `**Blocks**`) or a line-leading `Blocks:` — NOT the
    # bare word "blocks", which shows up in prose far more than "depends on" does (e.g. "this blocks
    # the deploy flow") and would falsely link tickets. Only fires when the marker line names #N
    # exactly. `cur != n` skips #N own `**Blocks:**` (that names its dependents, not its blockers);
    # `cur != ""` guards the preamble before the first heading.
    cur != n && cur != "" {
      low=tolower($0)
      if (low ~ /\*\*blocks:?\*\*/ || low ~ /^[[:space:]]*blocks:/) {
        s=$0; names_n=0
        while (match(s,/#[0-9]+/)) {
          if (substr(s,RSTART+1,RLENGTH-1)==n) names_n=1
          s=substr(s,RSTART+RLENGTH)
        }
        if (names_n && !seen[cur]++) print cur
      }
    }
  ' "$f"
}

# Non-blocking lint (#309): a ticket that states a dependency in PROSE ("depends on #N", "blocked by
# #N", "blocks #N") but carries NO canonical bold marker (`**Depends on:**` / `**Blocks:**`) anywhere
# in its block. Such a prose-only edge is invisible to the pre-spawn dependency gate
# (govern::ticket_deps), so the dependent stays freely selectable — the exact #308/#306/#307 miss that
# a supervisor had to flag by hand. Prints one warning line per offending ticket (empty when clean);
# advisory only — the operator canonicalizes to the bold marker; never gates selection. Conservative:
# a block with ANY bold marker is suppressed (a second, differently-targeted prose edge is not
# re-flagged), trading recall for near-zero false positives. Reads $1 (def TICKETS_FILE).
govern::prose_dep_warnings() { # [tickets-file] -> "#N: prose dependency '<phrase>' has no marker" lines
  local f="${1:-$TICKETS_FILE}"
  [[ -f "$f" ]] || return 0
  awk '
    function flush() {
      if (cur != "" && prose != "" && !marker)
        print "#" cur ": prose dependency \x27" prose "\x27 has no **Depends on:**/**Blocks:** marker"
    }
    match($0, /^##[[:space:]]+#[0-9]+/) {
      flush()
      cur=substr($0, RSTART, RLENGTH); sub(/^##[[:space:]]+#/, "", cur)
      prose=""; marker=0; next
    }
    cur != "" {
      low=tolower($0)
      # a canonical bold marker anywhere in the block suppresses the warning for the whole block.
      if (low ~ /\*\*depends on/ || low ~ /\*\*blocks/) { marker=1; next }
      # informal phrase: a dep verb directly followed by whitespace + #N (records the first only).
      if (prose=="" && match(low, /(depends on|blocked by|blocks)[ \t]+#[0-9]+/))
        prose=substr($0, RSTART, RLENGTH)
    }
    END { flush() }
  ' "$f"
}

# Add/merge ONE wait entry (a JSON object carrying at least `.ticket`; optional `.pr`+`.repo` and/or
# `.dependsOn`) into pending-waits.json, de-duped by ticket number (newest wins). Creates the file if
# absent. No-op without jq / a ticket field. Live-only side effect — callers gate on MODE.
govern::waits_add() { # entry-json
  local entry="$1" f="$PENDING_WAITS_FILE" t cur tmp
  command -v jq >/dev/null 2>&1 || return 0
  t="$(jq -r '.ticket // empty' <<<"$entry" 2>/dev/null || true)"
  [[ "$t" =~ ^[0-9]+$ ]] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  cur="$([[ -s "$f" ]] && cat "$f" || echo '{"waits":[]}')"
  # tmp+mv (never `> $f` directly): the redirect truncates $f BEFORE jq runs, so a jq failure
  # (corrupt pre-existing JSON, disk full) would EMPTY pending-waits.json and evaporate every
  # deferral. Matches the na_skip_bump / waits_remove pattern.
  tmp="$f.tmp.$$"
  if printf '%s' "$cur" | jq -c --argjson e "$entry" --argjson t "$t" \
       '{waits: (((.waits // []) | map(select(.ticket != $t))) + [$e])}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Drop the wait entry for ticket $1 from pending-waits.json (no-op if absent). Used when a blocker
# lands mid-run (an attemptNext for a wait-deferred ticket).
govern::waits_remove() { # ticket
  local t="$1" f="$PENDING_WAITS_FILE" tmp
  [[ -s "$f" ]] && command -v jq >/dev/null 2>&1 || return 0
  tmp="$f.tmp.$$"
  jq -c --argjson t "$t" '{waits: ((.waits // []) | map(select(.ticket != $t)))}' "$f" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" || rm -f "$tmp" 2>/dev/null || true
}

# Re-check every entry in pending-waits.json against its blocker; REWRITE the file keeping only the
# still-blocking entries, and print "ticket<TAB>why" for each so the run-loop can exclude + log it.
# An entry blocks while: its PR is still OPEN (or its state can't be verified — fail-closed), OR its
# `.dependsOn` ticket is still in tickets.md. It CLEARS (entry dropped, ticket selectable again) when:
# the PR merged/closed, the dep resolved, or the waiting ticket itself is gone from tickets.md.
govern::waits_refresh() { # -> "ticket\twhy" lines (for still-blocked); rewrites pending-waits.json
  local f="$PENDING_WAITS_FILE"
  [[ -s "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local kept="[]" line t pr repo dep why blocking state
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    t="$(jq -r '.ticket // empty' <<<"$line" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] || continue
    # The waiting ticket itself was resolved/closed → its wait is moot; drop it.
    if ! grep -qE "^## #$t([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null; then
      govern::log "wait #$t — ticket no longer in tickets.md; clearing wait (#119)"; continue
    fi
    # #191: a wait must NEVER hold back a ticket whose OWN open PR is in an auto-merge repo. Such a PR
    # is the governor's to DRIVE TO MERGE (resume → merge; on conflict → rebase-resolve → merge), not
    # an external PR to "wait on" — the #119 defer is for PRs a human / another lane lands (frontend,
    # or a true cross-ticket dependency the ticket has no PR for). Conflating the two left the 2nd of
    # two interdependent un-parked tickets permanently deferred while its blocker was green+MERGEABLE,
    # needing a manual merge. If #t has its OWN open PR (head ticket-$t) in an auto-merge repo, drop
    # the wait so the selector resumes + merges it. Frontend own-PRs (is_merge_repo false) and
    # dependency waits where #t has no own PR fall through to the normal block logic below.
    local own o_repo o_pr _o_url
    own="$(govern::find_pr "$t" 2>/dev/null || true)"
    if [[ -n "$own" ]]; then
      read -r o_repo o_pr _o_url <<<"$own"
      if govern::is_merge_repo "$o_repo"; then
        govern::log "wait #$t — ticket owns open $o_repo PR #$o_pr in an auto-merge repo; governor will resume+merge it (not defer); clearing wait (#191)"
        continue
      fi
    fi
    pr="$(jq -r '.pr // empty' <<<"$line" 2>/dev/null || true)"
    repo="$(jq -r '.repo // "harness"' <<<"$line" 2>/dev/null || echo harness)"
    dep="$(jq -r '.dependsOn // empty' <<<"$line" 2>/dev/null || true)"
    why=""; blocking=0
    if [[ "$pr" =~ ^[0-9]+$ ]]; then
      state="$(govern::pr_state "$repo" "$pr")"
      case "$state" in
        OPEN)          blocking=1; why="waiting on $repo PR #$pr (still open)";;
        MERGED|CLOSED) govern::log "wait #$t — $repo PR #$pr is $state; clearing wait (#119)";;
        *)             blocking=1; why="waiting on $repo PR #$pr (state unverifiable — keeping wait)";;
      esac
    fi
    if [[ "$blocking" -eq 0 && "$dep" =~ ^[0-9]+$ ]]; then
      if grep -qE "^## #$dep([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null; then
        blocking=1; why="depends on #$dep (still open)"
      else
        govern::log "wait #$t — dependency #$dep resolved; clearing wait (#119)"
      fi
    fi
    if [[ "$blocking" -eq 1 ]]; then
      kept="$(jq -c --argjson e "$line" '. + [$e]' <<<"$kept" 2>/dev/null || echo "$kept")"
      printf '%s\t%s\n' "$t" "$why"
    fi
  done < <(jq -c '.waits[]?' "$f" 2>/dev/null)
  jq -n --argjson w "$kept" '{waits:$w}' > "$f" 2>/dev/null || true
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
  rel="$(govern::tickets_relpath)"
  content="$(git -C "$d" show "origin/main:$rel" 2>/dev/null)" || return 0
  printf '%s\n' "$content" | grep -qE "^##[[:space:]]+#$n([^0-9]|\$)" && return 0
  return 1
}

# ── autostash-pop-safe `pull --rebase` for the shared main checkout (#377) ──────────────────────
# Three call sites run `git -c rebase.autoStash=true pull --rebase origin main` in the SHARED main
# checkout: govern-bookkeep.sh's pre-edit origin sync (step 0) and its push-CAS retry loop (step 4),
# plus commit_meta_to_main's push loop. #370 added autostash so a co-tenant Claude session's UNRELATED
# dirty tracked files (e.g. .claude/context/** WIP) never block the rebase. That handles a
# NON-overlapping dirty tree. But when origin/main advances a file the co-tenant is CONCURRENTLY
# editing (SAME file+region — e.g. a merged spawn-worker.sh change vs the flows-feature WIP), the
# rebase itself succeeds (it only replays OUR append-only meta diffs) yet the autostash POP hits a real
# content conflict. Critically, git reports that pop conflict as a mere WARNING and STILL EXITS 0
# ("Applying autostash resulted in conflicts. Your changes are safe in the stash … Successfully
# rebased and updated refs/heads/main." — verified git 2.50), while leaving the SHARED index with
# UNMERGED entries and the autostash PRESERVED. So the old `pull --rebase … || { rebase --abort; }`
# fallback NEVER fires (rc 0) and `rebase --abort` would be a no-op anyway (the rebase already
# completed; the pop is a separate step). Every later `git add`/`git commit`/`git pull` in the shared
# checkout then fails "you have unmerged files" → the checkout is WEDGED (#377, incident 2026-07-17:
# a merge collided with co-tenant flows WIP → several tickets false-FAILED and got parked).
#
# This wrapper runs that exact command but NEVER leaves the shared checkout wedged, distinguishing:
#   • fast-forward / clean rebase / clean autostash pop  → return 0 (fully synced)
#   • GENUINE rebase CONTENT conflict on a meta file (rc  → rebase left in progress; abort (restores
#     ≠0, both sides edited tickets.md/escalations.md)      the autostash), return 1 — caller logs
#                                                            reconcile-manually, exactly as before
#   • conflicted autostash POP (rc 0, unmerged index, a   → the rebase SUCCEEDED, so local main IS
#     freshly-preserved stash)                              already on origin/main; only the pop wedged
#                                                            the tree. Reset tracked files to the
#                                                            post-rebase HEAD and leave the co-tenant
#                                                            WIP UNTOUCHED in the preserved stash for
#                                                            THEM to reconcile (we never hand-merge
#                                                            someone else's code), warn, return 0.
# The `reset --hard HEAD` is provably non-destructive here: it runs ONLY after confirming a NEW stash
# entry holds the co-tenant delta (autostash never stashes untracked files, which reset --hard also
# never removes). If that stash is somehow absent, it does NOT reset — it fails closed (return 1) so
# un-stashed work is never discarded. Never force-pushes. Call from anywhere (uses `git -C`).
govern::pull_rebase_autostash() { # <repo-dir> -> 0 synced/recovered | 1 genuine-conflict-or-unsafe
  local d="$1" pre_stash post_stash unmerged
  pre_stash="$(git -C "$d" rev-parse -q --verify refs/stash 2>/dev/null || true)"
  if ! git -C "$d" -c rebase.autoStash=true pull --rebase origin main >/dev/null 2>&1; then
    # rc ≠ 0 → the rebase itself failed (genuine content conflict, left in progress). Fail closed
    # exactly like the pre-#377 fallback: abort (this also restores the autostash) and signal caller.
    git -C "$d" rebase --abort >/dev/null 2>&1 || true
    return 1
  fi
  # rc 0. The rebase completed — but a conflicted autostash pop is only a warning (still rc 0), so
  # inspect the index directly. No unmerged entries → clean pop (or nothing was stashed) → synced.
  unmerged="$(git -C "$d" ls-files --unmerged 2>/dev/null | head -1)"
  [[ -z "$unmerged" ]] && return 0
  # Unmerged after a SUCCESSFUL rebase ⟹ the autostash pop conflicted. Confirm a freshly-preserved
  # stash holds the co-tenant delta before touching the tree — only then is the reset non-destructive.
  post_stash="$(git -C "$d" rev-parse -q --verify refs/stash 2>/dev/null || true)"
  if [[ -n "$post_stash" && "$post_stash" != "$pre_stash" ]]; then
    git -C "$d" reset -q --hard HEAD >/dev/null 2>&1 || true
    govern::log "pull_rebase_autostash: origin advanced a file a co-tenant is concurrently editing; the autostash pop conflicted. Local main IS synced to origin/main; the co-tenant's uncommitted WIP is preserved in \`git stash\` (top entry) — recover it with 'git stash pop' and resolve the conflict. The governor did NOT touch or merge it (#377)."
    return 0
  fi
  # Unmerged index but no recoverable stash (should be unreachable: an autostash pop is the only way
  # `pull --rebase` yields rc 0 + unmerged, and that always leaves the stash). Do NOT reset --hard —
  # un-stashed work could be lost. Fail closed so the caller logs reconcile-manually.
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
# #370: the retry-loop's `pull --rebase` runs with `-c rebase.autoStash=true` so a co-tenant
# session's unrelated dirty tracked files (e.g. .claude/context/** WIP) never block it — git
# transiently stashes/restores them byte-identically around the rebase. A genuine content conflict
# on $rel itself still fails the rebase (autostash only covers UNRELATED dirty files) and falls
# through to the abort + break, unchanged.
# #377: the rebase is done through govern::pull_rebase_autostash so an OVERLAPPING-same-file autostash
# POP conflict (origin advanced a file a co-tenant is editing) can NEVER wedge the shared index — that
# case is rc 0 but leaves unmerged entries, which the helper detects and recovers (co-tenant WIP parked
# in the preserved stash). A genuine content conflict on $rel still returns 1 → abort + break, unchanged.
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
        govern::pull_rebase_autostash "$d" || break
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

# ── interrupted/mid-stream-drop detection (#34) ─────────────────────────────
# A laptop that sleeps mid-run (e.g. clamshell-on-battery) suspends the worker's process tree and
# drops the network, so the in-flight `claude -p` API stream dies mid-response with "API Error:
# Connection closed mid-response" and the worker exits on its OWN (NOT killed by the timeout
# watchdog). This is NEITHER a ticket fault NOR a persistent infra outage: it is a TRANSIENT drop
# (the laptop woke; the network returned), and the worktree is preserved + resumable. So it gets its
# OWN status — `interrupted` — which run-loop auto-retries ONCE (not halt-the-run like infra, not
# burn-as-failed like a genuine failure). The signature set is deliberately NARROW and DISJOINT from
# GOVERN_INFRA_ERROR_RE (a clean auth/connection-refused outage stays `infra` → halt): it matches
# only the mid-stream connection-drop class that a suspend/resume produces.
GOVERN_INTERRUPTED_ERROR_RE='Connection closed mid-response|Connection closed|Premature close|socket ?hang ?up|stream (disconnected|closed|interrupted)|response closed before|terminated.*mid-response'

# Print a short human signature of a transient mid-stream connection drop if the worker's stream
# ($1 = worker.jsonl) shows one in its final (error) result event or an explicit "API Error:" line;
# print nothing otherwise. Mirror of govern::infra_error_signature; always returns 0.
govern::interrupted_error_signature() { # worker-jsonl -> signature|""
  local jsonl="${1:-}" msg
  [[ -n "$jsonl" && -f "$jsonl" ]] || return 0
  # Authoritative: the LAST result event, only when it ended in an error.
  msg="$(grep '"type":"result"' "$jsonl" 2>/dev/null | tail -1 \
        | jq -r 'select(.is_error==true) | .result // empty' 2>/dev/null || true)"
  if [[ -n "$msg" ]] && printf '%s' "$msg" | grep -qiE "$GOVERN_INTERRUPTED_ERROR_RE"; then
    printf '%s' "$msg" | tr -d '\r' | tr '\n' ' ' | cut -c1-160; return 0
  fi
  # Fallback: the CLI prints "API Error: ..." lines into the stream even without a clean result.
  msg="$(grep -oiE 'API Error:[^"]*' "$jsonl" 2>/dev/null | grep -iE "$GOVERN_INTERRUPTED_ERROR_RE" | tail -1 || true)"
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
