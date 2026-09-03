#!/usr/bin/env bash
# Deterministically apply a resolved worker's report (read from stdin) for ticket N:
#   delete the ## #N block, append newTickets (per-queue numbering = this file's max+1),
#   apply a ROOT-level lessonPatch (sub-repo CLAUDE.md lessons ride in the worker's own PR),
#   commit. No Claude context involved. Usage:  printf '%s' "$report" | govern-bookkeep.sh <N>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
# ── --enforce-budgets: run the context ratchet controls OUTSIDE a dispatch ──────────────────────
# The lesson char cap, the CLAUDE.md total budget and the learnings TTL used to fire ONLY inside a
# per-ticket bookkeep. That coupled context hygiene to dispatch volume, so a fleet that stops
# dispatching stops enforcing: measured 2026-09-03, one fleet's root CLAUDE.md sat at 24,366 chars
# against a 14,000 budget (74% over, re-sent on every turn of ~395 interactive sessions) purely
# because no bookkeep had run since August. Budgets are a property of the FILES, not of the run.
#
# Usage:  govern-bookkeep.sh --enforce-budgets [--dry]
# Exit:   0 = under budget after the pass · 3 = still over (doctor gates on this) · 1 = usage error
#
# NOTHING IS EVER DELETED. Every demotion moves the full text into CLAUDE-APPENDIX.md, which is a
# real file a human reviews, not a bin. Content above the first flush-left `## ` heading (the
# preamble: the file's own framing rules) is never touched. Edits are left UNCOMMITTED on purpose:
# what a session is charged every turn is the operator's call to land, not a script's.
if [[ "${1:-}" == "--enforce-budgets" ]]; then
  shift
  EB_DRY=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry|--dry-run) EB_DRY=1;;
      *) govern::die "usage: govern-bookkeep.sh --enforce-budgets [--dry]";;
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
  if [[ "$EB_DRY" -eq 1 ]]; then eb_verb="would demote"; eb_verb2="would archive"; eb_verb3="would move"
  else eb_verb="demoted"; eb_verb2="archived"; eb_verb3="moved"; fi

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
  if [[ ! -f "$eb_appendix" ]]; then
    govern::log "budgets: $eb_claude is $(eb_size "$eb_claude") chars against a $eb_budget budget, but CLAUDE-APPENDIX.md is absent — there is nowhere to demote to. Create it, then re-run."
    [[ "$(eb_size "$eb_claude")" -gt "$eb_budget" ]] && exit 3
    exit 0
  fi

  # 1. LESSON CHAR CAP. A single section past the cap is a permanent per-turn tax paid by every
  #    session. Demote it whole; the appendix keeps every word.
  while IFS=$'\t' read -r sz head; do
    [[ "$sz" =~ ^[0-9]+$ ]] || continue
    [[ "$sz" -gt "$eb_cap" ]] || continue
    if eb_demote "$eb_claude" "$head"; then
      eb_moved=$((eb_moved+1))
      govern::log "budgets: $eb_verb \"$head\" ($sz chars > GOVERN_LESSON_MAX_CHARS=$eb_cap) → CLAUDE-APPENDIX.md"
    fi
  done < <(eb_sections "$eb_claude" | sort -k1,1nr)

  # 2. TOTAL BUDGET. Still over after the cap pass: demote whole sections, LARGEST FIRST, until the
  #    file is under budget. Largest-first is the only ordering that is both deterministic and
  #    monotone in what it buys per demotion.
  while [[ "$(eb_size "$eb_claude")" -gt "$eb_budget" ]]; do
    eb_pick="$(eb_sections "$eb_claude" | sort -k1,1nr | head -1 | cut -f2-)"
    [[ -n "$eb_pick" ]] || break
    eb_demote "$eb_claude" "$eb_pick" || break
    eb_moved=$((eb_moved+1))
    govern::log "budgets: $eb_verb \"$eb_pick\" → CLAUDE-APPENDIX.md (CLAUDE.md over the $eb_budget-char budget)"
    [[ "$EB_DRY" -eq 1 ]] && break   # a dry pass cannot shrink the file, so it would loop forever
  done

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
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)"
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
  govern::log "budgets: CLAUDE.md $eb_final/$eb_budget chars · $eb_moved entr(ies) $eb_verb3 to CLAUDE-APPENDIX.md"
  if [[ "$eb_final" -gt "$eb_budget" ]]; then
    govern::log "budgets: STILL OVER by $(( eb_final - eb_budget )) chars — nothing left to demote automatically; the remaining weight is in the preamble or in sections the appendix already holds. Cut it by hand."
    exit 3
  fi
  [[ "$EB_DRY" -eq 1 ]] || govern::log "budgets: edits left UNCOMMITTED in $eb_root — review and commit them yourself"
  exit 0
fi
N="${1:?ticket number required}"
report="$(cat)"
# '|| true' so a MISSING queue dir yields "" (not an unreliable set -e abort with a confusing cd error);
# the explicit assert below is the deterministic fail-closed guard (#28).
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" 2>/dev/null && pwd || true)"   # the queue/ folder (holds tickets.md)
govern::assert_commit_dir "$commit_dir"                  # fail closed if the queue dir is missing (#28)
declare -a patched_files=()   # every extra file (beyond TICKETS_FILE/SEQ_FILE/vdoc) to `git add` below —
                              # holds the root lesson target AND, on an overflow split, CLAUDE-APPENDIX.md too.

# ── Always-on context ratchet controls (#87) ────────────────────────────────────────────────────
# Promotion into root CLAUDE.md is AUTOMATIC; removal is a human noticing. That asymmetry is a
# ratchet: every individual promotion is defensible, and the aggregate is a permanent per-turn tax
# charged to every session forever. GOVERN_LESSON_MAX_CHARS (below) only caps how BIG one lesson may
# be and moves the overflow to the appendix — there is no admission test, no eviction, no expiry.
#
# THE BAR IS FREQUENCY x SEVERITY, NEVER FREQUENCY ALONE. A ~350-600 byte entry is ~90-150 tokens
# re-sent across ~30 turns ≈ 270-450 effective tokens per session, charged to EVERY session. If a hit
# averts a ~5-turn wrong path (~20K tokens) the break-even is a ~2.3% hit rate — about 1 session in 44.
# That per-hit figure is an ASSUMPTION, not a measurement, and it dominates the arithmetic, which is
# exactly why severity has to multiply in: a rare but irreversible rule still pays (e.g. a `gh pr edit
# --base` that reports success while changing nothing).
#
# BLOAT AND ROT ARE DIFFERENT PROBLEMS. Bloat is cost — placement fixes it. Rot is wrongness —
# placement does NOTHING for it. Demoting a wrong line to the appendix moves it from "injected always"
# to "retrieved unpredictably, reviewed never", which makes the appendix a rot reservoir. Rot has
# exactly three fixes: be right, supersede in place, delete. None of them is a move. COROLLARY: if
# something cannot be made self-correcting and does not clear the bar, DELETE it rather than demote it.
#
# The three gates below add admission + eviction. Each SHIPS INERT — the default is byte-for-byte
# today's behaviour — and each is reverted by a single env var:
#
#   GOVERN_LESSON_SINK=claude-md|appendix        (default claude-md = today)
#       `appendix` inverts the default sink: CLAUDE-APPENDIX.md becomes the DEFAULT target and an
#       always-on CLAUDE.md slot becomes opt-in, requiring an explicit CLAIM in the patch —
#       `lessonPatch.alwaysOn: true` plus a non-empty `.frequency` (how often this fires) and a
#       non-empty `.reversibility` (what it costs when missed). Both halves of frequency x severity.
#
#   GOVERN_LESSON_LADDER=0|1                     (default 0 = off)
#       Documented precedence, cheapest rung first:
#         guard (make it impossible) > lint/test (make it caught) > appendix (make it retrievable)
#         > always-on (make it re-sent every turn, forever).
#       A lesson may claim the always-on rung only if it DECLARES `lessonPatch.rung: "always-on"` AND
#       says why the cheaper rungs cannot cover it (`lessonPatch.rungWhyNot`). This is a gate on the
#       SHAPE of what was submitted — no model call, no judgement, no new `claude` invocation.
#
#   GOVERN_LESSON_EVICT=0|1                      (default 0 = off)
#       Forced eviction at budget: when the target is at/over GOVERN_LESSON_BUDGET_CHARS, a new
#       always-on line must NAME the entry it displaces (`lessonPatch.evicts`, matching exactly one
#       existing heading or rule line in the target). This is the load-bearing item — it converts
#       "is this useful?" (always yes -> ratchet) into "is this more useful than the weakest
#       incumbent?" (a comparison -> steady state). No name, or a name matching zero/many lines: the
#       lesson goes to the appendix instead of growing the always-on file.
#
#   GOVERN_LESSON_BUDGET_CHARS                   (default: $SHIPLOOP_CLAUDEMD_MAX_CHARS, else 14000)
#       The budget the eviction gate measures against — deliberately the SAME number the SessionStart
#       digest already warns on, so the warning and the gate can never disagree.

# Does this lessonPatch CLAIM an always-on slot? Both halves of the bar must be stated explicitly:
# frequency (how often it fires) AND reversibility (what it costs when missed). Returns 0 on a
# complete claim, 1 otherwise. Callers use it in a boolean context — no bare `[[ ]] &&` tail here.
govern_bk::claims_always_on() { # <report-json>
  local rpt="$1"
  local ao freq rev
  ao="$(printf '%s' "$rpt" | jq -r '.lessonPatch.alwaysOn // false' 2>/dev/null || echo false)"
  freq="$(printf '%s' "$rpt" | jq -r '.lessonPatch.frequency // ""' 2>/dev/null || true)"
  rev="$(printf '%s' "$rpt" | jq -r '.lessonPatch.reversibility // ""' 2>/dev/null || true)"
  if [[ "$ao" == "true" && -n "$freq" && -n "$rev" ]]; then return 0; fi
  return 1
}

# Ladder check: the patch must claim the TOP rung explicitly and justify skipping the cheaper ones.
# An absent/lower `rung` is not a failure of the lesson — it is a statement that a guard, a lint, or
# the appendix already covers it, which is precisely where it should go.
govern_bk::ladder_ok() { # <report-json>
  local rpt="$1"
  local rung why
  rung="$(printf '%s' "$rpt" | jq -r '.lessonPatch.rung // ""' 2>/dev/null || true)"
  why="$(printf '%s' "$rpt" | jq -r '.lessonPatch.rungWhyNot // ""' 2>/dev/null || true)"
  if [[ "$rung" == "always-on" && -n "$why" ]]; then return 0; fi
  return 1
}

# Remove the entry NAMED by <needle> from <file>. The needle is a literal substring and must match
# EXACTLY ONE line — zero matches means the worker named something that isn't there, many matches
# means it named something ambiguous; both are refusals, never a guess at which entry to delete.
#   * a HEADING match removes the heading through the line before the next heading of the same or a
#     shallower level (or EOF);
#   * a RULE/BULLET/paragraph match removes that line plus its INDENTED continuation lines (fenced
#     snippets under a bullet included), stopping at the next flush-left line.
# Blank lines inside the removed span are swallowed and a single separator blank is restored.
# Returns 0 only when exactly one entry was removed; the file is left byte-identical otherwise.
govern_bk::evict_entry() { # <file> <needle>
  local file="$1" needle="$2"
  local hits tmpf
  if [[ -z "$needle" || ! -f "$file" ]]; then return 1; fi
  hits="$(grep -cF -- "$needle" "$file" 2>/dev/null || true)"
  if [[ "$hits" != "1" ]]; then return 1; fi
  tmpf="$(mktemp)"
  if awk -v needle="$needle" '
      function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
      BEGIN { found = 0; removing = 0; lvl = 0; blank = 0 }
      {
        if (!found && index($0, needle)) {
          found = 1; removing = 1; blank = 0
          lvl = ($0 ~ /^#+[ \t]/) ? hlevel($0) : 0
          next
        }
        if (removing) {
          if ($0 ~ /^[ \t]*$/) { blank = 1; next }
          if (lvl > 0) {
            if (($0 ~ /^#+[ \t]/) && hlevel($0) <= lvl) { removing = 0 }
            else { blank = 0; next }
          } else {
            if ($0 ~ /^[ \t]/) { blank = 0; next }   # indented continuation of the evicted rule
            removing = 0
          }
          if (blank) print ""
          blank = 0
        }
        print
      }
      END { if (!found) exit 3 }
    ' "$file" > "$tmpf"; then
    mv "$tmpf" "$file"
    return 0
  fi
  rm -f "$tmpf"
  return 1
}

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
# #370: `-c rebase.autoStash=true` so a CO-TENANT session's unrelated dirty tracked files (e.g.
# .claude/context/** WIP) never block this rebase — git transiently stashes them, rebases, then
# restores them byte-identically. This does NOT mask a GENUINE content conflict (both sides edited
# tickets.md/escalations.md): that still fails the rebase and falls through to the reconcile-manually
# log line, unchanged.
# #377: the rebase runs through govern::pull_rebase_autostash so the OVERLAPPING-same-file case — origin
# advancing a govern SCRIPT a co-tenant is concurrently editing — can NEVER wedge the shared index. That
# case's autostash POP conflicts but git STILL exits 0 (only a warning), leaving unmerged index entries;
# the old `|| { rebase --abort; }` fallback never fired (rc 0) and every later git add/commit failed
# "unmerged files". The helper detects the rc-0-but-unmerged wedge and recovers (local main IS synced;
# co-tenant WIP parked in the preserved stash, never touched). A genuine conflict still returns 1 → log.
if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git -C "$commit_dir" remote get-url origin >/dev/null 2>&1; then
  git -C "$commit_dir" pull --ff-only origin main >/dev/null 2>&1 \
    || govern::pull_rebase_autostash "$commit_dir" \
    || govern::log "bookkeep #$N: pre-edit ff-pull AND rebase-pull failed — local main diverged from origin/main; reconcile manually ('git pull --rebase origin main && git push') before the next ticket"
fi

# 0b. Capture the ticket TITLE before the block is deleted (#252) — the promoted validation
# summary file is named ticket-<N>-<slug>.md, and the slug is derived from this title. Read it
# now while the `## #N — <title>` heading still exists; an empty title falls back to "validation".
# Portable sed (BSD/macOS awk lacks 3-arg match capture groups): strip the `## #N — ` prefix.
ticket_title="$(grep -m1 -E "^##[[:space:]]+#$N([^0-9]|\$)" "$TICKETS_FILE" 2>/dev/null \
  | sed -E "s/^##[[:space:]]+#$N[[:space:]]*(—|-)?[[:space:]]*//" || true)"

# 0c. Capture the ticket's `Flow:` field BEFORE the block is deleted (mirrors the title pre-capture) —
# a flow-registry validation stamps .claude/shiploop/validation/flows.md on resolve, and the flow ids live in the block
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
    insert_text="$text"   # what actually gets inserted into $target — overridden below on overflow

    # ── Placement gate (#83 Part 1) ─────────────────────────────────────────
    # A worker CLAIMS this lesson belongs at root (lessonPatch, not an in-PR sub-repo edit), but
    # worker-prompt.md's instruction to route sub-repo-scoped facts into the PR instead is text a
    # worker can get wrong — and it did, in measured practice (root CLAUDE.md growing monotonically
    # across fleets). Re-derive placement from the TEXT ITSELF via govern::lesson_placement (lib/
    # common.sh); redirect the insertion target to that sub-repo's own CLAUDE.md when the evidence
    # is unambiguous.
    #
    # TRANSACTIONAL: a redirect is a WRITE + COMMIT + (best-effort) PUSH into a git repo that is
    # NOT the one this script's own lock/CAS-retry machinery protects — a sub-repo push can fail for
    # reasons entirely outside our control (branch protection on its default branch, no push
    # credential in a headless context, a non-fast-forward race with another worker). We refuse to
    # even ATTEMPT a redirect unless the sub-repo's tree is already clean (never write/commit behind
    # something else that's mid-edit there), and if the attempt still fails, we undo ONLY what we
    # touched — never a `reset --hard` of a repo this script doesn't exclusively own — before falling
    # through to the ORIGINAL root insert below. A lesson must always land SOMEWHERE; a failed
    # redirect must never be a silently lost lesson (worse than the bloat this gate exists to fix).
    # Every outcome (redirect success / dirty-skip / attempted-then-fell-back / never attempted) is logged.
    redirected=0
    if command -v govern::lesson_placement >/dev/null 2>&1; then
      placement_repo=""; placement_reason=""
      IFS=$'\t' read -r placement_repo placement_reason < <(govern::lesson_placement "$text")
      if [[ -z "$placement_repo" ]]; then
        govern::log "bookkeep #$N: lessonPatch staying at root CLAUDE.md ($placement_reason)"
      else
        subrepo_dir="$meta_root/$placement_repo"
        subrepo_claude="$subrepo_dir/CLAUDE.md"
        if [[ ! -f "$subrepo_claude" ]] || ! git -C "$subrepo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          govern::log "bookkeep #$N: placement gate picked '$placement_repo' but $placement_repo/CLAUDE.md or its git repo isn't present here — staying at root CLAUDE.md ($placement_reason)"
        elif [[ -n "$(git -C "$subrepo_dir" status --porcelain 2>/dev/null)" ]]; then
          # SAFETY (#83 review): never write/commit into a sub-repo whose tree isn't already clean —
          # an operator mid-edit in the main checkout, a concurrent session, or a worker's leftover
          # state could be sitting there, and this gate has no business touching any of it. A dirty
          # tree is exactly the situation where we must back off, not write behind someone's back.
          govern::log "bookkeep #$N: placement gate picked '$placement_repo' but its working tree is DIRTY (uncommitted changes present) — refusing to write/commit into it; staying at root CLAUDE.md ($placement_reason)"
        elif [[ "$(git -C "$subrepo_dir" symbolic-ref --short -q HEAD 2>/dev/null || true)" != "$(govern::subrepo_default_branch "$subrepo_dir")" ]]; then
          # SAFETY (#83 review): govern-bookkeep.sh runs against the MAIN checkout (run-loop.sh
          # invokes it from the same tree that owns queue/tickets.md — never a worker's worktree,
          # which lives under a separate WORKTREE_BASE), and the workspace convention is that the
          # main checkout's sub-repos always sit on their default branch (root CLAUDE.md rule #8;
          # check-main-on-main.sh warns on drift, but only as an advisory SessionStart hook — it
          # never blocks). If that convention has been violated for any reason (a human manually
          # switched it, a bug elsewhere left it mid-op) and HEAD is on a ticket/feature branch,
          # `push HEAD:<default>` would push that branch's entire tip — including unmerged work —
          # straight onto the default branch, bypassing its PR and CI. Refuse instead: same shape
          # as the dirty-tree check above. Detached HEAD (symbolic-ref returns empty) also refuses.
          govern::log "bookkeep #$N: placement gate picked '$placement_repo' but its checkout is not on its default branch — refusing to redirect (would push the wrong branch's tip); staying at root CLAUDE.md ($placement_reason)"
        else
          subrepo_default_branch="$(govern::subrepo_default_branch "$subrepo_dir")"
          subrepo_prehead="$(git -C "$subrepo_dir" rev-parse HEAD 2>/dev/null || true)"
          subrepo_ok=0
          if [[ -n "$subrepo_prehead" ]]; then
            govern::insert_lesson "$subrepo_claude" "$anchor" "$text"
            # The compound command's exit status is its LAST evaluated element — `[[ "$pushed" == 1 ]]`
            # on the push branch, or the `exit 0` short-circuits when no push was needed/possible — so
            # the `if` genuinely reflects push success, not just "commit landed" (a real push failure
            # must count as an overall failure here, never be masked by an earlier `|| true`).
            if ( cd "$subrepo_dir"
                 git add CLAUDE.md \
                 && git commit -q -m "docs(claude): promote lesson from ticket #$N" \
                 && { [[ "${GOVERN_NO_PUSH:-0}" == "1" ]] && exit 0
                      git remote get-url origin >/dev/null 2>&1 || exit 0
                      pushed=0
                      for _attempt in 1 2 3 4 5; do
                        if git push origin "HEAD:$subrepo_default_branch" >/dev/null 2>&1; then pushed=1; break; fi
                        git pull --rebase origin "$subrepo_default_branch" >/dev/null 2>&1 || break
                      done
                      [[ "$pushed" == "1" ]]
                    }
               ); then
              subrepo_ok=1
            fi
          fi
          if [[ "$subrepo_ok" == "1" ]]; then
            redirected=1
            govern::log "bookkeep #$N: lessonPatch redirected root CLAUDE.md -> $placement_repo/CLAUDE.md ($placement_reason)"
          else
            # NARROW rollback — restore ONLY what we touched (CLAUDE.md + our own commit, if we made
            # one), never `reset --hard` a repo we don't exclusively own. The tree was verified clean
            # before we started, so the only possible diff from $subrepo_prehead at this point is our
            # own add/commit: `reset --mixed` moves HEAD back (a no-op if we never got as far as
            # committing) and resets the INDEX to match it (un-staging our `git add` either way),
            # then `checkout --` restores the WORKING TREE for that one path from that index. Neither
            # step touches any other file.
            git -C "$subrepo_dir" reset --mixed "$subrepo_prehead" >/dev/null 2>&1 || true
            git -C "$subrepo_dir" checkout -- CLAUDE.md 2>/dev/null || true
            govern::log "bookkeep #$N: sub-repo commit/push into $placement_repo/CLAUDE.md failed — reverted CLAUDE.md + our commit only (working tree otherwise untouched) and falling BACK TO ROOT CLAUDE.md instead ($placement_reason)"
          fi
        fi
      fi
    fi

    # Overflow gate: CLAUDE.md is re-sent every turn, so an oversized lessonPatch inserted verbatim
    # is a PERMANENT per-turn tax. Past GOVERN_LESSON_MAX_CHARS, keep only the LEAD rule (the first
    # paragraph — text up to the first blank line; the first line if there's no blank line) in
    # $target, pointing at the full text parked under its own heading in CLAUDE-APPENDIX.md. Falls
    # back to the CURRENT insert-everything behavior when CLAUDE-APPENDIX.md doesn't exist at the
    # meta-repo root — never silently lose the lesson. ROOT-ONLY: a redirected sub-repo lesson skips
    # this (CLAUDE-APPENDIX.md is a root-level overflow sink, and a sub-repo CLAUDE.md isn't re-sent
    # every turn the way root is, so the same permanent-tax argument doesn't apply there).
    if [[ "$redirected" == "0" ]]; then
      lesson_max_chars="${GOVERN_LESSON_MAX_CHARS:-600}"
      appendix="$meta_root/CLAUDE-APPENDIX.md"

      # ── Admission gates (#87): sink inversion, ladder, forced eviction ────────────────────────
      # All three can only DEMOTE to the appendix, never lose a lesson, and all three are skipped
      # entirely when CLAUDE-APPENDIX.md is absent (there is nowhere to demote TO — the pre-existing
      # "insert everything into CLAUDE.md" behaviour is the fallback, exactly as for overflow below).
      lesson_route="always-on"
      route_reason="default sink (GOVERN_LESSON_SINK=claude-md)"
      if [[ -f "$appendix" ]]; then
        sink_mode="${GOVERN_LESSON_SINK:-claude-md}"
        if [[ "$sink_mode" == "appendix" ]] && ! govern_bk::claims_always_on "$report"; then
          lesson_route="appendix"
          route_reason="GOVERN_LESSON_SINK=appendix (appendix is the DEFAULT sink) and this patch made no always-on claim — an always-on slot needs lessonPatch.alwaysOn=true PLUS a non-empty .frequency and .reversibility"
        elif [[ "${GOVERN_LESSON_LADDER:-0}" == "1" ]] && ! govern_bk::ladder_ok "$report"; then
          lesson_route="appendix"
          route_reason="ladder gate (guard > lint/test > appendix > always-on): the patch did not declare lessonPatch.rung=\"always-on\" together with a lessonPatch.rungWhyNot explaining why a guard or a lint cannot cover it"
        elif [[ "${GOVERN_LESSON_EVICT:-0}" == "1" ]]; then
          lesson_budget="${GOVERN_LESSON_BUDGET_CHARS:-${SHIPLOOP_CLAUDEMD_MAX_CHARS:-14000}}"
          lesson_cur_size="$(wc -c < "$target" 2>/dev/null | tr -d '[:space:]')"
          [[ -n "$lesson_cur_size" ]] || lesson_cur_size=0
          lesson_projected=$(( lesson_cur_size + ${#text} ))
          if [[ "$lesson_projected" -gt "$lesson_budget" ]]; then
            lesson_evicts="$(printf '%s' "$report" | jq -r '.lessonPatch.evicts // ""' 2>/dev/null || true)"
            if [[ -n "$lesson_evicts" ]] && govern_bk::evict_entry "$target" "$lesson_evicts"; then
              govern::log "bookkeep #$N: $lp_file at/over budget ($lesson_cur_size + ${#text} chars > $lesson_budget) — evicted the named incumbent (\"$lesson_evicts\") to make room for the promotion (GOVERN_LESSON_EVICT=1)"
            else
              lesson_route="appendix"
              if [[ -z "$lesson_evicts" ]]; then
                route_reason="$lp_file at/over budget ($lesson_cur_size + ${#text} chars > $lesson_budget) and lessonPatch.evicts was not supplied — a promotion at budget must NAME the entry it displaces"
              else
                route_reason="$lp_file at/over budget ($lesson_cur_size + ${#text} chars > $lesson_budget) and lessonPatch.evicts (\"$lesson_evicts\") did not match exactly one existing entry — refusing to guess which rule to delete"
              fi
            fi
          fi
        fi
      fi

      if [[ "$lesson_route" == "appendix" ]]; then
        # DEMOTED, not lost: the FULL text lands in the appendix under its own heading and NOTHING is
        # inserted into the always-on file (a pointer line would re-charge the per-turn tax this gate
        # exists to avoid). The appendix is not a rot reservoir — an entry parked here is still
        # subject to be-right / supersede-in-place / delete, never "moved and forgotten".
        heading="#$N — ${ticket_title:-lesson}"
        { printf '\n## %s\n\n' "$heading"; printf '%s\n' "$text"; } >> "$appendix"
        patched_files+=("$appendix")
        govern::log "bookkeep #$N: lessonPatch routed to CLAUDE-APPENDIX.md (\"$heading\") instead of always-on $lp_file — $route_reason"
        target="$appendix"   # the summary line reports the sink that actually received the lesson
      elif [[ "${#text}" -gt "$lesson_max_chars" && -f "$appendix" ]]; then
        if printf '%s' "$text" | grep -qE '^[[:space:]]*$'; then
          lead="$(awk '/^[[:space:]]*$/{exit} {print}' <<<"$text")"
        else
          lead="$(printf '%s\n' "$text" | head -n1)"
        fi
        heading="#$N — ${ticket_title:-lesson}"
        insert_text="$lead"$'\n\n'"See \`CLAUDE-APPENDIX.md\` → \"$heading\"."
        { printf '\n## %s\n\n' "$heading"; printf '%s\n' "$text"; } >> "$appendix"
        patched_files+=("$appendix")
        govern::log "bookkeep #$N: lessonPatch text (${#text} chars) exceeds GOVERN_LESSON_MAX_CHARS=$lesson_max_chars — full text moved to CLAUDE-APPENDIX.md (\"$heading\"), lead rule kept in $lp_file"
      fi
      # The appendix route already wrote (and staged) the appendix; inserting into the always-on file
      # as well would defeat the whole gate. Every other route inserts exactly as before.
      if [[ "$lesson_route" != "appendix" ]]; then
        govern::insert_lesson "$target" "$anchor" "$insert_text"
        patched_files+=("$target")   # ABSOLUTE path — staged from cd commit_dir (the queue/ folder), so a bare
                                      # root-relative name would miss it; absolute resolves from anywhere in the repo.
      fi
    else
      govern::log "bookkeep #$N: promoted lesson committed to $placement_repo/CLAUDE.md"
    fi
  fi
fi

# 3b. PROMOTE a passing autonomous validation into the committed sink (#252). The worker only
# writes the gitignored raw artifacts under the machine-local investigations sink; nothing else
# populates the git-tracked `.claude/shiploop/validation/` summary sink that founder-os context cites
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
  vdir="$meta_root/.claude/shiploop/validation"
  # slugify the title: lowercase, non-alphanumerics → '-', collapse + trim, cap to 60 chars.
  slug="$(printf '%s' "${ticket_title:-validation}" \
    | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//' | cut -c1-60)"
  [[ -z "$slug" ]] && slug="validation"
  vdoc="$vdir/ticket-$N-$slug.md"
  vdoc_rel=".claude/shiploop/validation/ticket-$N-$slug.md"
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
      printf -- '---\n> Auto-generated by `govern-bookkeep.sh` (#252) so the committed `.claude/shiploop/validation/`\n'
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
  git add "$(basename "$TICKETS_FILE")"
  for pf in ${patched_files[@]+"${patched_files[@]}"}; do git add "$pf"; done   # lesson target + (on overflow) CLAUDE-APPENDIX.md
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
  # #370/#377: the rebase runs through govern::pull_rebase_autostash — same coexistence rationale as
  # the pre-edit sync above. A co-tenant's dirty tracked files never block this retry loop; an
  # OVERLAPPING-same-file autostash-pop conflict (rc 0 + unmerged index) is detected and recovered
  # (our commit is already rebased onto origin/main → the next push is a fast-forward; co-tenant WIP is
  # parked in the preserved stash, untouched); and a genuine tickets.md content conflict still returns
  # 1 → break → the retries-exhausted log below.
  if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
    pushed=0
    for _attempt in 1 2 3 4 5; do
      if git push origin HEAD:main >/dev/null 2>&1; then pushed=1; break; fi
      govern::pull_rebase_autostash "$commit_dir" || break
    done
    if [[ "$pushed" != "1" ]]; then
      govern::log "bookkeep #$N: push to origin/main failed after 5 rebase-retries — local main now ahead/diverged; reconcile ('git pull --rebase origin main && git push') before the next ticket."
    fi
  fi
)

# 5b. STAMP THE FLOW REGISTRY on resolve (validations Phase 2). A flow-registry validation ticket
# (carried a `Flow:` field, pre-captured in step 0c) records its verdict into .claude/shiploop/validation/flows.md:
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

echo "bookkept #$N: block deleted; +$count ticket(s); lesson=${target:-none}; validationDoc=${vdoc_rel:-none}; pr=$pr"
