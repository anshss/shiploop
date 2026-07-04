#!/usr/bin/env bash
# Externalization lane (OPT-IN): once per governor run, file each OPEN Low-severity ticket that targets
# the configured OSS sub-repo as a public GitHub Issue on GOVERN_EXTERNALIZE_REPO, then remove its block
# from tickets.md and record it in queue/externalized.md. This is the mechanism by which the maintainer
# backlog seeds "good first issue"-style work for outside contributors and drives traction on the OSS repo.
#
# OFF by default. Enable by setting BOTH GOVERN_EXTERNALIZE_REPO (owner/repo) and
# GOVERN_EXTERNALIZE_SUBREPO (short sub-repo name matched against each ticket's Where line) in
# workspace.sh. Either unset → the lane no-ops cleanly.
#
# Eligibility = govern::externalize_candidates (Severity: Low AND Where → OSS sub-repo, EXCLUDING sibling
# repos whose name merely contains the OSS name as a substring, e.g. myproject-website ⊃ myproject).
# Gated by GOVERN_EXTERNALIZE_LANE (default 1) at the CALL SITE (run-loop.sh) and re-checked here
# (defense in depth).
#
# Honors --dry (or MODE=dry / GOVERN_ECHO=1): logs what WOULD be filed, makes NO gh call, NO edit, NO
# commit. Idempotent: a ticket already in externalized.md is never re-filed — if a prior run created the
# issue but didn't land the block delete (partial failure), this run HEALS by removing the lingering
# block only. Non-fatal by contract: a per-ticket gh failure leaves that ticket in place and the script
# exits non-zero, which the caller swallows so the loop never stalls.
#
# OPERATOR REQUIREMENT (#26): for auto-labels to actually apply, the gh account the governor is authed
# as needs ≥ Triage on GOVERN_EXTERNALIZE_REPO. `gh issue create --label …` is a COMPOSITE op — it
# creates the issue, then applies labels via a SEPARATE GraphQL `addLabelsToLabelable` mutation that a
# pull-only account is denied. The create still returns the URL, so the lane no longer infers full
# success from the URL alone: it captures create stderr and, on a label-permission rejection, emits a
# distinct WARN ("filed but labels REJECTED") instead of a silent `filed` success.
#
# Usage: externalize-low-tickets.sh [--dry]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

DRY=0
[[ "${1:-}" == "--dry" || "${MODE:-}" == "dry" || "${GOVERN_ECHO:-0}" == "1" ]] && DRY=1

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

# Without gh there's nothing to file — skip cleanly (a dry run still narrates intent).
if [[ "$DRY" -ne 1 ]] && ! command -v gh >/dev/null 2>&1; then
  govern::log "externalization: gh not available — skipping lane"
  exit 0
fi

# Collect eligible ticket numbers (bash 3.2: no mapfile).
cands=()
while IFS= read -r n; do [[ -n "$n" ]] && cands+=("$n"); done < <(govern::externalize_candidates "$TICKETS_FILE")
if [[ "${#cands[@]}" -eq 0 ]]; then
  govern::log "externalization: no Low-severity $repo tickets eligible"
  exit 0
fi

# Labels. GOVERN_EXTERNALIZE_LABELS, if set, is a manual override applied verbatim to every issue.
# Otherwise the lane AUTO-DECIDES per issue: it fetches the repo's EXISTING labels once and picks from
# them — the contributor signals ("good first issue", "help wanted") plus one content-derived category
# (documentation / test / pricing / bug / enhancement). Only labels the repo actually has are applied,
# so `gh` never fails on an unknown label. The fetch is read-only (safe in dry-run).
MANUAL_LABELS=()
AVAIL_LABELS=""
if [[ -n "${GOVERN_EXTERNALIZE_LABELS:-}" ]]; then
  IFS=',' read -r -a _labels <<< "$GOVERN_EXTERNALIZE_LABELS"
  for _l in "${_labels[@]}"; do
    _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"  # trim
    [[ -n "$_l" ]] && MANUAL_LABELS+=(--label "$_l")
  done
elif command -v gh >/dev/null 2>&1; then
  AVAIL_LABELS="$(gh label list --repo "$repo" --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
fi

# Exact repo label name matching $1 case-insensitively (gh needs the exact name), or "" if absent.
label_if_exists() { printf '%s\n' "$AVAIL_LABELS" | awk -v w="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'tolower($0)==w{print;exit}'; }

# Auto-decide labels for one issue from its text, intersected with the repo's labels. Prints the chosen
# EXACT label names, one per line (deduped). Empty when no labels are available (e.g. fetch failed).
auto_labels() { # title body
  local text cat l exact picked=""
  text="$(printf '%s\n%s' "$1" "$2" | tr 'A-Z' 'a-z')"
  # Universal content categories only — no domain-specific buckets (a workspace can add its own by
  # forking this arm or via GOVERN_EXTERNALIZE_LABELS to override auto-decide entirely).
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

# Delete ticket #N's block (heading through its trailing ---) — the EXACT mechanism govern-bookkeep.sh
# uses, so an externalized block is removed identically to a resolved one (atomic mktemp+mv).
delete_block() { # N
  local n="$1" tmp; tmp="$(mktemp)"
  awk -v n="$n" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" { grab=1 }
    grab && /^---[[:space:]]*$/ { grab=0; next }
    grab { next }
    { print }
  ' "$TICKETS_FILE" > "$tmp"
  mv "$tmp" "$TICKETS_FILE"
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

filed=0; healed=0; skipped=0; failed=0; label_rejected=0
for N in "${cands[@]}"; do
  heading="$(grep -m1 -E "^## #$N([^0-9]|\$)" "$TICKETS_FILE" || true)"
  [[ -n "$heading" ]] || continue
  title="${heading#*— }"                       # strip "## #N — " (shortest match → first em-dash)
  # The public issue body = the ticket block from the heading's trailing line down to (not including)
  # the closing ---, MINUS the **Ref:** line (always internal provenance). No internal #N (the heading
  # is reconstructed from the title alone).
  body="$(awk -v n="$N" '
    $0 ~ ("^## #" n "([^0-9]|$)") { grab=1; next }
    grab && /^---[[:space:]]*$/ { exit }
    grab { print }
  ' "$TICKETS_FILE" | grep -v '^\*\*Ref:\*\*')"

  # Partial-failure heal: the issue was filed on a prior run but its block never left tickets.md.
  if already_externalized "$N"; then
    if [[ "$DRY" -eq 1 ]]; then
      govern::log "[dry] #$N already in ledger — would remove its lingering tickets.md block (heal)"
    else
      govern::log "externalization: #$N already filed (in ledger) — removing its lingering block (heal)"
      delete_block "$N"; healed=$((healed+1))
    fi
    continue
  fi

  # Leak guard: after dropping Ref, if the title or body still references another ticket / a commit,
  # it's not self-contained for an outside contributor — skip it (leave it in tickets.md for a human).
  if has_internal_refs "$title"$'\n'"$body"; then
    govern::log "externalization: SKIP #$N \"$title\" — title/body carries internal cross-references (#N / commit hash) that don't translate to a public repo; sanitize it manually before externalizing"
    skipped=$((skipped+1))
    continue
  fi

  # Per-issue labels: the manual override (static) or auto-decided from the repo's existing labels.
  ticket_labels=()
  if [[ "${#MANUAL_LABELS[@]}" -gt 0 ]]; then
    ticket_labels=("${MANUAL_LABELS[@]}")
  else
    while IFS= read -r _ln; do [[ -n "$_ln" ]] && ticket_labels+=(--label "$_ln"); done < <(auto_labels "$title" "$body")
  fi
  label_names="$(printf '%s ' "${ticket_labels[@]+"${ticket_labels[@]}"}" | sed 's/--label //g')"

  if [[ "$DRY" -eq 1 ]]; then
    govern::log "[dry] would externalize #$N \"$title\" → $repo issue [labels: ${label_names:-none}] + remove its block from tickets.md"
    continue
  fi

  # CAPTURE stderr instead of discarding it (#26). `gh issue create --label …` is a COMPOSITE op:
  # it creates the issue (URL on stdout, exit 0) and THEN applies labels via a separate GraphQL
  # `addLabelsToLabelable` mutation. When the authed gh account has only `pull` on $repo, GitHub
  # CREATES the issue but REJECTS the label step — that rejection lands ONLY on stderr while the URL
  # is still returned. The old `2>/dev/null` + "non-empty URL ⇒ success" therefore logged `filed`
  # while every label was silently dropped. So: keep stderr, and after a create distinguish
  # "filed + labeled" from "filed but labels REJECTED".
  err_file="$(mktemp)"
  url="$(gh issue create --repo "$repo" --title "$title" --body "$body" ${ticket_labels[@]+"${ticket_labels[@]}"} 2>"$err_file")" || true
  create_err="$(cat "$err_file" 2>/dev/null || true)"; rm -f "$err_file"

  if [[ -n "$url" ]]; then
    # The issue exists on GitHub — record + de-block it (re-filing would create a DUPLICATE). But
    # surface whether the labels actually landed: a label rejection is NOT a silent `filed` success.
    if [[ "${#ticket_labels[@]}" -gt 0 ]] && govern::label_apply_rejected "$create_err"; then
      govern::log "externalization: WARN #$N filed but LABELS REJECTED [${label_names:-none}] → $url landed UNLABELED. The governor's gh account lacks ≥ Triage on $repo (GitHub denied addLabelsToLabelable); labels were computed correctly but dropped. ACTION: grant the gh account Triage/Write on $repo. (gh stderr: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))"
      label_rejected=$((label_rejected+1))
    else
      govern::log "externalization: filed #$N \"$title\" → $url [labels: ${label_names:-none}]"
    fi
    append_ledger "$N" "$title" "$url"
    delete_block "$N"
    filed=$((filed+1))
  else
    govern::log "externalization: gh issue create FAILED for #$N (\"$title\") — leaving ticket in tickets.md${create_err:+ (gh: $(printf '%s' "$create_err" | tr '\n' ' ' | cut -c1-160))}"
    failed=1
  fi
done

# Commit tickets.md + the ledger to main (coordination files commit directly to main — anti-pattern #8).
# Mirrors govern-bookkeep's CAS-with-retry push so a concurrent driver sharing origin/main can't resurrect
# the deleted blocks. Guarded: a pure no-op outside a git repo (tests) or under GOVERN_NO_PUSH=1.
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"   # '|| true' → "" if dir missing
# `-n "$commit_dir"` guards the #28 footgun: an empty commit_dir would make `git -C ""` resolve to the
# CURRENT repo, so a missing queue dir must never reach the commit.
if [[ "$DRY" -ne 1 && $(( filed + healed )) -gt 0 && -n "$commit_dir" ]] && git -C "$commit_dir" rev-parse --git-dir >/dev/null 2>&1; then
  ( cd "$commit_dir"
    git add -- "$TICKETS_FILE" "$EXTERNALIZED_FILE" 2>/dev/null || true
    if ! git diff --cached --quiet -- "$TICKETS_FILE" "$EXTERNALIZED_FILE" 2>/dev/null; then
      git commit -q -m "chore(govern): externalize $filed Low $repo ticket(s) to public issues" \
        -- "$TICKETS_FILE" "$EXTERNALIZED_FILE" || exit 0
      if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
        for _a in 1 2 3 4 5; do
          git push origin HEAD:main >/dev/null 2>&1 && break
          git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
        done
      fi
    fi )
fi

govern::log "externalization: filed=$filed (labels-rejected=$label_rejected) healed=$healed skipped=$skipped failed=$failed (repo=$repo, dry=$DRY)"
# A label rejection is a soft fault: the issue WAS filed (so not a hard `failed`), but it landed
# unlabeled because the gh account lacks Triage on $repo. Surface ONE summary nudge so the operator
# action (grant Triage) isn't buried in the per-ticket WARNs above.
[[ "$label_rejected" -gt 0 ]] && govern::log "externalization: NOTE $label_rejected issue(s) filed UNLABELED this run — labels are computed correctly but GitHub rejects applying them. ACTION: grant the governor's gh account ≥ Triage on $repo so auto-labels stick."
[[ "$failed" -eq 0 ]] || exit 1
exit 0
