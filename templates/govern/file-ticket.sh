#!/usr/bin/env bash
# Append ONE ticket to tickets.md with a collision-safe number (#73) AND persist it atomically —
# commit + CAS-push to origin/main under the SAME bookkeep lock the governor's govern-bookkeep uses
# (#240). The number comes from the LIVE max via govern::next_ticket_number — max(tickets.md's
# highest `## #N`, governor/.ticket-seq) + 1, allocated under the bookkeep lock and persisted to
# .ticket-seq — so a manual filing can never silently reuse a number a concurrent session (or the
# governor) already took. This is THE supported manual-filing path: never hand-append `## #N` with a
# guessed/hardcoded number, and never let two sessions append to tickets.md unserialized.
#
# #240 — atomic persist: the append used to be left UNCOMMITTED for the caller to stage, which made
# it trivial to lose. While a governor run is active, a concurrent driver's bookkeep rewrites and
# pushes tickets.md on its OWN base; an uncommitted manual append was silently clobbered by that
# rewrite. Now file-ticket.sh holds the bookkeep lock for the whole allocate→append→commit→push,
# syncs onto the freshest origin/main before appending, and CAS-pushes its append-only commit with
# rebase-retry — exactly like bookkeep — so the filed ticket is published before the lock is released
# and can never be clobbered.
#
# Usage:
#   scripts/govern/file-ticket.sh "Short title" [Severity] < body.md
#   printf 'Where: ...\nObserved: ...\nDone when: ...\n' | scripts/govern/file-ticket.sh "Title" Low
#
# Prints the allocated ticket number to stdout. Commits tickets.md + governor/.ticket-seq and pushes
# to origin/main by default. Set GOVERN_FILE_TICKET_NO_COMMIT=1 to revert to the legacy append-only
# behavior (leaves the append uncommitted for the caller to stage inside a larger filing commit) —
# but be aware that path is the #240 race and must only be used when no governor run is active.
# Honors GOVERN_NO_PUSH=1 (commit locally, skip the push) and no-ops the commit entirely outside a
# git repo (tests / offline), in which case the append is left on disk like the legacy path.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

title="${1:?ticket title required (arg 1)}"
sev="${2:-Medium}"
body="$(cat)"
[[ -n "${body//[[:space:]]/}" ]] || govern::die "ticket body required on stdin"

commit_dir="$(cd "$(dirname "$TICKETS_FILE")" && pwd)"
SEQ_FILE="${GOVERN_TICKET_SEQ_FILE:-$GOVERNOR_DIR/.ticket-seq}"
BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"

if [[ "${GOVERN_FILE_TICKET_NO_COMMIT:-0}" == "1" ]]; then
  # Legacy append-only path (explicit opt-in). Still routes numbering through the shared allocator
  # (which takes the bookkeep lock itself) so the number stays collision-safe; just leaves the
  # append uncommitted for the caller to stage. Prefer the default atomic path while a run is active.
  n="$(govern::next_ticket_number "$TICKETS_FILE")"
  printf '\n## #%s — %s\n\n**Severity:** %s\n\n%s\n\n---\n' "$n" "$title" "$sev" "$body" >> "$TICKETS_FILE"
  echo "$n"
  exit 0
fi

# Hold the bookkeep lock across the ENTIRE allocate→append→commit→push so a concurrent driver's
# bookkeep can't read tickets.md on a stale base and clobber our append (#240). mkdir-mutex; reclaim
# a crashed holder's lock after 5min. Non-fatal if busy >60s — proceed degraded, same as bookkeep.
govern::lock_acquire "$BK_LOCK" 60 300 || govern::log "file-ticket: bookkeep lock busy >60s — proceeding (degraded)"
trap 'govern::lock_release "$BK_LOCK"' EXIT

# Informational: a live governor run holds the run lock. We commit+push atomically under the
# bookkeep lock, so the filing is SAFE — but surface it so the operator knows a driver is active.
RUN_LOCK="${GOVERN_LOCK:-$GOVERNOR_DIR/.govern.lock}"
if [[ -d "$RUN_LOCK" ]]; then
  _hpid="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$RUN_LOCK/holder" 2>/dev/null || true)"
  if [[ -n "$_hpid" ]] && kill -0 "$_hpid" 2>/dev/null; then
    govern::log "file-ticket: a live governor run holds $RUN_LOCK (pid $_hpid) — filing under the bookkeep lock and committing+pushing atomically so the new ticket survives its bookkeep (#240)"
  fi
fi

# Pre-edit sync: rebase local main onto origin/main BEFORE appending so the new block is computed
# against the FRESHEST origin/main and the CAS-push below replays cleanly (mirrors bookkeep step 0).
# Guarded + non-fatal: skipped in a remoteless test repo and under GOVERN_NO_PUSH=1.
if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git -C "$commit_dir" remote get-url origin >/dev/null 2>&1; then
  git -C "$commit_dir" pull --ff-only origin main >/dev/null 2>&1 \
    || git -C "$commit_dir" pull --rebase origin main >/dev/null 2>&1 \
    || { git -C "$commit_dir" rebase --abort >/dev/null 2>&1 || true
         govern::log "file-ticket: pre-edit ff-pull AND rebase-pull failed — local main diverged from origin/main; reconcile ('git pull --rebase origin main && git push') before filing"; }
fi

# Allocate the next number under the already-held lock (the mkdir mutex is NOT reentrant, so tell the
# allocator to skip re-acquiring it), then append the block.
n="$(GOVERN_BOOKKEEP_LOCK_HELD=1 govern::next_ticket_number "$TICKETS_FILE")"
printf '\n## #%s — %s\n\n**Severity:** %s\n\n%s\n\n---\n' "$n" "$title" "$sev" "$body" >> "$TICKETS_FILE"

# Commit tickets.md + .ticket-seq and CAS-push to origin/main with rebase-retry, so the filed ticket
# can never be left uncommitted (and thus clobbered by a concurrent bookkeep). Mirrors bookkeep's
# step-4/5. pathspec-scoped commit — never sweeps up unrelated staged changes. Guarded + non-fatal:
# no-op outside a git repo (tests/offline; append stays on disk), commits locally but skips the push
# under GOVERN_NO_PUSH=1 / no origin.
if git -C "$commit_dir" rev-parse --git-dir >/dev/null 2>&1; then
  ( cd "$commit_dir"
    git add -- "$(basename "$TICKETS_FILE")" >/dev/null 2>&1 || true
    git add -- "$SEQ_FILE" >/dev/null 2>&1 || true   # absolute path; no-op if outside the repo (tests)
    git commit -q -m "docs(tickets): file #$n — $title" -- "$(basename "$TICKETS_FILE")" "$SEQ_FILE" >/dev/null 2>&1 || true
    if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
      # CAS-with-retry: if origin advanced under us (a concurrent driver's bookkeep / another filing
      # pushed), rebase our append-only commit onto the new origin/main and retry — a LOOP, not a
      # single try, so two+ racers can't exhaust one retry and leave our append unpushed. The append
      # is at end-of-file and the seq bump is monotonic, so the rebase replays cleanly. NEVER
      # force-push; exhausting all retries logs one clear reconcile message.
      pushed=0
      for _attempt in 1 2 3 4 5; do
        if git push origin HEAD:main >/dev/null 2>&1; then pushed=1; break; fi
        git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
      done
      if [[ "$pushed" != "1" ]]; then
        govern::log "file-ticket #$n: push to origin/main failed after 5 rebase-retries — local main now ahead/diverged; reconcile ('git pull --rebase origin main && git push'). The ticket IS committed locally, so it is not lost."
      fi
    fi )
fi

echo "$n"
