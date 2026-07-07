#!/usr/bin/env bash
# Externalization REVIEW GATE (OPT-IN): the governor NEVER auto-publishes a backlog ticket to a public
# repo. Instead it runs a two-phase, human-gated flow:
#
#   PHASE 1 — STAGE (default; once per governor run). Each OPEN Low-severity ticket that targets the
#     configured OSS sub-repo is MOVED out of the live queue.tickets.md into queue/tickets-externalize-
#     review.md (same block format; the governor never SELECTS work from it), and ONE questionnaire
#     escalation is filed asking the operator what to do with everything staged. Exactly one such
#     questionnaire is open at a time (deduped by its `- **Kind:** externalize-review`), so a run that
#     stages nothing new but still has staged tickets pending just re-nudges — never stacks duplicates.
#
#   PHASE 2 — FILE (`--file-approved`; invoked by escalations-apply-answers.sh when the operator answers
#     the questionnaire `approve-all`). Every block still in the review file is filed as a public GitHub
#     Issue on GOVERN_EXTERNALIZE_REPO, recorded in queue/externalized.md, and removed from the review
#     file. Nothing is ever published without this explicit approval.
#
#   The operator's other two answers are handled in escalations-apply-answers.sh: `move-back:<ids>`
#   restores the listed blocks to tickets.md and stamps each `**Externalize:** never` (so eligibility
#   never re-stages them), and `decide-later` leaves them staged for the next run's re-nudge.
#
# OFF by default. Enable by setting BOTH GOVERN_EXTERNALIZE_REPO (owner/repo) and
# GOVERN_EXTERNALIZE_SUBREPO (short sub-repo name matched against each ticket's Where line) in
# workspace.sh. Either unset → the lane no-ops cleanly.
#
# Eligibility = govern::externalize_candidates (Severity: Low AND Where → OSS sub-repo, EXCLUDING sibling
# repos whose name merely contains the OSS name as a substring, harness-internal, validation/decision,
# and any ticket already stamped `**Externalize:** never`). Gated by GOVERN_EXTERNALIZE_LANE (default 1)
# at the CALL SITE (run-loop.sh) and re-checked here (defense in depth).
#
# Honors --dry (or MODE=dry / GOVERN_ECHO=1): logs what WOULD happen, makes NO gh call, NO edit, NO
# commit — inert in both phases.
#
# OPERATOR REQUIREMENT (#26): for auto-labels to actually apply, the gh account the governor is authed
# as needs ≥ Triage on GOVERN_EXTERNALIZE_REPO. `gh issue create --label …` is a COMPOSITE op — it
# creates the issue, then applies labels via a SEPARATE GraphQL `addLabelsToLabelable` mutation that a
# pull-only account is denied. The create still returns the URL, so the lane no longer infers full
# success from the URL alone: it captures create stderr and, on a label-permission rejection, emits a
# distinct WARN ("filed but labels REJECTED") instead of a silent `filed` success.
#
# Usage: externalize-low-tickets.sh [--dry]                 # PHASE 1: stage + file the questionnaire
#        externalize-low-tickets.sh --file-approved [--dry] # PHASE 2: file every staged block as an issue
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

DRY=0
PHASE=stage
for arg in "$@"; do
  case "$arg" in
    --dry) DRY=1 ;;
    --file-approved) PHASE=file ;;
    *) : ;;
  esac
done
[[ "${MODE:-}" == "dry" || "${GOVERN_ECHO:-0}" == "1" ]] && DRY=1

# Defense in depth — the caller gates on this too, but never auto-publish if the lane is off.
if [[ "${GOVERN_EXTERNALIZE_LANE:-1}" != "1" ]]; then
  govern::log "externalization lane disabled (GOVERN_EXTERNALIZE_LANE=0) — skipping"
  exit 0
fi

# Default defensively under set -u: a stub workspace.sh (e.g. the mk_ws_stub test helper) may not
# define the GOVERN_EXTERNALIZE_* vars. With no target repo there is nothing to file — skip cleanly
# (exit 0) rather than dying on an unbound variable. In production the real workspace.sh defaults it.
repo="${GOVERN_EXTERNALIZE_REPO:-}"
if [[ -z "$repo" ]]; then
  govern::log "externalization: no GOVERN_EXTERNALIZE_REPO configured — skipping externalization"
  exit 0
fi

EXTERNALIZE_KIND="$EXTERNALIZE_REVIEW_KIND"

# ── shared block helpers (operate on an explicit file arg — tickets.md when staging, the review file
#    when filing) ──────────────────────────────────────────────────────────────────────────────────
# Heading line of ticket #N in $2, or "".
block_heading() { grep -m1 -E "^## #$1([^0-9]|\$)" "$2" 2>/dev/null || true; }

# The public issue body for ticket #N read from file $2: the block from the heading's trailing line
# down to (not including) the closing ---, MINUS the **Ref:** line (always internal provenance) and any
# **Externalize:** control field. No internal #N (the heading is reconstructed from the title alone).
block_body() { # N file
  awk -v n="$1" '
    $0 ~ ("^## #" n "([^0-9]|$)") { grab=1; next }
    grab && /^---[[:space:]]*$/ { exit }
    grab { print }
  ' "$2" | grep -vE '^\*\*Ref:\*\*|^\*\*Externalize:\*\*'
}

# Delete ticket #N's block (heading through its trailing ---) from file $2 — the EXACT mechanism
# govern-bookkeep.sh uses (atomic mktemp+mv).
delete_block() { # N file
  local n="$1" f="$2" tmp; tmp="$(mktemp)"
  awk -v n="$n" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" { grab=1 }
    grab && /^---[[:space:]]*$/ { grab=0; next }
    grab { next }
    { print }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

# Ensure the review file exists with a header (created lazily on first stage).
ensure_review_file() {
  [[ -f "$EXTERNALIZE_REVIEW_FILE" ]] && return 0
  mkdir -p "$(dirname "$EXTERNALIZE_REVIEW_FILE")" 2>/dev/null || true
  printf '# Externalize review queue\n\nLow-severity `%s` tickets STAGED by the governor externalization\nreview gate (`scripts/govern/externalize-low-tickets.sh`), awaiting ONE operator approval before any\npublic GitHub Issue is filed. Same block format as tickets.md; the governor never SELECTS work from\nhere. Answer the open `externalize-review` questionnaire in governor/escalations.md to file them\n(`approve-all`), reject them (`move-back:<ids>`), or defer (`decide-later`).\n\n' \
    "$repo" > "$EXTERNALIZE_REVIEW_FILE"
}

# Append ticket #N's WHOLE block (heading → trailing ---) from tickets.md to the review file, then
# delete it from tickets.md — the human-gated equivalent of migrate_to_parked, but the block keeps its
# number and gains no renumber/provenance edits (move-back must restore it verbatim).
stage_block() { # N
  local n="$1" block
  block="$(awk -v n="$n" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" {grab=1}
    grab {print}
    grab && /^---[[:space:]]*$/ {exit}
  ' "$TICKETS_FILE")"
  [[ -n "$block" ]] || return 0
  ensure_review_file
  { printf '\n'; printf '%s\n' "$block"; } >> "$EXTERNALIZE_REVIEW_FILE"
  delete_block "$n" "$TICKETS_FILE"
}

# Ticket numbers currently staged in the review file (one per line).
staged_numbers() { grep -oE '^## #[0-9]+' "$EXTERNALIZE_REVIEW_FILE" 2>/dev/null | grep -oE '[0-9]+' || true; }

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
# can't act on, so the FILE phase SKIPS it (a human must sanitize it first) rather than publish confusion.
has_internal_refs() { # text -> 0 if it contains a foreign #N or a commit hash
  printf '%s' "$1" | grep -qE '#[0-9]+|commit `?[0-9a-f]{7}|`[0-9a-f]{7,40}`'
}

# Commit tickets.md + the review file (the STAGE moves) to main. Coordination files commit directly to
# main (anti-pattern #8); mirrors govern-bookkeep's CAS-with-retry push so a concurrent driver sharing
# origin/main can't resurrect the moved blocks. A pure no-op outside a git repo (tests) or under
# GOVERN_NO_PUSH=1 push-skip.
commit_files() { # subject file...
  local subject="$1"; shift
  local commit_dir; commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"
  [[ -n "$commit_dir" ]] && git -C "$commit_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ( cd "$commit_dir"
    git add -- "$@" 2>/dev/null || true
    if ! git diff --cached --quiet -- "$@" 2>/dev/null; then
      git commit -q -m "$subject" -- "$@" || exit 0
      if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
        for _a in 1 2 3 4 5; do
          git push origin HEAD:main >/dev/null 2>&1 && break
          git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
        done
      fi
    fi )
}

# ── labels (FILE phase only) ────────────────────────────────────────────────────────────────────────
# GOVERN_EXTERNALIZE_LABELS, if set, is a manual override applied verbatim to every issue. Otherwise the
# lane AUTO-DECIDES per issue from the repo's EXISTING labels (contributor signals + one content
# category). Only labels the repo actually has are applied, so `gh` never fails on an unknown label.
setup_labels() {
  MANUAL_LABELS=(); AVAIL_LABELS=""
  if [[ -n "${GOVERN_EXTERNALIZE_LABELS:-}" ]]; then
    local _labels _l
    IFS=',' read -r -a _labels <<< "$GOVERN_EXTERNALIZE_LABELS"
    for _l in "${_labels[@]}"; do
      _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"  # trim
      [[ -n "$_l" ]] && MANUAL_LABELS+=(--label "$_l")
    done
  elif command -v gh >/dev/null 2>&1; then
    AVAIL_LABELS="$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
  fi
}
# Exact repo label name matching $1 case-insensitively (gh needs the exact name), or "" if absent.
label_if_exists() { printf '%s\n' "$AVAIL_LABELS" | awk -v w="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'tolower($0)==w{print;exit}'; }
# Auto-decide labels for one issue from its text, intersected with the repo's labels. Prints the chosen
# EXACT label names, one per line (deduped). Empty when no labels are available (e.g. fetch failed).
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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# PHASE 2 — FILE the staged blocks as public issues (invoked on operator approve-all).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
if [[ "$PHASE" == "file" ]]; then
  nums=(); while IFS= read -r n; do [[ -n "$n" ]] && nums+=("$n"); done < <(staged_numbers)
  if [[ "${#nums[@]}" -eq 0 ]]; then
    govern::log "externalization: nothing staged in the review file — nothing to file"
    exit 0
  fi
  if [[ "$DRY" -ne 1 ]] && ! command -v gh >/dev/null 2>&1; then
    govern::log "externalization: gh not available — cannot file approved review; leaving blocks staged"
    exit 0
  fi
  setup_labels

  filed=0; skipped=0; failed=0; label_rejected=0
  for N in "${nums[@]}"; do
    heading="$(block_heading "$N" "$EXTERNALIZE_REVIEW_FILE")"
    [[ -n "$heading" ]] || continue
    title="${heading#*— }"                       # strip "## #N — "
    body="$(block_body "$N" "$EXTERNALIZE_REVIEW_FILE")"

    if already_externalized "$N"; then
      if [[ "$DRY" -eq 1 ]]; then
        govern::log "[dry] #$N already in ledger — would remove its staged block (heal)"
      else
        govern::log "externalization: #$N already filed (in ledger) — removing its staged block (heal)"
        delete_block "$N" "$EXTERNALIZE_REVIEW_FILE"
      fi
      continue
    fi

    if has_internal_refs "$title"$'\n'"$body"; then
      govern::log "externalization: SKIP #$N \"$title\" — title/body carries internal cross-references (#N / commit hash) that don't translate to a public repo; sanitize it manually before externalizing (left staged)"
      skipped=$((skipped+1))
      continue
    fi

    ticket_labels=()
    if [[ "${#MANUAL_LABELS[@]}" -gt 0 ]]; then
      ticket_labels=("${MANUAL_LABELS[@]}")
    else
      while IFS= read -r _ln; do [[ -n "$_ln" ]] && ticket_labels+=(--label "$_ln"); done < <(auto_labels "$title" "$body")
    fi
    label_names="$(printf '%s ' "${ticket_labels[@]+"${ticket_labels[@]}"}" | sed 's/--label //g')"

    if [[ "$DRY" -eq 1 ]]; then
      govern::log "[dry] would file staged #$N \"$title\" → $repo issue [labels: ${label_names:-none}] + remove its block from the review file"
      continue
    fi

    err_file="$(mktemp)"
    url="$(gh issue create --repo "$repo" --title "$title" --body "$body" ${ticket_labels[@]+"${ticket_labels[@]}"} 2>"$err_file")" || true
    create_err="$(cat "$err_file" 2>/dev/null || true)"; rm -f "$err_file"

    if [[ -n "$url" ]]; then
      if [[ "${#ticket_labels[@]}" -gt 0 ]] && govern::label_apply_rejected "$create_err"; then
        govern::log "externalization: WARN #$N filed but LABELS REJECTED [${label_names:-none}] → $url landed UNLABELED. The governor's gh account lacks ≥ Triage on $repo (GitHub denied addLabelsToLabelable); labels were computed correctly but dropped. ACTION: grant the gh account Triage/Write on $repo. (gh stderr: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))"
        label_rejected=$((label_rejected+1))
      else
        govern::log "externalization: filed #$N \"$title\" → $url [labels: ${label_names:-none}]"
      fi
      append_ledger "$N" "$title" "$url"
      delete_block "$N" "$EXTERNALIZE_REVIEW_FILE"
      filed=$((filed+1))
    else
      govern::log "externalization: gh issue create FAILED for #$N (\"$title\") — leaving it staged in the review file${create_err:+ (gh: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))}"
      failed=1
    fi
  done

  if [[ "$DRY" -ne 1 && "$filed" -gt 0 ]]; then
    commit_files "chore(govern): externalize $filed approved Low $repo ticket(s) to public issues" "$EXTERNALIZE_REVIEW_FILE" "$EXTERNALIZED_FILE"
  fi
  govern::log "externalization(file-approved): filed=$filed (labels-rejected=$label_rejected) skipped=$skipped failed=$failed (repo=$repo, dry=$DRY)"
  [[ "$label_rejected" -gt 0 ]] && govern::log "externalization: NOTE $label_rejected issue(s) filed UNLABELED this run — grant the governor's gh account ≥ Triage on $repo so auto-labels stick."
  [[ "$failed" -eq 0 ]] || exit 1
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# PHASE 1 — STAGE eligible tickets + file/refresh the ONE review questionnaire (default mode).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cands=()
while IFS= read -r n; do [[ -n "$n" ]] && cands+=("$n"); done < <(govern::externalize_candidates "$TICKETS_FILE")

if [[ "$DRY" -eq 1 ]]; then
  if [[ "${#cands[@]}" -gt 0 ]]; then
    govern::log "[dry] would STAGE ${#cands[@]} Low $repo ticket(s) to $EXTERNALIZE_REVIEW_FILE: $(printf '#%s ' "${cands[@]}")and file/refresh the operator review questionnaire"
  else
    govern::log "[dry] externalization: no newly eligible Low $repo tickets to stage this run"
  fi
  exit 0
fi

# Move each eligible ticket out of the live queue into the review file.
for N in "${cands[@]}"; do stage_block "$N"; done
[[ "${#cands[@]}" -gt 0 ]] && commit_files "chore(govern): stage ${#cands[@]} Low $repo ticket(s) for externalization review" "$TICKETS_FILE" "$EXTERNALIZE_REVIEW_FILE"

# Anything staged (this run or a prior one still awaiting a decision) → ensure exactly ONE open
# questionnaire. Deduped by Kind so a re-nudge never stacks a second escalation.
staged=(); while IFS= read -r n; do [[ -n "$n" ]] && staged+=("$n"); done < <(staged_numbers)
if [[ "${#staged[@]}" -eq 0 ]]; then
  govern::log "externalization: nothing staged for review — no questionnaire needed"
  exit 0
fi

if govern::has_open_escalation_kind "$EXTERNALIZE_KIND" >/dev/null 2>&1; then
  govern::log "externalization: ${#staged[@]} ticket(s) staged; an externalize-review questionnaire is already open — re-nudge only (no duplicate)"
  exit 0
fi

# Build a single-line staged summary (#N Title; …) for the Reason field (the ndjson parser reads each
# field as one line, so keep it single-line — semicolon-separated).
summary=""
for N in "${staged[@]}"; do
  h="$(block_heading "$N" "$EXTERNALIZE_REVIEW_FILE")"; t="${h#*— }"
  summary="${summary:+$summary; }#$N $t"
done

SENT="$(govern::next_ticket_number)"
reason="${#staged[@]} Low-severity \`$repo\` ticket(s) staged in queue/tickets-externalize-review.md for public-issue review: ${summary}. NONE is filed until you approve."
question="File these staged tickets as public GitHub Issues on \`$repo\`? They leave the live queue until you decide."
options="approve-all (file every staged ticket as a public issue on $repo) | decide-later (keep them staged; ask again next run) | move-back:<ids> (restore the listed tickets to tickets.md and never re-stage them, e.g. move-back:${staged[0]})"
govern::file_open_escalation "$SENT" "externalize-review: ${#staged[@]} ticket(s) awaiting approval" \
  "$reason" "$question" "$options" "$EXTERNALIZE_KIND" \
  "operator: approve-all | decide-later | move-back:<ids>"
govern::log "externalization: filed review questionnaire #$SENT for ${#staged[@]} staged ticket(s) (repo=$repo)"
exit 0
