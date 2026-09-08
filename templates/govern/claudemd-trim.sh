#!/usr/bin/env bash
# claudemd-trim.sh: evidence-based, reversible SUGGESTION engine for the workspace root CLAUDE.md.
# Pure bash + awk/sed/jq, ZERO model calls.
#
# Principles (locked):
#   1. The unit of removal is a markdown BLOCK: a heading line, a bullet plus its indented
#      continuation lines, a paragraph, or a whole fenced code block. That is the smallest unit
#      whose removal cannot produce invalid markdown. Never a char truncation, never a raw line.
#   2. Trim candidates come from EVIDENCE, not from size or age.
#   3. Every removal is a reversible MOVE into CLAUDE-APPENDIX.md, never a delete.
#   4. NOTHING AUTOMATIC EVER EDITS CLAUDE.md. The only writers are explicit operator actions:
#      `--apply <hash>` here, and the /shiploop:compress playbook. This script used to auto-move
#      blocks it judged mechanically dead; on 2026-09-08 that quietly demoted 81 lines out of a
#      7,109-byte CLAUDE.md, every load-bearing anti-pattern included, because those rules cite
#      hub-only paths that a scaffolded workspace legitimately does not have. Detection is cheap
#      and often wrong; the edit is expensive and irreversible in practice. So: detect, classify,
#      report. A human decides.
#   5. Operator verdicts live OUTSIDE the file (governor/claudemd-verdicts.json), keyed by the
#      block's content hash, so a verdict dies exactly when the text it covered changes. No tool
#      bookkeeping in CLAUDE.md.
#
# The automatic run detects and reports only. Over budget, every non-protected block is classified
# into exactly one class and the candidates are written to governor/claudemd-trim-proposals.md:
#   * dead-citation  the block cites at least one backticked repo path or GOVERN_*/SHIPLOOP_*/WSP_*
#                    knob and EVERY citation is dead: the path is absent from the workspace root,
#                    from every sub-repo listed in scripts/lib/workspace.sh, AND from every
#                    templates/ tree in the workspace (a hub-only-by-design path such as
#                    `test/assert.sh` resolves LIVE there); the knob appears nowhere under
#                    scripts/ or templates/.
#   * duplicate      an exact content hash seen earlier in the file; the FIRST copy is never a
#                    candidate.
#   * jit-candidate  the block cites a path that EXISTS. The citation is a mechanically detectable
#                    trigger, so the rule can be loaded just in time instead of every turn.
#   * judgment       no mechanically detectable trigger: no citations at all, or only citations
#                    that cannot be checked (absolute/home paths, globs). NEVER a candidate and
#                    never written as a proposal.
# Never a candidate at all: the file's first block, every heading, a block stamped --still-true,
# and anything the LOAD-BEARING GUARD protects (a block under a heading matching
# anti-pattern|load-bearing|hard rule, or whose own text says load-bearing). Those are judgment.
# dead-citation and duplicate rank above jit-candidate; within a class, largest first.
#
# Usage:
#   claudemd-trim.sh                      detect + report; writes proposals, never CLAUDE.md
#   claudemd-trim.sh --dry-run            print what it would report; change nothing on disk
#   claudemd-trim.sh --apply <hash>       OPERATOR ACTION: move the ONE block with that content
#                                         hash (full hash or a unique prefix of 8+ hex chars) to
#                                         the appendix; refused when it matches zero or several
#                                         current blocks
#   claudemd-trim.sh --still-true <hash>  record an operator verdict in claudemd-verdicts.json
#                                         (schema: hash -> {verdict: "still-true", ts}); that block
#                                         stops being proposed until its text, and therefore its
#                                         hash, changes. Any failure reading the verdicts file
#                                         (missing, corrupt, partial) reads as NOT stamped.
# Env:
#   SHIPLOOP_CLAUDEMD_MAX_CHARS   total CLAUDE.md budget (default 14000). GOVERN_LESSON_BUDGET_CHARS
#                                 wins when set, the same precedence bookkeep and doctor use.
#   GOVERN_CLAUDEMD_SUGGEST=0     silence the one-line "run /shiploop:compress" suggestion; the
#                                 proposals file is still written.
# Exit: 0 = under budget, nothing to do, --dry-run, or an operator command that succeeded;
#       3 = compression candidates exist (proposals written). Never an error, and callers must not
#           let it change a governor run's exit status; 1 = usage error or refusal.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq

CT_CLAUDE="$WS_ROOT/CLAUDE.md"
CT_APPENDIX="$WS_ROOT/CLAUDE-APPENDIX.md"
CT_PROPOSALS="$GOVERNOR_DIR/claudemd-trim-proposals.md"
CT_VERDICTS="$GOVERNOR_DIR/claudemd-verdicts.json"
CT_BUDGET="${GOVERN_LESSON_BUDGET_CHARS:-${SHIPLOOP_CLAUDEMD_MAX_CHARS:-14000}}"
CT_UTC_DATE="$(date -u +%Y-%m-%d)"
CT_UTC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CT_WORK="$(mktemp -d)"
trap 'rm -rf "$CT_WORK"' EXIT

ct::sha() { # stdin -> sha256 hex on stdout
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
  return 0
}

# Parse <file> into block files under <outdir>: one NNNN.block per block plus ranges.tsv rows of
# "idx<TAB>kind<TAB>startline<TAB>endline" (kind: heading|fence|bullet|para). Fence-aware: a fenced
# code block is ONE block and is never split. A flush-left bullet owns its indented continuation
# lines and stops at the next flush-left line (the same span rule govern_bk::evict_entry uses).
# Contiguous flush-left prose, tables included, is one paragraph. Blank lines separate blocks.
ct::parse() { # <file> <outdir>
  local file="$1" out="$2"
  mkdir -p "$out"
  : > "$out/ranges.tsv"
  awk -v out="$out" '
    function bfile() { return sprintf("%s/%04d.block", out, bidx) }
    function openb(kind) { inb = 1; bkind = kind; bstart = NR; bprev = NR; print $0 > bfile() }
    function closeb() {
      if (!inb) return
      close(bfile())
      printf "%d\t%s\t%d\t%d\n", bidx, bkind, bstart, bprev >> (out "/ranges.tsv")
      bidx++; inb = 0
    }
    BEGIN { bidx = 0; inb = 0; infence = 0 }
    {
      if (infence) {
        print $0 > bfile(); bprev = NR
        if ($0 ~ fcloser) { infence = 0; closeb() }
        next
      }
      if ($0 ~ /^[ \t]*$/) { closeb(); next }
      if ($0 ~ /^ {0,3}```/ || $0 ~ /^ {0,3}~~~/) {
        closeb(); openb("fence"); infence = 1
        fcloser = ($0 ~ /^ {0,3}~~~/) ? "^ {0,3}~~~" : "^ {0,3}```"
        next
      }
      if ($0 ~ /^#+[ \t]/) { closeb(); openb("heading"); closeb(); next }
      if ($0 ~ /^([-*+]|[0-9]+[.)])([ \t]|$)/) { closeb(); openb("bullet"); next }
      if ($0 ~ /^[ \t]/) {
        if (inb) { print $0 > bfile(); bprev = NR } else { openb("para") }
        next
      }
      if (inb && bkind == "para") { print $0 > bfile(); bprev = NR; next }
      closeb(); openb("para"); next
    }
    END { closeb() }
  ' "$file"
  return 0
}

# Load blocks of <file> into parallel arrays and compute the content hash per block: sha256 over
# kind + newline + whitespace-normalized text (runs collapsed to one space, line ends trimmed).
# Position independent by construction: the hash survives moving or re-indenting a block and dies
# on any wording change, which is exactly the lifetime an out-of-file verdict must have.
CT_N=0
ct::load() { # <file>
  local file="$1" idx kind s e bf
  rm -rf "$CT_WORK/blocks"
  ct::parse "$file" "$CT_WORK/blocks"
  CT_N=0; CT_KIND=(); CT_START=(); CT_END=(); CT_BYTES=(); CT_HASH=(); CT_FILE=(); CT_HEAD=()
  local head=""
  while IFS=$'\t' read -r idx kind s e; do
    bf="$(printf '%s/blocks/%04d.block' "$CT_WORK" "$idx")"
    [[ -f "$bf" ]] || continue
    # Nearest preceding heading, so the load-bearing guard can read a block's section context.
    if [[ "$kind" == "heading" ]]; then head="$(head -n 1 "$bf")"; fi
    CT_HEAD[$CT_N]="$head"
    CT_KIND[$CT_N]="$kind"
    CT_START[$CT_N]="$s"
    CT_END[$CT_N]="$e"
    CT_FILE[$CT_N]="$bf"
    CT_BYTES[$CT_N]="$(wc -c < "$bf" | tr -d '[:space:]')"
    CT_HASH[$CT_N]="$({ printf '%s\n' "$kind"; sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' "$bf"; } | ct::sha)"
    CT_N=$((CT_N+1))
  done < "$CT_WORK/blocks/ranges.tsv"
  return 0
}

# Every root a citation may resolve against: the workspace root plus each sub-repo listed in
# scripts/lib/workspace.sh. (REPOS and wsp_repo_localdir come from sourcing common.sh.)
ct::roots() {
  local r d
  printf '%s\n' "$WS_ROOT"
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    d="$(wsp_repo_localdir "$r" 2>/dev/null || true)"
    if [[ -n "$d" ]]; then printf '%s\n' "$d"; fi
  done
  return 0
}

# SUFFIX FALLBACK, ported from a live fleet's fix to this exact function (aquanode, commit 15bf864;
# read-only reference, not this repo). The direct per-root checks below only resolve a citation
# written relative to the workspace root or to a sub-repo ROOT. Most citations in CLAUDE.md are
# neither: they name a script by its bare basename (`check-indexed-urls-live.sh` is really
# website/scripts/check-indexed-urls-live.sh there) or by a partial path (`tickets.md` is really
# queue/tickets.md). Without this, 9 live rules were queued for eviction as "dead citations" on that
# fleet's own workspace — the same failure the budget sweep in THIS repo had already committed
# twice: an auto-remover proving death from its own narrow lookup. An auto-remover must fail toward
# KEEPING, so a match anywhere under any of this workspace's roots counts as live. Built once per
# run and cached in CT_PATH_INDEX.
#
# Indexing every root from ct::roots() (not just WS_ROOT, which is all the ported fix needed on a
# single-repo workspace) is the "add on top" this port needs for a hub/sub-repo layout: a path
# resolving under any sub-repo's templates/ tree reads LIVE as a plain side effect of the same
# suffix match, no separate templates-specific lookup required. `test/assert.sh` matches the
# `…/shiploop/templates/govern/test/assert.sh` index line by the `/test/assert.sh` suffix test below
# — which is exactly the hub-only-by-design false positive #110 exists to fix (govern's test suite
# ships only inside the hub's templates/, never copied into a scaffolded workspace).
ct::path_index() {
  [[ -z "${CT_PATH_INDEX:-}" ]] || return 0
  CT_PATH_INDEX="$CT_WORK/pathindex.txt"
  : > "$CT_PATH_INDEX"
  while IFS= read -r d; do
    find "$d" \( -name node_modules -o -name .git -o -name .next -o -name dist \) -prune \
      -o -print 2>/dev/null | sed -e "s|^$d/||" >> "$CT_PATH_INDEX" || :
  done < <(ct::roots)
  return 0
}

# Does <workspace-relative path> exist at the workspace root, inside any sub-repo, or (via the
# suffix fallback) as a basename or partial path anywhere under any of them? One hit anywhere makes
# the citation LIVE.
ct::path_exists() { # <relpath>
  local p="$1" d
  while IFS= read -r d; do
    if [[ -e "$d/$p" ]]; then return 0; fi
  done < <(ct::roots)
  ct::path_index
  grep -qxF -- "$p" "$CT_PATH_INDEX" 2>/dev/null && return 0
  grep -qF -- "/$p" "$CT_PATH_INDEX" 2>/dev/null && return 0
  return 1
}

# A knob is LIVE when its name appears anywhere under scripts/ or templates/ (reads, defaults and
# comments included). Deliberately wider than "assigned somewhere": the conservative direction for
# an auto-remover is fewer proofs of death, never a wrong one.
ct::var_live() { # <NAME>
  local r d
  while IFS= read -r r; do
    for d in "$r/scripts" "$r/templates"; do
      [[ -d "$d" ]] || continue
      if grep -rqF -- "$1" "$d" 2>/dev/null; then return 0; fi
    done
  done < <(ct::roots)
  return 1
}

# Print one "<status>\t<token>" line per checkable citation in the block; status is dead, live or
# unproven. Backticked tokens only. A token is a citation when it is a GOVERN_*/SHIPLOOP_*/WSP_*
# knob name, or looks like a repo path (contains "/" or ends in .sh/.md/.js/.ts/.json). URLs are
# not repo paths; absolute or home paths and glob/expansion characters make a path unprovable, and
# an unproven citation keeps the block out of the dead-citation class (it becomes jit-candidate if
# something else on it is live, otherwise judgment).
ct::citations() { # <blockfile>
  local bf="$1" tok w
  { grep -oE '`[^`]{1,200}`' "$bf" 2>/dev/null || true; } | sed -e 's/^`//' -e 's/`$//' | sort -u | \
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    if [[ "$tok" =~ ^(GOVERN|SHIPLOOP|WSP)_[A-Z0-9_]+$ ]]; then
      if ct::var_live "$tok"; then printf 'live\t%s\n' "$tok"; else printf 'dead\t%s\n' "$tok"; fi
      continue
    fi
    w="${tok%% *}"          # `scripts/x.sh --flag` cites scripts/x.sh
    w="${w#./}"
    case "$w" in
      *://*) continue ;;    # URL, not a repo path
    esac
    if [[ "$w" != */* && ! "$w" =~ \.(sh|md|js|ts|json)$ ]]; then continue; fi
    case "$w" in
      /*|~*) printf 'unproven\t%s\n' "$w"; continue ;;
      *[\*\?\[\$\{]*) printf 'unproven\t%s\n' "$w"; continue ;;
      # A `<placeholder>` segment names a shape, not a file, and a git refspec is not a path at all.
      # Both used to resolve as dead and evict a live rule on the fleet this fix was ported from
      # (a `logs/investigations/<bug>/` citation, an `origin/main` mention) — ported verbatim.
      *\<*\>*) printf 'unproven\t%s\n' "$w"; continue ;;
      origin/*|upstream/*|HEAD|HEAD~*) printf 'unproven\t%s\n' "$w"; continue ;;
    esac
    if ct::path_exists "$w"; then printf 'live\t%s\n' "$w"; else printf 'dead\t%s\n' "$w"; fi
  done
  return 0
}

# Evaluate one block's citation evidence into CT_EV_DEAD/CT_EV_LIVE/CT_EV_UNPROVEN (counts) and
# CT_EV_DEADLIST/CT_EV_LIVELIST/CT_EV_UNPROVENLIST (first three tokens each, backticked).
ct::evaluate() { # <blockfile>
  local st tok
  CT_EV_DEAD=0; CT_EV_LIVE=0; CT_EV_UNPROVEN=0
  CT_EV_DEADLIST=""; CT_EV_LIVELIST=""; CT_EV_UNPROVENLIST=""
  while IFS=$'\t' read -r st tok; do
    [[ -n "$st" ]] || continue
    case "$st" in
      dead)
        CT_EV_DEAD=$((CT_EV_DEAD+1))
        if [[ "$CT_EV_DEAD" -le 3 ]]; then CT_EV_DEADLIST="${CT_EV_DEADLIST:+$CT_EV_DEADLIST, }\`$tok\`"; fi ;;
      live)
        CT_EV_LIVE=$((CT_EV_LIVE+1))
        if [[ "$CT_EV_LIVE" -le 3 ]]; then CT_EV_LIVELIST="${CT_EV_LIVELIST:+$CT_EV_LIVELIST, }\`$tok\`"; fi ;;
      unproven)
        CT_EV_UNPROVEN=$((CT_EV_UNPROVEN+1))
        if [[ "$CT_EV_UNPROVEN" -le 3 ]]; then CT_EV_UNPROVENLIST="${CT_EV_UNPROVENLIST:+$CT_EV_UNPROVENLIST, }\`$tok\`"; fi ;;
    esac
  done < <(ct::citations "$1")
  return 0
}

# LOAD-BEARING GUARD. A block is protected, and therefore classified `judgment` and never proposed,
# when its section heading names it as one of the rules the workspace cannot lose, or when the block
# itself says so. This is the direct fix for the 2026-09-08 regression: every one of 17 anti-patterns
# was demoted out of the always-loaded file because they cite hub-only paths. A rule that had to be
# written down because something broke is exactly the rule a size heuristic should never touch.
CT_LOADBEARING_RE='anti-pattern|load-bearing|hard rule'
ct::load_bearing() { # <idx> -> 0 when protected
  local i="$1"
  if [[ -n "${CT_HEAD[$i]}" ]] && grep -qiE -- "$CT_LOADBEARING_RE" <<<"${CT_HEAD[$i]}"; then return 0; fi
  if grep -qiF -- 'load-bearing' "${CT_FILE[$i]}"; then return 0; fi
  return 1
}

# OPERATOR PATH ONLY (--apply is the only caller): nothing automatic may reach this function.
# Remove the given "start-end" line ranges from <file>, swallowing the blank run that directly
# follows each removed range (the block separator) so exactly one blank keeps separating the
# neighbours, and trimming trailing blanks only when the file's tail block was removed. Everything
# outside those spans is byte-identical.
ct::remove_ranges() { # <file> <s-e> [<s-e> ...]
  local file="$1" tmpf; shift
  tmpf="$(mktemp "$CT_WORK/rm.XXXXXX")"
  awk -v rlist="$*" '
    BEGIN {
      n = split(rlist, R, " ")
      for (i = 1; i <= n; i++) { split(R[i], ab, "-"); for (j = ab[1] + 0; j <= ab[2] + 0; j++) del[j] = 1 }
    }
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (del[i] && !del[i + 1]) { j = i + 1; while (j <= NR && L[j] ~ /^[ \t]*$/) { del[j] = 1; j++ } }
      }
      olast = NR; while (olast >= 1 && L[olast] ~ /^[ \t]*$/) olast--
      if (olast >= 1 && del[olast]) {
        e = olast - 1
        while (e >= 1 && (del[e] || L[e] ~ /^[ \t]*$/)) { del[e] = 1; e-- }
      }
      for (i = 1; i <= NR; i++) if (!del[i]) print L[i]
    }
  ' "$file" > "$tmpf"
  mv "$tmpf" "$file"
  return 0
}

# Append one block to the appendix under a dated per-label heading (opened once per run per label),
# preceded by a one-line provenance note naming the source file. OPERATOR PATH ONLY: the only caller
# is --apply. Nothing on the automatic path may reach this function.
CT_LAST_SECTION=""
ct::append_block() { # <label> <provenance> <blockfile>
  local label="$1" prov="$2" bf="$3"
  if [[ "$CT_LAST_SECTION" != "$label" ]]; then
    printf '\n## Trimmed %s (%s)\n' "$CT_UTC_DATE" "$label" >> "$CT_APPENDIX"
    CT_LAST_SECTION="$label"
  fi
  printf '\n> %s\n\n' "$prov" >> "$CT_APPENDIX"
  cat "$bf" >> "$CT_APPENDIX"
  return 0
}

# Is there a live still-true verdict for <full hash>? Missing, corrupt or partially valid verdict
# files all read as NOT stamped: jq failures collapse to an empty string here.
ct::verdict_live() { # <full hash>
  local v
  [[ -f "$CT_VERDICTS" ]] || return 1
  v="$(jq -r --arg h "$1" '.[$h].verdict // empty' "$CT_VERDICTS" 2>/dev/null || true)"
  if [[ "$v" == "still-true" ]]; then return 0; fi
  return 1
}

# Resolve <hash-or-prefix> (8+ hex chars) against the currently loaded blocks. Refuses on zero
# matches (the text changed, or the block already moved: the verdict/apply must die with it) and on
# several matches (never guess). Sets CT_FOUND to the matched index.
ct::find_block() { # <hash-or-prefix>
  local q="$1" i n=0
  CT_FOUND=-1
  [[ "$q" =~ ^[0-9a-f]{8,64}$ ]] || govern::die "trim: '$q' is not a content hash (8 to 64 lowercase hex chars)"
  i=0
  while [[ "$i" -lt "$CT_N" ]]; do
    case "${CT_HASH[$i]}" in
      "$q"*) n=$((n+1)); CT_FOUND=$i ;;
    esac
    i=$((i+1))
  done
  if [[ "$n" -eq 0 ]]; then govern::die "trim: no current block matches hash '$q' (its text changed, or it was already moved): refusing"; fi
  if [[ "$n" -gt 1 ]]; then govern::die "trim: hash prefix '$q' matches $n blocks: give more characters"; fi
  return 0
}

ct::first_line() { # <blockfile> -> first line, truncated, tabs flattened (it rides in a TSV)
  head -n 1 "$1" | tr '\t' ' ' | cut -c1-70
  return 0
}

# ── argument parsing ────────────────────────────────────────────────────────
CT_MODE="run"; CT_DRY=0; CT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--dry) CT_DRY=1 ;;
    --apply)      CT_MODE="apply";      CT_ARG="${2:-}"; [[ -n "$CT_ARG" ]] || govern::die "usage: claudemd-trim.sh --apply <hash>"; shift ;;
    --still-true) CT_MODE="still-true"; CT_ARG="${2:-}"; [[ -n "$CT_ARG" ]] || govern::die "usage: claudemd-trim.sh --still-true <hash>"; shift ;;
    *) govern::die "usage: claudemd-trim.sh [--dry-run] | --apply <hash> | --still-true <hash>" ;;
  esac
  shift
done

if [[ ! -f "$CT_CLAUDE" ]]; then
  govern::log "trim: no $CT_CLAUDE, nothing to trim"
  exit 0
fi

# ── operator commands ───────────────────────────────────────────────────────
if [[ "$CT_MODE" == "apply" ]]; then
  ct::load "$CT_CLAUDE"
  ct::find_block "$CT_ARG"
  [[ -f "$CT_APPENDIX" ]] || govern::die "trim: CLAUDE-APPENDIX.md is absent, nowhere to move the block to (create it, then re-run)"
  i="$CT_FOUND"
  ct::append_block "operator apply" \
    "moved from CLAUDE.md by claudemd-trim.sh --apply on $CT_UTC_TS (operator decision, hash ${CT_HASH[$i]:0:12})" \
    "${CT_FILE[$i]}"
  ct::remove_ranges "$CT_CLAUDE" "${CT_START[$i]}-${CT_END[$i]}"
  govern::log "trim: moved block ${CT_HASH[$i]:0:12} (${CT_BYTES[$i]} bytes, ${CT_KIND[$i]}, line ${CT_START[$i]}) to CLAUDE-APPENDIX.md"
  exit 0
fi

if [[ "$CT_MODE" == "still-true" ]]; then
  ct::load "$CT_CLAUDE"
  ct::find_block "$CT_ARG"
  ct_hash="${CT_HASH[$CT_FOUND]}"
  mkdir -p "$GOVERNOR_DIR"
  ct_base='{}'
  if [[ -f "$CT_VERDICTS" ]]; then
    if jq -e 'type == "object"' "$CT_VERDICTS" >/dev/null 2>&1; then
      ct_base="$(cat "$CT_VERDICTS")"
    else
      mv "$CT_VERDICTS" "$CT_VERDICTS.corrupt.$(date -u +%s)"
      govern::log "trim: $CT_VERDICTS was unreadable; set it aside as *.corrupt.* and starting fresh (an unreadable verdict always reads as NOT stamped)"
    fi
  fi
  printf '%s' "$ct_base" | jq --arg h "$ct_hash" --arg ts "$CT_UTC_TS" \
    '. + {($h): {verdict: "still-true", ts: $ts}}' > "$CT_VERDICTS.tmp"
  mv "$CT_VERDICTS.tmp" "$CT_VERDICTS"
  govern::log "trim: recorded still-true verdict for ${ct_hash:0:12}; this block is no longer proposed until its text changes"
  exit 0
fi

# ── detect, classify, report: this path NEVER edits CLAUDE.md ───────────────
ct::load "$CT_CLAUDE"
ct_size="$(wc -c < "$CT_CLAUDE" | tr -d '[:space:]')"

if [[ "$ct_size" -le "$CT_BUDGET" ]]; then
  if [[ "$CT_DRY" -eq 0 && -f "$CT_PROPOSALS" ]]; then
    rm -f "$CT_PROPOSALS"
    govern::log "trim: removed stale $CT_PROPOSALS (file is under budget)"
  fi
  govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, under budget"
  exit 0
fi

# Candidate rows: "<classrank>\t<bytes>\t<hash>\t<class>\t<kind>\t<startline>\t<evidence>\t<snippet>".
# classrank 0 = mechanical (dead-citation, duplicate), 1 = jit-candidate; sorted rank ascending then
# bytes descending, so the mechanically-evidenced blocks always read first.
ct_cand="$CT_WORK/candidates.tsv"
: > "$ct_cand"
ct_stamped=0; ct_guarded=0; ct_judgment=0
ct_seen=" "
i=0
while [[ "$i" -lt "$CT_N" ]]; do
  h="${CT_HASH[$i]}"
  case "$ct_seen" in
    *" $h "*) isdup=1 ;;
    *) isdup=0 ;;
  esac
  ct_seen="$ct_seen$h "

  if [[ "$i" -eq 0 || "${CT_KIND[$i]}" == "heading" ]]; then i=$((i+1)); continue; fi
  if ct::load_bearing "$i"; then
    ct_guarded=$((ct_guarded+1)); i=$((i+1)); continue
  fi
  if ct::verdict_live "$h"; then
    ct_stamped=$((ct_stamped+1)); i=$((i+1)); continue
  fi

  ct_class=""; ct_rank=1; ct_ev=""
  if [[ "$isdup" -eq 1 ]]; then
    ct_class="duplicate"; ct_rank=0
    ct_ev="exact duplicate of an earlier block; the first copy stays in place"
  else
    ct::evaluate "${CT_FILE[$i]}"
    if [[ $((CT_EV_DEAD + CT_EV_LIVE + CT_EV_UNPROVEN)) -eq 0 ]]; then
      ct_judgment=$((ct_judgment+1)); i=$((i+1)); continue           # no citations: judgment
    elif [[ "$CT_EV_LIVE" -gt 0 ]]; then
      ct_class="jit-candidate"; ct_rank=1
      ct_ev="cites $CT_EV_LIVELIST, still present: a mechanically detectable trigger, so this rule can be loaded just in time instead of every turn"
    elif [[ "$CT_EV_UNPROVEN" -gt 0 ]]; then
      ct_judgment=$((ct_judgment+1)); i=$((i+1)); continue           # uncheckable citation: judgment
    else
      ct_class="dead-citation"; ct_rank=0
      ct_ev="every citation is dead: $CT_EV_DEADLIST (absent from the workspace root, every sub-repo, and every templates/ tree)"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ct_rank" "${CT_BYTES[$i]}" "$h" "$ct_class" "${CT_KIND[$i]}" "${CT_START[$i]}" \
    "$(printf '%s' "$ct_ev" | tr '\t' ' ')" "$(ct::first_line "${CT_FILE[$i]}")" >> "$ct_cand"
  i=$((i+1))
done
sort -t "$(printf '\t')" -k1,1n -k2,2nr -o "$ct_cand" "$ct_cand"
ct_nprops="$(grep -c . "$ct_cand" 2>/dev/null || true)"
ct_nprops="${ct_nprops:-0}"

if [[ "$ct_guarded" -gt 0 ]]; then
  govern::log "trim: load-bearing guard protected $ct_guarded block(s) from being proposed (heading matches anti-pattern/load-bearing/hard rule, or the block says load-bearing)"
fi

if [[ "$CT_DRY" -eq 1 ]]; then
  while IFS=$'\t' read -r rank bytes h class kind start ev snip; do
    govern::log "trim: would propose ${h:0:12} [$class] ($bytes bytes, $kind, line $start): $ev"
  done < "$ct_cand"
  govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, would write $ct_nprops compression candidate(s) to $CT_PROPOSALS"
  exit 0
fi

if [[ "$ct_nprops" -eq 0 ]]; then
  if [[ -f "$CT_PROPOSALS" ]]; then rm -f "$CT_PROPOSALS"; fi
  govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, over budget with no compression candidate(s): every remaining block is a heading, load-bearing, stamped still-true, or judgment. This one has to be cut by hand."
  exit 0
fi

mkdir -p "$GOVERNOR_DIR"
{
  printf '# CLAUDE.md compression candidates\n\n'
  printf 'Generated by claudemd-trim.sh on %s. CLAUDE.md is %s chars against a %s char budget.\n' "$CT_UTC_TS" "$ct_size" "$CT_BUDGET"
  printf 'NOTHING here was changed automatically, and nothing automatic ever edits CLAUDE.md.\n'
  printf 'Run `/shiploop:compress` to work through these, or act on one directly:\n\n'
  printf '    bash scripts/govern/claudemd-trim.sh --apply <hash>       move it to CLAUDE-APPENDIX.md\n'
  printf '    bash scripts/govern/claudemd-trim.sh --still-true <hash>  keep it; not re-proposed until its text changes\n\n'
  printf 'Classes: dead-citation (every citation is gone), duplicate (an earlier copy exists),\n'
  printf 'jit-candidate (cites a live path, so it can load just in time). A judgment block, one with\n'
  printf 'no mechanically detectable trigger, is never proposed and never appears below.\n'
  printf 'This file is regenerated on every run; do not edit it by hand.\n'
  if [[ "$ct_stamped" -gt 0 ]]; then
    printf '(%s block(s) stamped still-true were skipped.)\n' "$ct_stamped"
  fi
  if [[ "$ct_guarded" -gt 0 ]]; then
    printf '(%s block(s) protected by the load-bearing guard were skipped.)\n' "$ct_guarded"
  fi
  if [[ "$ct_judgment" -gt 0 ]]; then
    printf '(%s judgment block(s) were skipped: no mechanically detectable trigger.)\n' "$ct_judgment"
  fi
  printf '\n## Candidates (mechanical first, then largest first)\n'
  while IFS=$'\t' read -r _rank bytes h class kind start ev snip; do
    printf -- '\n- `%s`\n  Class: %s\n  %s bytes, %s, line %s: %s\n  > %s\n' "$h" "$class" "$bytes" "$kind" "$start" "$ev" "$snip"
  done < "$ct_cand"
} > "$CT_PROPOSALS"

if [[ "${GOVERN_CLAUDEMD_SUGGEST:-1}" != "0" ]]; then
  govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, $ct_nprops compression candidate(s) - run /shiploop:compress"
fi
govern::log "trim: candidates written to $CT_PROPOSALS; CLAUDE.md was not modified"
exit 3
