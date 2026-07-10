#!/usr/bin/env bash
# Externalization lane (OPT-IN) — STAGED REVIEW GATE. The governor NEVER auto-publishes a public issue:
# eligible Low-severity tickets are first MOVED into a review queue and held behind ONE operator
# approval. Three modes:
#
#   (default) STAGE   — once per governor run: move each OPEN eligible Low ticket out of tickets.md into
#                       queue/tickets-externalize-review.md, then file/refresh ONE escalation
#                       questionnaire (Kind: externalize-review) listing every staged ticket with
#                       options approve-all | decide-later | move-back:<ids>. Files NO issue.
#   --approve         — file EVERY staged ticket in the review queue as a public GitHub issue on
#                       GOVERN_EXTERNALIZE_REPO, record it in queue/externalized.md, and remove it from
#                       the review queue. Invoked by escalations-apply-answers.sh on the approve-all
#                       disposition (with GOVERN_EXTERNALIZE_NO_COMMIT=1 so its step-5 commit publishes).
#   --move-back <ids> — return the listed tickets from the review queue to tickets.md, each stamped
#                       `**Externalize:** never` so govern::externalize_candidates permanently excludes
#                       them (they never re-stage). Invoked on the move-back disposition. The rest stay
#                       staged and are re-nudged next run.
#
# OFF by default. Enable by setting BOTH GOVERN_EXTERNALIZE_REPO (owner/repo) and
# GOVERN_EXTERNALIZE_SUBREPO (short sub-repo name matched against each ticket's Where line) in
# workspace.sh. Either unset → the lane no-ops cleanly.
#
# Eligibility = govern::externalize_candidates (Severity: Low AND Where → OSS sub-repo, EXCLUDING sibling
# repos whose name merely contains the OSS name as a substring, AND EXCLUDING any ticket carrying
# `**Externalize:** never`). Gated by GOVERN_EXTERNALIZE_LANE (default 1) at the CALL SITE (run-loop.sh)
# and re-checked here (defense in depth).
#
# Honors --dry (or MODE=dry / GOVERN_ECHO=1): logs what WOULD happen, makes NO gh call, NO edit, NO
# commit. Idempotent: a ticket already in externalized.md is never re-filed — if a prior run created the
# issue but didn't land the block delete (partial failure), --approve HEALS by removing the lingering
# block only. The stage lane keeps exactly ONE questionnaire open across runs (dedupe by Kind), so an
# un-answered gate is re-surfaced, never duplicated. Non-fatal by contract: a per-ticket gh failure
# leaves that ticket staged and the script exits non-zero, which the caller swallows so the loop never
# stalls.
#
# OPERATOR REQUIREMENT (#26): for auto-labels to actually apply, the gh account the governor is authed
# as needs ≥ Triage on GOVERN_EXTERNALIZE_REPO. `gh issue create --label …` is a COMPOSITE op — it
# creates the issue, then applies labels via a SEPARATE GraphQL `addLabelsToLabelable` mutation that a
# pull-only account is denied. The create still returns the URL, so the lane no longer infers full
# success from the URL alone: it captures create stderr and, on a label-permission rejection, emits a
# distinct WARN ("filed but labels REJECTED") instead of a silent `filed` success.
#
# Usage: externalize-low-tickets.sh [--dry] [--approve | --move-back "<id ...>"]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

DRY=0
OP="stage"
MOVEBACK_IDS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry)       DRY=1 ;;
    --approve)   OP="approve" ;;
    --move-back) OP="move-back"; MOVEBACK_IDS="${2:-}"; shift ;;
    *) : ;;   # ignore unknown args (forward-compat)
  esac
  shift
done
[[ "${MODE:-}" == "dry" || "${GOVERN_ECHO:-0}" == "1" ]] && DRY=1

# Defense in depth — the caller gates on this too, but never auto-publish if the lane is off.
if [[ "${GOVERN_EXTERNALIZE_LANE:-1}" != "1" ]]; then
  govern::log "externalization lane disabled (GOVERN_EXTERNALIZE_LANE=0) — skipping"
  exit 0
fi

# Default defensively under set -u: a stub workspace.sh (e.g. the mk_ws_stub test helper) may not
# define the GOVERN_EXTERNALIZE_* vars. With no target repo there is nothing to externalize — skip
# cleanly (exit 0). In production the real workspace.sh defaults it.
repo="${GOVERN_EXTERNALIZE_REPO:-}"
if [[ -z "$repo" ]]; then
  govern::log "externalization: no GOVERN_EXTERNALIZE_REPO configured — skipping externalization"
  exit 0
fi

# Only --approve needs gh (to file issues). stage/move-back are pure local queue edits.
if [[ "$OP" == "approve" && "$DRY" -ne 1 ]] && ! command -v gh >/dev/null 2>&1; then
  govern::log "externalization: gh not available — skipping approve"
  exit 0
fi

# ── shared: commit queue edits to main (CAS-with-retry, mirrors govern-bookkeep). A no-op in DRY mode,
# and — when invoked from escalations-apply-answers.sh (GOVERN_EXTERNALIZE_NO_COMMIT=1) — deferred so
# that caller's own step-5 commit publishes the queue edits atomically with the escalation resolution.
commit_queue() { # <commit-subject> <file> [file...]
  local subj="$1"; shift
  [[ "$DRY" -eq 1 ]] && return 0
  [[ "${GOVERN_EXTERNALIZE_NO_COMMIT:-0}" == "1" ]] && return 0
  local commit_dir
  commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"
  [[ -n "$commit_dir" ]] || return 0
  git -C "$commit_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ( cd "$commit_dir"
    git add -- "$@" 2>/dev/null || true
    if ! git diff --cached --quiet -- "$@" 2>/dev/null; then
      git commit -q -m "$subj" -- "$@" || exit 0
      if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
        for _a in 1 2 3 4 5; do
          git push origin HEAD:main >/dev/null 2>&1 && break
          git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
        done
      fi
    fi )
}

# ── shared: ensure the review queue has a header before the first block is appended.
ensure_review_header() {
  [[ -f "$EXTERNALIZE_REVIEW_FILE" ]] && return 0
  printf '# Externalization review queue\n\nLow-severity `%s` tickets STAGED for public GitHub Issues on `%s`, awaiting ONE\noperator approval (escalation Kind: externalize-review). The governor NEVER files an issue from a\nticket until it is approved. approve-all -> all filed; move-back:<ids> -> returned to tickets.md and\nnever externalized; decide-later -> left here, re-nudged next run. Same block format as tickets.md.\n' \
    "${GOVERN_EXTERNALIZE_SUBREPO:-oss}" "$repo" > "$EXTERNALIZE_REVIEW_FILE"
}

# ── labels (used only by --approve). GOVERN_EXTERNALIZE_LABELS, if set, is a manual override applied
# verbatim to every issue. Otherwise AUTO-DECIDE per issue from the repo's EXISTING labels.
MANUAL_LABELS=()
AVAIL_LABELS=""
if [[ -n "${GOVERN_EXTERNALIZE_LABELS:-}" ]]; then
  IFS=',' read -r -a _labels <<< "$GOVERN_EXTERNALIZE_LABELS"
  for _l in "${_labels[@]}"; do
    _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"  # trim
    [[ -n "$_l" ]] && MANUAL_LABELS+=(--label "$_l")
  done
elif [[ "$OP" == "approve" && "$DRY" -ne 1 ]] && command -v gh >/dev/null 2>&1; then
  AVAIL_LABELS="$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
fi

# Exact repo label name matching $1 case-insensitively (gh needs the exact name), or "" if absent.
label_if_exists() { printf '%s\n' "$AVAIL_LABELS" | awk -v w="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'tolower($0)==w{print;exit}'; }

# Auto-decide labels for one issue from its text, intersected with the repo's labels.
auto_labels() { # title body
  local text cat l exact picked=""
  text="$(printf '%s\n%s' "$1" "$2" | tr 'A-Z' 'a-z')"
  case "$text" in
    *documentation*|*"docs:"*|*"doc page"*|*readme*|*cli-reference*) cat="documentation";;
    *" test "*|*tests*|*coverage*|*pytest*|*" qa "*)                 cat="test";;
    *bug*|*incorrect*|*wrong*|*leak*|*throwaway*|*broken*|*regression*|*"doesn't"*|*"does not"*|*fails*) cat="bug";;
    *)                                                               cat="enhancement";;
  esac
  for l in "good first issue" "help wanted" "$cat"; do
    exact="$(label_if_exists "$l")"
    [[ -n "$exact" ]] && picked="${picked}${exact}"$'\n'
  done
  printf '%s' "$picked" | awk 'NF && !seen[$0]++'
}

# Has ticket #N already been externalized? (idempotency guard — survives a partial failure.)
already_externalized() { grep -qE "^- #$1 " "$EXTERNALIZED_FILE" 2>/dev/null; }

append_ledger() { # N title url
  if [[ ! -f "$EXTERNALIZED_FILE" ]]; then
    printf '# Externalized tickets\n\nLow-severity `%s` tickets filed as public GitHub Issues by the governor\nexternalization lane (`scripts/govern/externalize-low-tickets.sh`). Local cross-walk only — the\npublic issue carries no internal ticket number. Append-only; doubles as the idempotency ledger.\n\n' \
      "$repo" > "$EXTERNALIZED_FILE"
  fi
  printf -- '- #%s — %s — %s (%s)\n' "$1" "$2" "$3" "$(date +%F)" >> "$EXTERNALIZED_FILE"
}

# Does text carry an internal harness cross-reference that doesn't translate to a public repo — a
# foreign ticket number (#N) or a commit hash? Such a ticket leaks private context an OSS contributor
# can't act on, so the lane SKIPS it (a human must sanitize it first) rather than publish confusion.
has_internal_refs() { # text -> 0 if it contains a foreign #N or a commit hash
  printf '%s' "$1" | grep -qE '#[0-9]+|commit `?[0-9a-f]{7}|`[0-9a-f]{7,40}`'
}

# All `## #N` ticket numbers currently in a file, one per line.
block_ids() { grep -oE '^## #[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+'; }

# ════════════════════════════════════════════════════════════════════════════
# STAGE — move eligible candidates into the review queue, then file/refresh the ONE questionnaire.
# ════════════════════════════════════════════════════════════════════════════
do_stage() {
  local cands=() N moved=0 block
  while IFS= read -r N; do [[ -n "$N" ]] && cands+=("$N"); done < <(govern::externalize_candidates "$TICKETS_FILE")

  for N in "${cands[@]+"${cands[@]}"}"; do
    grep -qE "^## #$N([^0-9]|\$)" "$TICKETS_FILE" || continue
    if [[ "$DRY" -eq 1 ]]; then
      govern::log "[dry] would STAGE #$N -> $EXTERNALIZE_REVIEW_FILE (out of tickets.md)"
      moved=$((moved+1)); continue
    fi
    ensure_review_header
    block="$(govern::ticket_block "$N" "$TICKETS_FILE")"
    [[ -n "$block" ]] || continue
    printf '\n%s\n' "$block" >> "$EXTERNALIZE_REVIEW_FILE"
    govern::ticket_block_delete "$N" "$TICKETS_FILE"
    moved=$((moved+1))
  done
  [[ "$moved" -gt 0 && "$DRY" -ne 1 ]] && \
    commit_queue "chore(govern): stage $moved Low ${GOVERN_EXTERNALIZE_SUBREPO:-oss} ticket(s) for externalization review" "$TICKETS_FILE" "$EXTERNALIZE_REVIEW_FILE"

  # Questionnaire — over the FULL staged set (new + any left from prior runs), not just this run's moves.
  local staged=() sn
  while IFS= read -r sn; do [[ -n "$sn" ]] && staged+=("$sn"); done < <(block_ids "$EXTERNALIZE_REVIEW_FILE")
  if [[ "${#staged[@]}" -eq 0 ]]; then
    govern::log "externalization: nothing staged for review (repo=$repo)"
    return 0
  fi
  # Dedupe: keep exactly ONE open externalize-review questionnaire across runs (identity is the Kind,
  # not a ticket number — one questionnaire spans many staged tickets). An un-answered gate is left as
  # the standing nudge; we never file a second.
  if govern::has_open_escalation_kind externalize-review >/dev/null 2>&1; then
    govern::log "externalization: an externalize-review escalation is already open (${#staged[@]} staged) — not re-filing (dedupe)"
    return 0
  fi
  # Build the ticket list "#N — Title" for the question body.
  local listing anchor h
  anchor="${staged[0]}"
  listing="$(for sn in "${staged[@]}"; do
    h="$(grep -m1 -E "^## #$sn([^0-9]|\$)" "$EXTERNALIZE_REVIEW_FILE" || true)"
    printf '#%s — %s; ' "$sn" "${h#*— }"
  done)"
  if [[ "$DRY" -eq 1 ]]; then
    govern::log "[dry] would file ONE externalize-review escalation listing ${#staged[@]} staged ticket(s): $listing"
    return 0
  fi
  govern::file_open_escalation \
    "$anchor" \
    "Externalization review — ${#staged[@]} Low ${GOVERN_EXTERNALIZE_SUBREPO:-oss} ticket(s) staged for public issues" \
    "The externalization lane staged ${#staged[@]} Low-severity \`${GOVERN_EXTERNALIZE_SUBREPO:-oss}\` ticket(s) into \`queue/tickets-externalize-review.md\`. They are NOT filed as public issues yet — the governor never auto-publishes; it needs ONE approval." \
    "File these as public \`good first issue\` GitHub issues on \`$repo\`? Staged: ${listing%%; }" \
    "approve-all (file ALL staged as public issues) · decide-later (leave staged, re-ask next run) · move-back:<ids> (return the listed tickets to tickets.md and NEVER externalize them; the rest stay staged)" \
    "externalize-review" \
    "operator: approve-all | decide-later | move-back:<ids>"
  govern::log "externalization: filed ONE externalize-review questionnaire (anchor #$anchor) for ${#staged[@]} staged ticket(s)"
}

# ════════════════════════════════════════════════════════════════════════════
# APPROVE — file every staged ticket in the review queue as a public issue, ledger + de-block it.
# ════════════════════════════════════════════════════════════════════════════
do_approve() {
  local ids=() N filed=0 healed=0 skipped=0 failed=0 label_rejected=0
  while IFS= read -r N; do [[ -n "$N" ]] && ids+=("$N"); done < <(block_ids "$EXTERNALIZE_REVIEW_FILE")
  if [[ "${#ids[@]}" -eq 0 ]]; then
    govern::log "externalization approve: review queue empty — nothing to file"
    return 0
  fi
  for N in "${ids[@]}"; do
    local heading title body
    heading="$(grep -m1 -E "^## #$N([^0-9]|\$)" "$EXTERNALIZE_REVIEW_FILE" || true)"
    [[ -n "$heading" ]] || continue
    title="${heading#*— }"
    body="$(awk -v n="$N" '
      $0 ~ ("^## #" n "([^0-9]|$)") { grab=1; next }
      grab && /^---[[:space:]]*$/ { exit }
      grab { print }
    ' "$EXTERNALIZE_REVIEW_FILE" | grep -v '^\*\*Ref:\*\*' | grep -v '^\*\*Externalize:\*\*')"

    # Partial-failure heal: the issue was filed on a prior run but its block never left the queue.
    if already_externalized "$N"; then
      if [[ "$DRY" -eq 1 ]]; then
        govern::log "[dry] approve: #$N already in ledger — would remove its lingering review-queue block (heal)"
      else
        govern::ticket_block_delete "$N" "$EXTERNALIZE_REVIEW_FILE"; healed=$((healed+1))
        govern::log "externalization approve: #$N already filed (in ledger) — removed its lingering staged block (heal)"
      fi
      continue
    fi

    # Leak guard: not self-contained for an outside contributor — leave it staged for a human.
    if has_internal_refs "$title"$'\n'"$body"; then
      govern::log "externalization approve: SKIP #$N \"$title\" — carries internal cross-references (#N / commit hash); sanitize it manually before externalizing (left staged)"
      skipped=$((skipped+1)); continue
    fi

    local ticket_labels=() label_names
    if [[ "${#MANUAL_LABELS[@]}" -gt 0 ]]; then
      ticket_labels=("${MANUAL_LABELS[@]}")
    else
      while IFS= read -r _ln; do [[ -n "$_ln" ]] && ticket_labels+=(--label "$_ln"); done < <(auto_labels "$title" "$body")
    fi
    label_names="$(printf '%s ' "${ticket_labels[@]+"${ticket_labels[@]}"}" | sed 's/--label //g')"

    if [[ "$DRY" -eq 1 ]]; then
      govern::log "[dry] approve: would file #$N \"$title\" -> $repo issue [labels: ${label_names:-none}] + remove its staged block"
      continue
    fi

    local err_file url create_err
    err_file="$(mktemp)"
    url="$(gh issue create --repo "$repo" --title "$title" --body "$body" ${ticket_labels[@]+"${ticket_labels[@]}"} 2>"$err_file")" || true
    create_err="$(cat "$err_file" 2>/dev/null || true)"; rm -f "$err_file"

    if [[ -n "$url" ]]; then
      if [[ "${#ticket_labels[@]}" -gt 0 ]] && govern::label_apply_rejected "$create_err"; then
        govern::log "externalization approve: WARN #$N filed but LABELS REJECTED [${label_names:-none}] -> $url landed UNLABELED. The governor's gh account lacks ≥ Triage on $repo. ACTION: grant Triage/Write. (gh stderr: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))"
        label_rejected=$((label_rejected+1))
      else
        govern::log "externalization approve: filed #$N \"$title\" -> $url [labels: ${label_names:-none}]"
      fi
      append_ledger "$N" "$title" "$url"
      govern::ticket_block_delete "$N" "$EXTERNALIZE_REVIEW_FILE"
      filed=$((filed+1))
    else
      govern::log "externalization approve: gh issue create FAILED for #$N (\"$title\") — left staged${create_err:+ (gh: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))}"
      failed=1
    fi
  done

  [[ $(( filed + healed )) -gt 0 && "$DRY" -ne 1 ]] && \
    commit_queue "chore(govern): externalize $filed approved Low $repo ticket(s) to public issues" "$EXTERNALIZE_REVIEW_FILE" "$EXTERNALIZED_FILE"
  govern::log "externalization approve: filed=$filed (labels-rejected=$label_rejected) healed=$healed skipped=$skipped failed=$failed (repo=$repo, dry=$DRY)"
  [[ "$label_rejected" -gt 0 ]] && govern::log "externalization approve: NOTE $label_rejected issue(s) filed UNLABELED this run — grant the governor's gh account ≥ Triage on $repo so auto-labels stick."
  [[ "$failed" -eq 0 ]] || return 1
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# MOVE-BACK — return listed tickets to tickets.md, each stamped `**Externalize:** never`.
# ════════════════════════════════════════════════════════════════════════════
do_move_back() {
  local ids="$1" N moved=0 block
  [[ -n "$ids" ]] || { govern::log "externalization move-back: no ids given — nothing to do"; return 0; }
  for N in $ids; do
    [[ "$N" =~ ^[0-9]+$ ]] || continue
    grep -qE "^## #$N([^0-9]|\$)" "$EXTERNALIZE_REVIEW_FILE" 2>/dev/null || { govern::log "externalization move-back: #$N not in the review queue — skip"; continue; }
    if [[ "$DRY" -eq 1 ]]; then
      govern::log "[dry] move-back: would return #$N to tickets.md + stamp **Externalize:** never"
      moved=$((moved+1)); continue
    fi
    block="$(govern::ticket_block "$N" "$EXTERNALIZE_REVIEW_FILE")"
    [[ -n "$block" ]] || continue
    # Append to tickets.md with `**Externalize:** never` inserted as the first field after the heading
    # (skip if the block somehow already carries the flag), so externalize_candidates never re-stages it.
    { printf '\n'
      printf '%s\n' "$block" | awk '
        NR==1 { print; next }
        NR==2 && !done && $0 !~ /^\*\*Externalize:\*\*/ { print "**Externalize:** never  <!-- operator move-back: do not externalize -->"; done=1 }
        { print }'
    } >> "$TICKETS_FILE"
    govern::ticket_block_delete "$N" "$EXTERNALIZE_REVIEW_FILE"
    moved=$((moved+1))
    govern::log "externalization move-back: returned #$N to tickets.md (Externalize: never)"
  done
  [[ "$moved" -gt 0 && "$DRY" -ne 1 ]] && \
    commit_queue "chore(govern): move $moved ticket(s) back from externalization review (never-externalize)" "$TICKETS_FILE" "$EXTERNALIZE_REVIEW_FILE"
  govern::log "externalization move-back: returned=$moved ticket(s) (dry=$DRY)"
}

case "$OP" in
  stage)     do_stage ;;
  approve)   do_approve ;;
  move-back) do_move_back "$MOVEBACK_IDS" ;;
esac
