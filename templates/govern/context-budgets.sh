#!/usr/bin/env bash
# ── context-budgets.sh: run the context ratchet controls OUTSIDE a dispatch ────────────────────
# The lesson char cap, the CLAUDE.md total budget and the learnings TTL used to fire ONLY inside a
# per-ticket bookkeep. That coupled context hygiene to dispatch volume, so a fleet that stops
# dispatching stops enforcing: measured 2026-09-03, one fleet's root CLAUDE.md sat at 24,366 chars
# against a 14,000 budget (74% over, re-sent on every turn of ~395 interactive sessions) purely
# because no bookkeep had run since August. Budgets are a property of the FILES, not of the run.
#
# Split off from the (now-deleted) govern-bookkeep.sh: that file held two unrelated code paths
# sharing nothing but a filename. This script is one of them, standing alone; the sibling resolve
# path is land-resolution.sh. Neither calls the other.
#
# Usage:  context-budgets.sh [--dry]
# Exit:   0 = under budget after the pass, 3 = still over (doctor gates on this), 1 = usage error
#
# CLAUDE.md is REPORT ONLY, always. This is an operator-invoked entry point now
# (`npm run govern:context-budgets`): nothing flushes it automatically since the dispatch loop's
# run-end block went away. This call never demotes a section and the trim it calls (below)
# never edits CLAUDE.md either. An earlier version demoted any section over GOVERN_LESSON_MAX_CHARS
# whenever a human ran this directly, which is exactly the "auto-editor confidently wrong about one
# block silently costs a rule the workspace needed" failure #110 exists to close: a per-entry cap is
# no less an automatic editor for being manually invoked. The only writers left for CLAUDE.md are
# `claudemd-trim.sh --apply <hash>` and the `/shiploop:compress` playbook, both explicit per-block
# operator actions. learnings.md keeps its own separate, opt-in TTL archive lane (item 3 below): it
# is not CLAUDE.md and was never part of this incident.
#
# NOTHING IS EVER DELETED. A demotion (learnings.md TTL only, see below) moves the full text into
# CLAUDE-APPENDIX.md, which is a real file a human reviews, not a bin. Edits are left UNCOMMITTED on
# purpose: what a session is charged every turn is the operator's call to land, not a script's.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

EB_DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry|--dry-run) EB_DRY=1;;
    *) govern::die "usage: context-budgets.sh [--dry]";;
  esac
  shift
done
eb_root="$(govern::meta_root)"
eb_claude="$eb_root/CLAUDE.md"
eb_appendix="$eb_root/CLAUDE-APPENDIX.md"
eb_learnings="$eb_root/learnings.md"
eb_budget="${GOVERN_LESSON_BUDGET_CHARS:-${SHIPLOOP_CLAUDEMD_MAX_CHARS:-14000}}"
eb_cap="${GOVERN_LESSON_MAX_CHARS:-600}"
eb_moved=0
if [[ "$EB_DRY" -eq 1 ]]; then eb_verb2="would archive"
else eb_verb2="archived"
fi

eb_size() { local n; n="$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')"; printf '%s' "${n:-0}"; }
# Print the byte size of every flush-left `## ` section in $1, as "<size>\t<heading text>".
eb_sections() { # <file>
  awk '
    /^## / { if (h != "") printf "%d\t%s\n", n, h; h = $0; n = length($0) + 1; next }
    h != "" { n += length($0) + 1 }
    END { if (h != "") printf "%d\t%s\n", n, h }
  ' "$1" 2>/dev/null
}
# Move one whole `## ` section out of $1 and append it verbatim to the appendix.
eb_demote() { # <file> <heading-line>
  local file="$1" head="$2" tmpf body
  body="$(awk -v h="$head" 'BEGIN{on=0} $0==h{on=1;print;next} on && /^## /{on=0} on{print}' "$file")"
  [[ -n "$body" ]] || return 1
  tmpf="$(mktemp)"
  awk -v h="$head" 'BEGIN{on=0} $0==h{on=1;next} on && /^## /{on=0} on{next} {print}' "$file" > "$tmpf" || { rm -f "$tmpf"; return 1; }
  if [[ "$EB_DRY" -eq 1 ]]; then rm -f "$tmpf"; return 0; fi
  mv "$tmpf" "$file"
  printf '\n%s\n' "$body" >> "$eb_appendix"
  return 0
}

if [[ ! -f "$eb_claude" ]]; then
  govern::log "budgets: no $eb_claude — nothing to enforce"
  exit 0
fi
# 1. LESSON CHAR CAP. REPORT ONLY. A single section past the cap is a permanent per-turn tax paid
#    by every session, worth flagging, but this function never edits CLAUDE.md to fix it: that is
#    the exact auto-editor this ticket retires. Route it through claudemd-trim.sh's own candidate
#    list (a big block already ranks near the top there) rather than a second, uncoordinated write
#    path into the same file.
eb_oversized=0
while IFS=$'\t' read -r sz head; do
  [[ "$sz" =~ ^[0-9]+$ ]] || continue
  [[ "$sz" -gt "$eb_cap" ]] || continue
  eb_oversized=$((eb_oversized+1))
done < <(eb_sections "$eb_claude" | sort -k1,1nr)
if [[ "$eb_oversized" -gt 0 ]]; then
  govern::log "budgets: $eb_oversized section(s) exceed GOVERN_LESSON_MAX_CHARS=$eb_cap chars (informational only, nothing moved): run /shiploop:compress"
fi

# 2. TOTAL BUDGET. claudemd-trim.sh detects and reports; it never edits CLAUDE.md. It classifies
#    every block (dead-citation / duplicate / jit-candidate / judgment), protects load-bearing
#    rules outright, and writes ranked candidates to governor/claudemd-trim-proposals.md for
#    /shiploop:compress (or `claudemd-trim.sh --apply <hash>`) to act on. Its exit 3 means
#    "candidates exist", not an error, and must never gate a run. The size check below stays as
#    the alarm (exit 3, doctor gates on it).
if [[ -f "$DIR/claudemd-trim.sh" ]]; then
  eb_trim_rc=0
  if [[ "$EB_DRY" -eq 1 ]]; then bash "$DIR/claudemd-trim.sh" --dry-run || eb_trim_rc=$?
  else bash "$DIR/claudemd-trim.sh" || eb_trim_rc=$?
  fi
  if [[ "$eb_trim_rc" -ne 0 && "$eb_trim_rc" -ne 3 ]]; then
    govern::log "budgets: claudemd-trim.sh exited $eb_trim_rc (continuing; the size check below still gates)"
  fi
fi

# 3. LEARNINGS TTL (opt-in, SHIPLOOP_LEARNINGS_TTL=1 — the same knob the SessionStart digest reads,
#    so the warning and the enforcement can never disagree). learnings.md is transient by contract;
#    an entry past the window is archived to the appendix rather than deleted, because a still-true
#    measurement that vanishes just gets re-derived at full cost.
if [[ "${SHIPLOOP_LEARNINGS_TTL:-0}" == "1" && -f "$eb_learnings" ]]; then
  eb_ttl_days="${SHIPLOOP_LEARNINGS_TTL_DAYS:-14}"
  eb_today="${SHIPLOOP_LEARNINGS_TODAY:-$(date +%Y-%m-%d)}"
  eb_today_n="${eb_today//-/}"
  while IFS=$'\t' read -r _sz head; do
    eb_d="$(awk -v h="$head" 'BEGIN{on=0} $0==h{on=1} on{print} on && /^## / && $0!=h{exit}' "$eb_learnings" \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sed -n '1p' || true)"
    [[ -n "$eb_d" ]] || continue                       # undated entries are never aged out
    eb_age=$(( ( $(date -j -f %Y-%m-%d "$eb_today" +%s 2>/dev/null || date -d "$eb_today" +%s 2>/dev/null || echo 0) \
               - $(date -j -f %Y-%m-%d "$eb_d" +%s 2>/dev/null || date -d "$eb_d" +%s 2>/dev/null || echo 0) ) / 86400 ))
    [[ "$eb_age" -gt "$eb_ttl_days" ]] || continue
    if eb_demote "$eb_learnings" "$head"; then
      eb_moved=$((eb_moved+1))
      govern::log "budgets: $eb_verb2 learnings entry \"$head\" (${eb_age}d old > SHIPLOOP_LEARNINGS_TTL_DAYS=$eb_ttl_days) → CLAUDE-APPENDIX.md"
    fi
  done < <(eb_sections "$eb_learnings" | sort -k1,1nr)
  : "$eb_today_n"
fi

eb_final="$(eb_size "$eb_claude")"
govern::log "budgets: CLAUDE.md $eb_final/$eb_budget chars (report only: nothing automatic ever edits CLAUDE.md)"
if [[ "$eb_moved" -gt 0 ]]; then
  govern::log "budgets: $eb_moved learnings.md entr(ies) $eb_verb2 to CLAUDE-APPENDIX.md"
fi
if [[ "$eb_final" -gt "$eb_budget" ]]; then
  govern::log "budgets: STILL OVER by $(( eb_final - eb_budget )) chars. Nothing was moved automatically and nothing ever is: run /shiploop:compress, or review governor/claudemd-trim-proposals.md and claudemd-trim.sh --apply <hash> the blocks you approve, or stamp keepers with --still-true <hash>."
  exit 3
fi
if [[ "$EB_DRY" -eq 0 && "$eb_moved" -gt 0 ]]; then
  govern::log "budgets: edits left UNCOMMITTED in $eb_root: review and commit them yourself"
fi
exit 0
