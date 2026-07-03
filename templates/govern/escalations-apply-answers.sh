#!/usr/bin/env bash
# #62 — close the escalation lifecycle. Run at run-START: read the operator answers the relay
# recorded into escalations.md and DRIVE an action so a decision never sits as inert file text:
#   • Disposition "do-the-work" → UN-PARK: move the `### #N` entry from "## Open" to "## Resolved"
#       so select-ticket stops skipping it → the governor retries the ticket this run.
#   • Disposition "defer" (defer-indefinitely / won't-do / keep-manual / close) → auto-MIGRATE the
#       ticket: move its `## #N` block from tickets.md to tickets-parked.md (renumber to that queue's
#       max+1) AND move the escalation to "## Resolved", so tickets.md stays the live workable set
#       and doesn't silently fill with decided-but-undead escalations.
#   • Disposition "mitigated" (#121) → CLOSE as accepted-current-state: the situation is already
#       acceptable / harm is zero but the literal done-condition needs out-of-band action. Mechanically
#       like "defer" (the `## #N` block leaves tickets.md), but the ticket is NOT parked as still-todo —
#       it's just removed, and the escalation moves to "## Resolved" with a "resolved — mitigated" note.
#       Distinct from defer (still-todo, manual queue) and do-the-work (retry).
#   • "Make this a rule?" answered with a rule → append it to preferences.md (grows the doctrine).
# Unanswered / keep-open entries are left exactly as-is. Idempotent: an already-Resolved entry is
# never re-touched. Commits the result in the dir holding tickets.md (like govern-bookkeep.sh).
#
# Usage:  escalations-apply-answers.sh        (no args; reads the governor files)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
DATE="$(date +%Y-%m-%d)"

[[ -f "$ESCALATIONS_FILE" ]] || { echo "no escalations file — nothing to apply"; exit 0; }

# 1. Collect answered open entries with a recognized disposition.
entries="$(govern::escalations_open_ndjson | jq -s '.' 2>/dev/null || echo '[]')"
[[ -n "$entries" ]] || entries='[]'
n_entries="$(printf '%s' "$entries" | jq 'length' 2>/dev/null || echo 0)"
# #3: regenerate pending-escalations.json even on the no-op paths, so a stale/ghost snapshot is
# corrected against escalations.md whether or not we act (a manual resolution / crashed prior run can
# leave pending listing a closed entry or missing a still-open one). Cheap, idempotent.
if [[ "$n_entries" -le 0 ]]; then
  "$DIR/escalations-emit-pending.sh" >/dev/null 2>&1 || true
  echo "no open escalations — nothing to apply"; exit 0
fi

# If the workspace ships the bookkeep mutex (concurrent-driver builds), serialize the
# tickets.md / escalations.md read-modify-write against a concurrent driver's bookkeep,
# reusing the same lock. The base scaffold is single-driver and has no such helper — skip then.
if declare -F govern::lock_acquire >/dev/null 2>&1; then
  BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
  govern::lock_acquire "$BK_LOCK" 60 300 || govern::log "apply-answers: bookkeep lock busy >60s — proceeding (degraded)"
  trap 'govern::lock_release "$BK_LOCK"' EXIT
fi

resolved_csv=","          # tickets to move Open → Resolved
notes_file="$(mktemp)"    # tab-separated: ticket<TAB>resolution note
acted=0; n_unpark=0; n_defer=0; n_mitigated=0; n_rule=0

# Migrate a ticket block tickets.md → tickets-parked.md, renumbered to the parked queue's max+1.
# Prints the new number, or empty if the block wasn't found in tickets.md.
migrate_to_parked() { # N -> M
  local N="$1" pmax M block tmp
  pmax="$(grep -oE '^## #[0-9]+' "$TICKETS_PARKED_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)"; pmax="${pmax:-0}"
  M=$((pmax+1))
  block="$(awk -v n="$N" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" {grab=1}
    grab {print}
    grab && /^---[[:space:]]*$/ {exit}
  ' "$TICKETS_FILE")"
  [[ -n "$block" ]] || { echo ""; return 0; }
  # renumber the heading + stamp provenance, append to the parked queue.
  { printf '\n'
    printf '%s\n' "$block" | awk -v n="$N" -v m="$M" -v d="$DATE" '
      NR==1 { sub("#" n, "#" m); print; print ""; print "**Parked:** " d " — auto-migrated from tickets.md by the governor (escalation #" n " answered: defer / keep-manual / won'"'"'t-do)."; next }
      { print }'
  } >> "$TICKETS_PARKED_FILE"
  # delete the block from tickets.md.
  tmp="$(mktemp)"
  awk -v n="$N" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" {grab=1}
    grab && /^---[[:space:]]*$/ {grab=0; next}
    grab {next}
    {print}
  ' "$TICKETS_FILE" > "$tmp" && mv "$tmp" "$TICKETS_FILE"
  echo "$M"
}

# Delete a ticket block from tickets.md WITHOUT parking it (#121 — the `mitigated` disposition).
# Mechanically the same removal migrate_to_parked does, but the block is NOT appended to
# tickets-parked.md: the ticket is closed as accepted-current-state, not parked as still-todo.
# Returns 0 if a block was removed, 1 if no `## #N` block was present.
delete_ticket_block() { # N -> 0 removed | 1 not found
  local N="$1" tmp
  grep -qE "^##[[:space:]]+#$N([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null || return 1
  tmp="$(mktemp)"
  awk -v n="$N" '
    $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" {grab=1}
    grab && /^---[[:space:]]*$/ {grab=0; next}
    grab {next}
    {print}
  ' "$TICKETS_FILE" > "$tmp" && mv "$tmp" "$TICKETS_FILE"
  return 0
}

# Append an operator-confirmed rule to preferences.md (grows the doctrine slowly, #62).
append_rule() { # N text
  local N="$1" text="$2" sect="## Auto-added rules (from answered escalations)"
  grep -qF "$sect" "$PREFERENCES_FILE" 2>/dev/null || printf '\n%s\n' "$sect" >> "$PREFERENCES_FILE"
  printf -- '- (#%s, %s) %s\n' "$N" "$DATE" "$text" >> "$PREFERENCES_FILE"
}

# 2. Decide + act per answered entry.
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  tk="$(jq -r '.ticket' <<<"$row")"
  ans="$(jq -r '.answer // ""' <<<"$row")"
  dispraw="$(jq -r '.disposition // ""' <<<"$row")"
  ruleraw="$(jq -r '.makeRule // ""' <<<"$row")"

  # Skip entries the operator hasn't answered yet.
  govern::is_placeholder "$ans" && govern::is_placeholder "$dispraw" && continue

  # Read the canonical token from the Disposition field (skip it if still the placeholder — its
  # help text embeds the option words and would otherwise parse as a real disposition).
  # #87: anchor on the LEADING token first (govern::disposition_lead_token), so a clarifying
  # parenthetical that names another canonical token (e.g. `keep-open _(NOT do-the-work)_`) is not
  # misclassified by norm_disposition's anywhere-in-string match.
  if govern::is_placeholder "$dispraw"; then disp=""; else disp="$(govern::norm_disposition "$(govern::disposition_lead_token "$dispraw")")"; fi
  # Fall back to reading the disposition out of the free-text answer if the field is blank.
  [[ -z "$disp" ]] && ! govern::is_placeholder "$ans" && disp="$(govern::norm_disposition "$ans")"

  # "Make this a rule?" — append if a substantive rule was given (not placeholder / no / yes-only).
  if ! govern::is_placeholder "$ruleraw"; then
    rl="$(printf '%s' "$ruleraw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$(printf '%s' "$rl" | tr 'A-Z' 'a-z')" in
      ''|no|none|n/a|-|false) : ;;                            # not a rule
      yes|y|true) append_rule "$tk" "${ans:-$rl}"; n_rule=$((n_rule+1)); acted=1 ;;  # affirmative w/o text → use the answer
      *)          append_rule "$tk" "$rl";          n_rule=$((n_rule+1)); acted=1 ;;  # explicit rule text
    esac
  fi

  case "$disp" in
    do-the-work)
      resolved_csv+="$tk,"; printf '%s\t%s\n' "$tk" "un-parked — governor will retry this ticket (operator: do-the-work)" >> "$notes_file"
      n_unpark=$((n_unpark+1)); acted=1
      govern::log "apply-answers: #$tk answered do-the-work → un-parking (governor retries)"
      ;;
    defer)
      M="$(migrate_to_parked "$tk")"
      if [[ -n "$M" ]]; then
        resolved_csv+="$tk,"; printf '%s\t%s\n' "$tk" "deferred — ticket moved to tickets-parked.md as #$M (operator: defer / keep-manual)" >> "$notes_file"
        n_defer=$((n_defer+1)); acted=1
        govern::log "apply-answers: #$tk answered defer → migrated tickets.md → tickets-parked.md as #$M; escalation resolved"
      else
        # Ticket block already gone from tickets.md (e.g. resolved elsewhere) — still close the escalation.
        resolved_csv+="$tk,"; printf '%s\t%s\n' "$tk" "deferred — no live ticket block in tickets.md (already removed); escalation closed" >> "$notes_file"
        n_defer=$((n_defer+1)); acted=1
        govern::log "apply-answers: #$tk answered defer but no tickets.md block found — closing escalation only"
      fi
      ;;
    mitigated)
      if delete_ticket_block "$tk"; then
        resolved_csv+="$tk,"; printf '%s\t%s\n' "$tk" "resolved — mitigated: accepted current state (harm already zero); ticket closed (removed from tickets.md), NOT parked (operator: mitigated)" >> "$notes_file"
        n_mitigated=$((n_mitigated+1)); acted=1
        govern::log "apply-answers: #$tk answered mitigated → closing as accepted-current-state (removed from tickets.md, not parked); escalation resolved"
      else
        # Ticket block already gone from tickets.md (e.g. resolved elsewhere) — still close the escalation.
        resolved_csv+="$tk,"; printf '%s\t%s\n' "$tk" "resolved — mitigated; no live ticket block in tickets.md (already removed); escalation closed (operator: mitigated)" >> "$notes_file"
        n_mitigated=$((n_mitigated+1)); acted=1
        govern::log "apply-answers: #$tk answered mitigated but no tickets.md block found — closing escalation only"
      fi
      ;;
    keep-open|"")
      : ;;  # operator wrote something but not a terminal disposition → leave open
  esac
done < <(printf '%s' "$entries" | jq -c '.[]')

if [[ "$acted" -eq 0 ]]; then
  rm -f "$notes_file"
  # #3: still regenerate pending-escalations.json (open entries may exist that just aren't yet
  # actionable) so a stale snapshot is reconciled against escalations.md even on this no-op path.
  "$DIR/escalations-emit-pending.sh" >/dev/null 2>&1 || true
  echo "no answered escalations with an actionable disposition — nothing to apply"
  exit 0
fi

# 3. Rewrite escalations.md: move every resolved `### #N` from "## Open" to "## Resolved",
#    appending the dated resolution note. Relies on Open preceding Resolved (the file format).
tmp="$(mktemp)"
awk -v rset="$resolved_csv" -v date="$DATE" -v notesf="$notes_file" '
  BEGIN{
    while((getline line < notesf) > 0){
      tabp=index(line,"\t"); if(tabp>0){ k=substr(line,1,tabp-1); v=substr(line,tabp+1); note[k]=v }
    }
    in_open=0; cap=0; cur=""; ncap=0
  }
  function emit_captured(){
    for(i=1;i<=ncap;i++){ nn=cap_ord[i]; t=cap_text[nn]; sub(/\n+$/,"\n",t); printf "%s", t; if(note[nn]!="") printf "- **Resolved:** %s — %s\n", date, note[nn]; print "" }
  }
  /^## Open/     { in_open=1; print; next }
  /^## Resolved/ { cap=0; in_open=0; print; emit_captured(); next }
  /^## /         { cap=0; in_open=0; print; next }
  {
    if(in_open && $0 ~ /^### +#[0-9]+/){
      nn=$0; sub(/^### +#/,"",nn); sub(/[^0-9].*/,"",nn)
      if(index(rset, "," nn ",") > 0){
        cap=1; cur=nn; cap_ord[++ncap]=nn
        cap_text[nn]=$0 " — ANSWERED " date "\n"
        next
      } else { cap=0; print; next }
    }
    if(cap){ cap_text[cur]=cap_text[cur] $0 "\n"; next }
    print
  }
' "$ESCALATIONS_FILE" > "$tmp" && mv "$tmp" "$ESCALATIONS_FILE"
rm -f "$notes_file"

# 4. Refresh pending-escalations.json so it no longer lists what we just closed.
"$DIR/escalations-emit-pending.sh" >/dev/null 2>&1 || true

# 5. Commit the result in the dir holding tickets.md (the main checkout in real use), the same
#    place + style govern-bookkeep.sh commits. Guarded push so local main stays == origin/main —
#    the same invariant govern-bookkeep.sh / preflight-main.sh rely on (a concurrent operator
#    session commits meta files to the SAME main, so the harness must keep them in sync). The push
#    is plain ff-only (never forced) and is skipped with no remote (local-only / test repo) and
#    under GOVERN_NO_PUSH=1.
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"   # '|| true' → "" if dir missing
govern::assert_commit_dir "$commit_dir"   # fail closed if the queue dir is missing (#28)
( cd "$commit_dir"
  git add -- "$TICKETS_FILE" "$TICKETS_PARKED_FILE" "$ESCALATIONS_FILE" "$PREFERENCES_FILE" 2>/dev/null || true
  git commit -q -m "docs(governor): apply escalation answers (un-park ${n_unpark}, defer ${n_defer}, mitigated ${n_mitigated}, rules ${n_rule})" || true
  if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
    git push origin HEAD:main >/dev/null 2>&1 \
      || govern::log "apply-answers: push to origin/main failed — local main now ahead; run 'git push' before the next harness ticket"
  fi
)
echo "applied escalation answers: un-parked $n_unpark, deferred $n_defer, mitigated $n_mitigated, rules added $n_rule"
