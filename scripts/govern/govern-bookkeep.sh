#!/usr/bin/env bash
# Deterministically apply a resolved worker's report (read from stdin) for ticket N:
#   delete the ## #N block, append newTickets (per-queue numbering = this file's max+1),
#   apply a ROOT-level lessonPatch (sub-repo CLAUDE.md lessons ride in the worker's own PR),
#   commit. No Claude context involved. Usage:  printf '%s' "$report" | govern-bookkeep.sh <N>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
N="${1:?ticket number required}"
report="$(cat)"
# '|| true' so a MISSING queue dir yields "" (not an unreliable set -e abort with a confusing cd error);
# the explicit assert below is the deterministic fail-closed guard (#28).
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"   # the queue/ folder (holds tickets.md)
govern::assert_commit_dir "$commit_dir"                  # fail closed if the queue dir is missing (#28)
patched=""

# Serialize the whole tickets.md read-modify-write + commit. Two concurrent govern drivers
# (parallel sessions on disjoint tickets, #41) would otherwise race the mktemp→mv (lost
# block-delete) and the git index. mkdir-mutex; reclaim if a crashed holder left it >5min.
BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
govern::lock_acquire "$BK_LOCK" 60 300 || govern::log "bookkeep lock busy >60s — proceeding (degraded)"
trap 'govern::lock_release "$BK_LOCK"' EXIT

# 0. Sync the local checkout's main to origin/main BEFORE editing tickets.md, so the block-delete
# (and any newTickets/lesson appends) are computed against the FRESHEST origin/main — never a stale
# base that still carries a block a CONCURRENT driver already deleted+pushed. #108: with parallel
# drivers sharing one origin (GOVERN_ALLOW_CONCURRENT=1, #41) the bookkeep lock (BK_LOCK) serializes
# writes WITHIN one checkout but does NOT serialize the cross-checkout git push/pull; a bookkeep that
# committed a stale tickets.md and pushed could resurrect an already-resolved block on origin/main
# (the other driver then re-selects it). The local-FS claim/bookkeep locks can't see another
# checkout's push — only an origin sync can. Guarded + non-fatal: skipped without an origin
# (local-only / test repo) and under GOVERN_NO_PUSH=1. ff-pull is the happy path; if local main
# carries unpushed append-only bookkeep/filing commits (diverged), rebase them rather than give up.
if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git -C "$commit_dir" remote get-url origin >/dev/null 2>&1; then
  git -C "$commit_dir" pull --ff-only origin main >/dev/null 2>&1 \
    || git -C "$commit_dir" pull --rebase origin main >/dev/null 2>&1 \
    || { git -C "$commit_dir" rebase --abort >/dev/null 2>&1 || true
         govern::log "bookkeep #$N: pre-edit ff-pull AND rebase-pull failed — local main diverged from origin/main; reconcile manually ('git pull --rebase origin main && git push') before the next ticket"; }
fi

# 0b. Capture the ticket TITLE before the block is deleted (#252) — the promoted validation
# summary file is named ticket-<N>-<slug>.md, and the slug is derived from this title. Read it
# now while the `## #N — <title>` heading still exists; an empty title falls back to "validation".
# Portable sed (BSD/macOS awk lacks 3-arg match capture groups): strip the `## #N — ` prefix.
ticket_title="$(grep -m1 -E "^##[[:space:]]+#$N([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null \
  | sed -E "s/^##[[:space:]]+#$N[[:space:]]*(—|-)?[[:space:]]*//" || true)"

# 0c. Capture the ticket's `Flow:` field BEFORE the block is deleted (mirrors the title pre-capture) —
# a flow-registry validation stamps validation/flows.md on resolve, and the flow ids live in the block
# that step 1 deletes. Empty for a non-flow ticket (the stamp step then no-ops). Guarded on the parser.
ticket_flow=""
ticket_flow_op="validate"
if command -v govern::ticket_flow_ids >/dev/null 2>&1; then
  ticket_flow="$(govern::ticket_flow_ids "$N" "$TICKETS_FILE" 2>/dev/null || true)"
  # A KILL removal ticket (Flow-op: remove) TOMBSTONES its flow(s) on resolve instead of stamping a
  # verdict — captured now, before step 1 deletes the block. Default "validate" for a normal flow ticket.
  command -v govern::ticket_flow_op >/dev/null 2>&1 \
    && ticket_flow_op="$(govern::ticket_flow_op "$N" "$TICKETS_FILE" 2>/dev/null || echo validate)"
fi

# 1. Delete the ## #N block via the shared parser (govern::ticket_block_delete): boundary is
# the next `^##[[:space:]]+#<digits>` heading (or EOF), consuming the block's trailing `---`
# separator so a doubled separator is never left behind AND a bare `---` inside the body no
# longer terminates the delete early (leaving orphaned body lines under the next heading).
# CAS check (#108): after the origin sync above, verify the block is still present. If a
# concurrent driver already resolved+deleted it, the delete is a harmless no-op — but log it
# so a double-processed ticket is VISIBLE here rather than silently re-bookkept.
if ! grep -qE "^##[[:space:]]+#$N([^0-9]|\$)" "$TICKETS_FILE"; then
  govern::log "bookkeep #$N: block already absent from tickets.md after origin sync (resolved by a concurrent driver?) — delete is a no-op (#108)"
fi
govern::ticket_block_delete "$N" "$TICKETS_FILE"

# Collapse the blank-line residue the block-delete leaves behind. The awk above removes the
# heading-through-`---`, but the blank line that PRECEDED the heading and the one that FOLLOWED
# the `---` are not part of the grab, so each resolved ticket leaves ~1 stray blank line. Over the
# file's life (hundreds of tickets resolved + deleted) these accumulate into large whitespace voids.
# `cat -s` squeezes any run of consecutive blank lines back down to one — idempotent, and it also
# compacts already-accumulated gaps. (Legitimate single blanks between blocks are unaffected.)
tmp="$(mktemp)"; cat -s "$TICKETS_FILE" > "$tmp"; mv "$tmp" "$TICKETS_FILE"

# 2. Append newTickets. Number each via the shared monotonic allocator (#54, #73):
# govern::next_ticket_number returns max(persisted high-water mark in governor/.ticket-seq,
# current tickets.md max) + 1 and bumps the seq, so deleting the highest `## #N` then filing leaves
# a GAP instead of reclaiming the number, AND a number is never shared with a manual filing that
# routes through the same helper. We already hold the bookkeep lock (BK_LOCK above), so tell the
# helper to skip re-acquiring it — the mkdir mutex is not reentrant. The seq file is git-added below.
SEQ_FILE="${GOVERN_TICKET_SEQ_FILE:-$GOVERNOR_DIR/.ticket-seq}"
count="$(printf '%s' "$report" | jq '.newTickets | length' 2>/dev/null || echo 0)"
i=0
while [[ "$i" -lt "$count" ]]; do
  maxn="$(GOVERN_BOOKKEEP_LOCK_HELD=1 govern::next_ticket_number "$TICKETS_FILE")"
  title="$(printf '%s' "$report" | jq -r ".newTickets[$i].title")"
  sev="$(printf '%s' "$report" | jq -r ".newTickets[$i].severity // \"Medium\"")"
  body="$(printf '%s' "$report" | jq -r ".newTickets[$i].body")"
  printf '\n## #%s — %s\n\n**Severity:** %s\n\n%s\n\n---\n' "$maxn" "$title" "$sev" "$body" >> "$TICKETS_FILE"
  i=$((i+1))
done

# 3. Root-level lessonPatch (only files at the meta-repo ROOT, e.g. CLAUDE.md; never a sub-repo's own
# git tree, and never the queue/ folder — the lesson file sits beside it at the root).
lp_file="$(printf '%s' "$report" | jq -r '.lessonPatch.file // empty' 2>/dev/null || true)"
if [[ -n "$lp_file" && "$lp_file" != */* ]]; then   # root-level file only (no slash)
  meta_root="$(govern::meta_root)"   # repo root — computed lazily, ONLY when a root lesson exists, and
                                      # inside the BK_LOCK critical section (never a pre-lock git call).
  target="$meta_root/$lp_file"
  if [[ -f "$target" ]]; then
    anchor="$(printf '%s' "$report" | jq -r '.lessonPatch.anchor // empty')"
    text="$(printf '%s' "$report" | jq -r '.lessonPatch.text')"
    if [[ -n "$anchor" ]] && grep -qF "$anchor" "$target"; then
      # Insert the (possibly multi-line) lesson AFTER the anchor line. Pass the text via a
      # FILE read with getline — NEVER `awk -v t="$text"`: awk's -v cannot hold literal
      # newlines, so multi-line lesson text dies with "awk: newline in string" and the patch
      # silently fails (the resolve then aborts before its commit under set -e).
      tmpf="$(mktemp)"; tf="$(mktemp)"; printf '%s\n' "$text" > "$tf"
      awk -v a="$anchor" -v tf="$tf" '
        index($0,a) && !done { print; print ""; while ((getline line < tf) > 0) print line; close(tf); done=1; next }
        { print }
      ' "$target" > "$tmpf"
      mv "$tmpf" "$target"; rm -f "$tf"
    else
      printf '\n%s\n' "$text" >> "$target"
    fi
    patched="$target"   # ABSOLUTE path — staged from cd commit_dir (the queue/ folder), so a bare
                        # root-relative name would miss it; absolute resolves from anywhere in the repo.
  fi
fi

# 3b. PROMOTE a passing autonomous validation into the committed sink (#252). The worker only
# writes the gitignored raw artifacts under the machine-local investigations sink; nothing else
# populates the git-tracked `.claude/context/validation/` summary sink that founder-os context cites
# as proof. When the report carries a REAL live-test pass (validation.ranLiveTest=true + non-empty
# evidence — already enforced upstream before this resolved bookkeep runs), auto-write a durable
# `ticket-<N>-<slug>.md` summary so the committed sink is never empty for a passing autonomous
# validation. A pre-existing (hand-written, richer) summary is NEVER clobbered — we only create the
# file when absent; either way we record the pointer (step 6).
vdoc=""; vdoc_rel=""
ranlive="$(printf '%s' "$report" | jq -r '.validation.ranLiveTest // false' 2>/dev/null || echo false)"
evidence="$(printf '%s' "$report" | jq -r '.validation.evidence // ""' 2>/dev/null || true)"
if [[ "$ranlive" == "true" && -n "$evidence" ]]; then
  meta_root="$(govern::meta_root)"
  vdir="$meta_root/.claude/context/validation"
  # slugify the title: lowercase, non-alphanumerics → '-', collapse + trim, cap to 60 chars.
  slug="$(printf '%s' "${ticket_title:-validation}" \
    | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//' | cut -c1-60)"
  [[ -z "$slug" ]] && slug="validation"
  vdoc="$vdir/ticket-$N-$slug.md"
  vdoc_rel=".claude/context/validation/ticket-$N-$slug.md"
  mkdir -p "$vdir"
  if [[ -e "$vdoc" ]]; then
    govern::log "bookkeep #$N: validation summary $vdoc_rel already exists — keeping it (not overwriting a hand-authored record); pointer still recorded (#252)"
  else
    pr_lines="$(printf '%s' "$report" | jq -r '
      ([ .pr ] + (.prs // [])) | map(select(. != null and ((.repo // "") != "")))
      | map("- \(.repo)#\(.number)" + (if (.url // "") != "" then " — \(.url)" else "" end)) | .[]' 2>/dev/null || true)"
    {
      printf '# Ticket #%s — %s — VALIDATION RESULT\n\n' "$N" "${ticket_title:-validation}"
      printf '**Auto-promoted by the governor on resolve (run %s).** This is the durable, git-tracked\n' "$(basename "${GOVERN_RUN_DIR:-manual}")"
      printf 'evidence summary for an autonomously-resolved validation ticket — the committed sink that\n'
      printf 'founder-os context (`features.md` / `direction.md` / `product.md`) may cite as proof. The\n'
      printf 'raw artifacts (screenshots, ground-truth, `report.json`, `worker.jsonl`) live in the\n'
      printf '**gitignored** machine-local investigations sink on the machine that ran the test; this\n'
      printf 'file is the durable record that survives that machine-local sink.\n\n'
      printf '## PR(s)\n%s\n\n' "${pr_lines:-- (none recorded)}"
      printf '## Verdict / evidence (from the worker'"'"'s `validation.evidence`)\n\n%s\n\n' "$evidence"
      printf -- '---\n> Auto-generated by `govern-bookkeep.sh` (#252) so the committed `.claude/context/validation/`\n'
      printf '> sink is never empty for a passing autonomous validation. A human may expand this with the\n'
      printf '> full PASS/FAIL table from the raw investigations sink; the pointer in the ticket-history\n'
      printf '> file keeps the evidence path greppable after the ticket block is deleted.\n'
    } > "$vdoc"
    govern::log "bookkeep #$N: promoted validation evidence → $vdoc_rel (committed sink) (#252)"
  fi
fi

# 4. Commit (in the dir holding tickets.md — the main checkout in real use), then publish.
# #129: a multi-repo ticket reports several PRs (.pr + .prs[]); list them all in the commit message
# so the resolve commit records every PR, not just the first.
pr="$(printf '%s' "$report" | jq -r '
  ([ .pr ] + (.prs // []))
  | map(select(. != null and ((.repo // "") != "")))
  | (map("\(.repo)#\(.number)") | join(", "))
  | if . == "" then "?#0" else . end' 2>/dev/null || echo '?#0')"
( cd "$commit_dir"
  git add "$(basename "$TICKETS_FILE")" ${patched:+"$patched"}
  git add "$SEQ_FILE" 2>/dev/null || true  # #54 high-water mark (absolute path; no-op if outside repo, e.g. tests)
  [[ -n "$vdoc" ]] && git add "$vdoc" 2>/dev/null || true  # #252 promoted validation summary (absolute path)
  git commit -q -m "docs(tickets): resolve #$N ($pr)" || true

  # Publish the bookkeep commit as a CAS-with-retry loop so a concurrent driver sharing one
  # origin/main can't resurrect this delete. If the push is rejected (origin advanced under us —
  # another driver pushed its own tickets.md edit), rebase our append-only commit onto the new
  # origin/main and retry. #108: a LOOP (not a single retry) so two+ concurrent drivers racing the
  # same origin/main can't exhaust one retry and leave our delete unpushed (the resolved block then
  # resurfaces on origin → re-selected). The rebase replays our delete diff cleanly: the per-ticket
  # claim lock (#41) guarantees a concurrent push is a DIFFERENT ticket's block, so there's no
  # overlap to conflict on. Guarded + non-fatal: a pure no-op without an origin (local-only / test
  # repo) or under GOVERN_NO_PUSH=1; exhausting all retries logs one clear reconcile message.
  if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
    pushed=0
    for _attempt in 1 2 3 4 5; do
      if git push origin HEAD:main >/dev/null 2>&1; then pushed=1; break; fi
      git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
    done
    if [[ "$pushed" != "1" ]]; then
      govern::log "bookkeep #$N: push to origin/main failed after 5 rebase-retries — local main now ahead/diverged; reconcile ('git pull --rebase origin main && git push') before the next ticket."
    fi
  fi
)

# 5b. STAMP THE FLOW REGISTRY on resolve (validations Phase 2). A flow-registry validation ticket
# (carried a `Flow:` field, pre-captured in step 0c) records its verdict into validation/flows.md:
# Status per Kind (correctness→PASS, effectiveness→EFFECTIVE/MEASURING), reachable SHA pins, Env,
# measured, PR-URL linkage, and a promoted evidence summary — all via govern::cas_edit under the
# bookkeep lock we already hold (GOVERN_BOOKKEEP_LOCK_HELD=1, since the mkdir mutex is not reentrant).
# No-op for a non-flow ticket. A PII hit in the promoted summary returns 2 (logged; the resolve
# itself already committed — the operator scrubs + re-stamps). Guarded on the parser + a jq report.
if [[ -n "$ticket_flow" ]] && command -v govern::flows_stamp_from_report >/dev/null 2>&1; then
  if [[ "$ticket_flow_op" == "remove" ]]; then
    # KILL loop completion (validations Phase 5): the removal ticket's PR deletes the feature; on resolve
    # we TOMBSTONE the flow (Status TOMBSTONED, history preserved) rather than stamping a fresh verdict.
    if command -v govern::flows_tombstone >/dev/null 2>&1; then
      GOVERN_BOOKKEEP_LOCK_HELD=1 govern::flows_tombstone "$ticket_flow" "$(govern::meta_root)" \
        || govern::log "bookkeep #$N: flow-registry tombstone returned non-zero (flows: $ticket_flow)"
    fi
  else
    GOVERN_BOOKKEEP_LOCK_HELD=1 govern::flows_stamp_from_report "$report" resolve "$ticket_flow" "$(govern::meta_root)" \
      || govern::log "bookkeep #$N: flow-registry stamp returned non-zero (flows: $ticket_flow) — check for a PII-park or unreachable-SHA warning above"
  fi
fi

# 6. POINTER ON RESOLVE (#252). The ticket block is now gone; reconstructing the evidence path from
# the slug later is fragile. Persist an explicit, greppable pointer to the cross-run history file
# recording the PR(s) AND the promoted validation-summary path, so a resolved validation ticket keeps
# a durable, machine-readable link to its evidence even though the block was deleted. Append-only,
# best-effort (gitignored runtime state); honors GOVERN_HISTORY_FILE so tests can point it elsewhere.
# Only emitted when a validation summary was involved — ordinary code tickets already have their PR#
# in the resolve-commit message (greppable via `git log`).
if [[ -n "$vdoc_rel" ]]; then
  HISTORY_FILE="${GOVERN_HISTORY_FILE:-$GOVERNOR_DIR/ticket-history.jsonl}"
  pr_json="$(printf '%s' "$report" | jq -c '([ .pr ] + (.prs // [])) | map(select(. != null and ((.repo // "") != "")))' 2>/dev/null || echo '[]')"
  printf '{"ticket":%s,"status":"resolved","kind":"validation-evidence","prs":%s,"validationDoc":%s,"evidence":%s,"ts":%s}\n' \
    "$N" "$pr_json" "$(jq -Rn --arg s "$vdoc_rel" '$s')" "$(jq -Rn --arg s "$evidence" '$s')" "$(date +%s)" \
    >> "$HISTORY_FILE" 2>/dev/null \
    && govern::log "bookkeep #$N: recorded validation-evidence pointer → $vdoc_rel in $(basename "$HISTORY_FILE") (#252)" || true
fi

echo "bookkept #$N: block deleted; +$count ticket(s); lesson=${patched:-none}; validationDoc=${vdoc_rel:-none}; pr=$pr"
