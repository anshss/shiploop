#!/usr/bin/env bash
# #274: CLASSIFIED promotion bridge between the two disjoint governor backlogs.
#
# The governor has TWO backlogs: queue/tickets.md is drained autonomously, but governor/improvements.md
# is observe->propose only — govern-self-apply.sh is opt-in (default OFF) and the autonomous loop never
# reads improvements.md. So a self-improvement proposal was acted on ONLY when the operator remembered
# to review run-end output and manually promote it (same remember-vs-mechanism class as #271).
#
# This bridge runs right after govern-improve.sh appends a run's proposals. It CLASSIFIES each proposal
# and auto-files the SAFE/additive ones as ONE ticket via file-ticket.sh, so the governor drains them
# like any ticket — no manual promote-remember step.
#
# CRITICAL CAVEAT (the whole reason this is a CLASSIFIED bridge, not a wholesale merge): a proposal that
# touches the governor's OWN safety rails — GOVERN_MAX_* run bounds, the merge allowlist, the permission
# mode / bypassPermissions, the green-or-none merge gate — or is labelled `OPERATOR DECISION` is NEVER
# auto-queued. Rationale: a harness-self-change filed as a ticket would AUTO-MERGE on the harness repo,
# which has NO PR-level CI — strictly LESS safe than govern-self-apply.sh's test-gated path. Rail-touching
# proposals stay in improvements.md behind the explicit human gate.
#
# Conservative by design: anything matching the rail patterns stays human-gated. A false "rail" merely
# defers a safe idea to a human; a false "safe" would auto-queue a rail change — the dangerous direction
# the ticket forbids. When in doubt, hold.
#
# Usage: govern-improve-triage.sh [run-id]
#   run-id given  → triage only that run's block (the run-loop path, precise).
#   run-id absent → triage the newest un-triaged block (the manual `govern:improve-triage` path).
# Idempotent: a block already carrying an AUTO-PROMOTED / AUTO-TRIAGE / PROMOTED annotation is skipped.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
FILE="${GOVERN_IMPROVEMENTS_FILE:-$GOVERNOR_DIR/improvements.md}"
RUNID="${1:-}"

[[ -f "$FILE" ]] || { govern::log "improve-triage: no improvements.md — nothing to triage"; exit 0; }

# Rail-touching / human-gate patterns (matched case-insensitively per proposal line). The shared knob
# identifiers come from ONE definition (GOVERN_PROTECTED_PATTERNS in common.sh — #331), so a rail added
# there is protected here automatically; this line only adds the human-readable rail PHRASES the
# improve-reviewer writes (which self-apply, grepping a code diff, doesn't need).
RAIL="${GOVERN_PROTECTED_PATTERNS}|OPERATOR DECISION|merge allowlist|merge-allowlist|permission mode|permission gate|run bound|loop bound|hard-stop|hard stop|safety rail|green-or-none|green or none|auto-merge|auto merge"

# ── Locate the target block (a `## ` heading and everything up to the next `## ` / EOF) ──
if [[ -n "$RUNID" ]]; then
  hdr_ln="$(grep -nE "^## .*${RUNID}" "$FILE" | tail -1 | cut -d: -f1 || true)"
else
  hdr_ln="$(grep -nE '^## ' "$FILE" | tail -1 | cut -d: -f1 || true)"
fi
[[ -n "$hdr_ln" ]] || { govern::log "improve-triage: no proposal block found${RUNID:+ for $RUNID}"; exit 0; }

block="$(awk -v start="$hdr_ln" 'NR>start && /^## /{exit} NR>=start{print}' "$FILE")"
block_hdr="$(printf '%s\n' "$block" | head -1)"

# Idempotency: never re-triage a block already annotated (auto or manual).
if printf '%s' "$block" | grep -qiE 'AUTO-PROMOTED|AUTO-TRIAGE|PROMOTED TO TICKETS'; then
  govern::log "improve-triage: block '${block_hdr}' already triaged — skipping"; exit 0
fi

# ── Extract proposal bullets (-, *, or "N.") and classify each ──
bullets="$(printf '%s\n' "$block" | grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]' || true)"

safe=(); nrail=0
while IFS= read -r line; do
  [[ -n "${line//[[:space:]]/}" ]] || continue
  if printf '%s' "$line" | grep -qiE "$RAIL"; then
    nrail=$((nrail+1))
  else
    safe+=("$line")
  fi
done <<< "$bullets"

date_now="$(date +%Y-%m-%d\ %H:%M)"
run_label="${RUNID:-$(printf '%s' "$block_hdr" | sed -E 's/^## //')}"

# annotate BLOCK-HEADER-LINE with NOTE, in place (match the exact header text — no regex).
annotate() { # note
  local note="$1" tmp; tmp="$(mktemp)"
  awk -v hdr="$block_hdr" -v note="$note" '
    { print }
    $0==hdr && !done { print ""; print note; done=1 }
  ' "$FILE" > "$tmp" && mv "$tmp" "$FILE"
}

commit_annotation() { # ticket-number-or-empty
  [[ "$FILE" == "$GOVERNOR_DIR/improvements.md" ]] || return 0
  govern::commit_meta_to_main "$WS_ROOT" "governor/improvements.md" \
    "chore(govern): auto-triage improvements → ticket #${1:-none} (#274)" \
    && govern::log "improve-triage: committed improvements.md annotation to main (#274)"
}

if [[ "${#safe[@]}" -eq 0 ]]; then
  annotate "> **AUTO-TRIAGE ${date_now}:** no safe/additive proposals to promote — ${nrail} rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274)."
  commit_annotation ""
  govern::log "improve-triage: nothing safe to promote (${nrail} rail-touching held) for '${run_label}'"
  exit 0
fi

# ── File the SAFE proposals as ONE ticket via the supported atomic path ──
# Build the body in a temp file (NOT `$(cat <<EOF)`: macOS bash 3.2 mis-parses a command-substituted
# heredoc whose body contains parentheses), then pipe it into file-ticket.sh (reads body from stdin).
safe_list="$(printf '%s\n' "${safe[@]}")"
block_ref="${block_hdr##\#\# }"   # header text without the leading "## "
bodyfile="$(mktemp)"
cat > "$bodyfile" <<EOF
Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run ${run_label}. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
${safe_list}

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "${block_ref}". ${nrail} rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).
EOF

# ── ONE STANDING TICKET, not one per run ────────────────────────────────────────────────────────
# This used to mint a fresh `## #N` every time it fired. Self-improvement proposals recur — the same
# friction produces the same proposal next run — so the queue accumulated near-duplicate entries
# that a human then had to reconcile by hand (#62/#67/#72/#75/#76 were five entries describing one
# thing). They are the SAME work item, so they belong in the SAME ticket: if an open one is already
# there, append this run's proposals to it and reuse its number.
#
# Matching is on the ticket TITLE prefix — deliberately not a marker comment or a side-file, so the
# link is visible to anyone reading tickets.md and survives a hand-edit. Bookkeeping deletes the
# block on resolve exactly as for any other ticket, and the next run then opens a fresh one.
STANDING_TITLE="Harness self-improvement: promote safe proposals"

# Appends under the bookkeep lock — the same lock file-ticket.sh takes — so a concurrent filer can
# never interleave with this read-modify-write. Fail-open: if the lock can't be had, fall through to
# filing a normal new ticket rather than dropping the proposals.
append_to_standing() { # <ticket-number> <bodyfile> -> rc 0 on success
  local num="$1" src="$2"
  local lock tmp rc
  local got=0
  lock="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
  govern::lock_acquire "$lock" 60 300 && got=1
  [[ "$got" == "1" ]] || return 1
  tmp="$(mktemp)"
  # Insert immediately BEFORE the block's terminating boundary (the next `## #` heading or EOF), so
  # the appended run sits inside the ticket it belongs to.
  if awk -v num="$num" -v add="$(date +%Y-%m-%d\ %H:%M)" -v runl="$run_label" -v addfile="$src" '
    function flush_add(   line) {
      if (emitted) return
      print ""
      print "**Also proposed after run " runl " (" add "):**"
      while ((getline line < addfile) > 0) print line
      close(addfile)
      emitted = 1
    }
    /^##[[:space:]]+#[0-9]+/ {
      if (inblock) { flush_add(); inblock = 0 }
      cur = $0; sub(/^##[[:space:]]+#/, "", cur); sub(/[^0-9].*/, "", cur)
      if (cur == num) inblock = 1
    }
    { print }
    END { if (inblock) flush_add() }
  ' "$TICKETS_FILE" > "$tmp"; then
    mv "$tmp" "$TICKETS_FILE"; rc=0
  else
    rm -f "$tmp"; rc=1
  fi
  govern::lock_release "$lock"
  return "$rc"
}

# An OPEN standing ticket = a `## #N` heading whose title starts with STANDING_TITLE.
standing_n="$(grep -oE "^##[[:space:]]+#[0-9]+[[:space:]]*[—-][[:space:]]*${STANDING_TITLE}" "$TICKETS_FILE" 2>/dev/null \
  | tail -1 | sed -E 's/^##[[:space:]]+#([0-9]+).*/\1/' || true)"

n=""
if [[ "$standing_n" =~ ^[0-9]+$ ]] && append_to_standing "$standing_n" "$bodyfile"; then
  n="$standing_n"
  govern::log "improve-triage: appended ${#safe[@]} proposal(s) to the STANDING ticket #${n} instead of minting a new one"
  govern::commit_meta_to_main "$(dirname "$TICKETS_FILE")" "$(govern::tickets_relpath)" \
    "chore(govern): append run ${run_label} proposals to standing ticket #${n} (#274)" >/dev/null 2>&1 || true
else
  n="$("$DIR/file-ticket.sh" "${STANDING_TITLE} (from ${run_label})" Low < "$bodyfile" 2>/dev/null || true)"
fi
rm -f "$bodyfile"

if [[ ! "$n" =~ ^[0-9]+$ ]]; then
  govern::log "improve-triage: file-ticket did not return a number (got '${n}') — leaving block untriaged for manual review"
  exit 0
fi

annotate "> **AUTO-PROMOTED ${date_now}:** ${#safe[@]} safe proposal(s) → ticket **#${n}**. ${nrail} rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274)."
commit_annotation "$n"
govern::log "improve-triage: filed #${n} with ${#safe[@]} safe proposal(s); ${nrail} rail-touching held for '${run_label}'"
