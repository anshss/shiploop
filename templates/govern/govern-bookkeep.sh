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
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" && pwd)"
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

# 1. Delete the ## #N block (heading through its trailing ---). CAS check (#108): after the origin
# sync above, verify the block is still present. If a concurrent driver already resolved+deleted it,
# the awk delete below is a harmless no-op — but log it so a double-processed ticket is VISIBLE here
# rather than silently re-bookkept.
if ! grep -qE "^##[[:space:]]+#$N([^0-9]|\$)" "$TICKETS_FILE"; then
  govern::log "bookkeep #$N: block already absent from tickets.md after origin sync (resolved by a concurrent driver?) — delete is a no-op (#108)"
fi
tmp="$(mktemp)"
awk -v n="$N" '
  $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" { grab=1 }
  grab && /^---[[:space:]]*$/ { grab=0; next }
  grab { next }
  { print }
' "$TICKETS_FILE" > "$tmp"
mv "$tmp" "$TICKETS_FILE"

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

# 3. Root-level lessonPatch (only files inside commit_dir; never a sub-repo's own git tree).
lp_file="$(printf '%s' "$report" | jq -r '.lessonPatch.file // empty' 2>/dev/null || true)"
if [[ -n "$lp_file" && "$lp_file" != */* ]]; then   # root-level file only (no slash)
  target="$commit_dir/$lp_file"
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
    patched="$lp_file"
  fi
fi

# 4. Commit (in the dir holding tickets.md — the main checkout in real use), then publish.
pr="$(printf '%s' "$report" | jq -r '(.pr.repo // "?") + "#" + ((.pr.number // 0)|tostring)')"
( cd "$commit_dir"
  git add "$(basename "$TICKETS_FILE")" ${patched:+"$patched"}
  git add "$SEQ_FILE" 2>/dev/null || true  # #54 high-water mark (absolute path; no-op if outside repo, e.g. tests)
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
echo "bookkept #$N: block deleted; +$count ticket(s); lesson=${patched:-none}; pr=$pr"
