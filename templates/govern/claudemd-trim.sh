#!/usr/bin/env bash
# claudemd-trim.sh: evidence-based, reversible, two-lane trimming for the workspace root CLAUDE.md.
# Pure bash + awk/sed/jq, ZERO model calls. Replaces the blind largest-first eviction that used to
# live inside `govern-bookkeep.sh --enforce-budgets` (which now calls this script instead).
#
# Principles (locked; adapted from cleanmyclaude's rule_trim / rule_drift / rule_verdicts):
#   1. The unit of removal is a markdown BLOCK: a heading line, a bullet plus its indented
#      continuation lines, a paragraph, or a whole fenced code block. That is the smallest unit
#      whose removal cannot produce invalid markdown. Never a char truncation, never a raw line.
#   2. Trim candidates come from EVIDENCE, not from size or age.
#   3. Every removal is a reversible MOVE into CLAUDE-APPENDIX.md, never a delete.
#   4. Suspicion requires a human; only mechanical proof may auto-apply. Operator verdicts live
#      OUTSIDE the file (governor/claudemd-verdicts.json), keyed by the block's content hash, so a
#      verdict dies exactly when the text it covered changes. No tool bookkeeping in CLAUDE.md.
#
# Lane 1 (auto, mechanical proof only; kill switch GOVERN_TRIM_DEAD=0):
#   * dead-citation blocks: the block cites at least one backticked repo path or
#     GOVERN_*/SHIPLOOP_*/WSP_* knob, every cited path is absent from the workspace root AND from
#     every sub-repo listed in scripts/lib/workspace.sh, and every cited knob appears nowhere under
#     scripts/ or templates/. One live or uncheckable citation disqualifies the block; a block with
#     no citations never qualifies.
#   * exact duplicates: a content hash seen earlier in the file keeps its FIRST copy; later copies
#     move to the appendix.
#   * a heading block and the file's FIRST block are never auto-moved.
# Lane 2 (propose, everything else): when the file still exceeds the budget after lane 1, ranked
#   candidates (largest first, each with content hash, byte size and an evidence line) are written
#   to governor/claudemd-trim-proposals.md. This lane NEVER modifies CLAUDE.md.
#
# Usage:
#   claudemd-trim.sh                      lane 1, then lane 2 when still over budget
#   claudemd-trim.sh --dry-run            print what each lane would do; change nothing on disk
#   claudemd-trim.sh --apply <hash>       move the ONE block with that content hash (full hash or a
#                                         unique prefix of 8+ hex chars) to the appendix; refused
#                                         when it matches zero or several current blocks
#   claudemd-trim.sh --still-true <hash>  record an operator verdict in claudemd-verdicts.json
#                                         (schema: hash -> {verdict: "still-true", ts}); lane 2
#                                         stops proposing that block until its text, and therefore
#                                         its hash, changes. Any failure reading the verdicts file
#                                         (missing, corrupt, partial) reads as NOT stamped.
# Env:
#   SHIPLOOP_CLAUDEMD_MAX_CHARS   total CLAUDE.md budget (default 14000). GOVERN_LESSON_BUDGET_CHARS
#                                 wins when set, the same precedence bookkeep and doctor use.
#   GOVERN_TRIM_DEAD=0            disable lane 1 (auto moves); proposals only.
# Exit: 0 = under budget, or nothing to do, or --dry-run / operator command succeeded;
#       3 = still over budget after lane 1 (proposals written); 1 = usage error or refusal.
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
  CT_N=0; CT_KIND=(); CT_START=(); CT_END=(); CT_BYTES=(); CT_HASH=(); CT_FILE=()
  while IFS=$'\t' read -r idx kind s e; do
    bf="$(printf '%s/blocks/%04d.block' "$CT_WORK" "$idx")"
    [[ -f "$bf" ]] || continue
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

# Does <workspace-relative path> exist at the workspace root or inside any sub-repo listed in
# scripts/lib/workspace.sh? (REPOS and wsp_repo_localdir come from sourcing common.sh.)
ct::path_exists() { # <relpath>
  local p="$1" r d
  if [[ -e "$WS_ROOT/$p" ]]; then return 0; fi
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    d="$(wsp_repo_localdir "$r" 2>/dev/null || true)"
    if [[ -n "$d" && -e "$d/$p" ]]; then return 0; fi
  done
  return 1
}

# A knob is LIVE when its name appears anywhere under scripts/ or templates/ (reads, defaults and
# comments included). Deliberately wider than "assigned somewhere": the conservative direction for
# an auto-remover is fewer proofs of death, never a wrong one.
ct::var_live() { # <NAME>
  local d
  for d in "$WS_ROOT/scripts" "$WS_ROOT/templates"; do
    [[ -d "$d" ]] || continue
    if grep -rqF -- "$1" "$d" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Print one "<status>\t<token>" line per checkable citation in the block; status is dead, live or
# unproven. Backticked tokens only. A token is a citation when it is a GOVERN_*/SHIPLOOP_*/WSP_*
# knob name, or looks like a repo path (contains "/" or ends in .sh/.md/.js/.ts/.json). URLs are
# not repo paths; absolute or home paths and glob/expansion characters make a path unprovable, and
# an unproven citation disqualifies the block from lane 1.
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

# One human-readable evidence line for a lane-2 candidate, from the CT_EV_* globals.
ct::evidence_line() {
  if [[ "$CT_EV_LIVE" -gt 0 ]]; then
    printf 'cites %s, still present in the workspace: cannot auto-prove dead' "$CT_EV_LIVELIST"
  elif [[ "$CT_EV_UNPROVEN" -gt 0 ]]; then
    printf 'cites %s, not mechanically checkable: cannot auto-prove dead' "$CT_EV_UNPROVENLIST"
  elif [[ "$CT_EV_DEAD" -gt 0 ]]; then
    printf 'every citation dead (%s) but lane 1 did not run (GOVERN_TRIM_DEAD=0 or no appendix)' "$CT_EV_DEADLIST"
  else
    printf 'no citations: judgment call'
  fi
  return 0
}

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
# preceded by a one-line provenance note naming the source file.
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
  govern::log "trim: recorded still-true verdict for ${ct_hash:0:12}; lane 2 stops proposing this block until its text changes"
  exit 0
fi

# ── lane 1: auto-move only what is mechanically proven ──────────────────────
ct::load "$CT_CLAUDE"
ct_trim_dead="${GOVERN_TRIM_DEAD:-1}"
ct_seen=" "
ct_dead_idx=""; ct_dup_idx=""; ct_lane1_hashes=" "
if [[ "$ct_trim_dead" == "0" ]]; then
  govern::log "trim: lane 1 (auto) disabled by GOVERN_TRIM_DEAD=0; proposals only"
else
  i=0
  while [[ "$i" -lt "$CT_N" ]]; do
    h="${CT_HASH[$i]}"
    prot=0
    if [[ "$i" -eq 0 || "${CT_KIND[$i]}" == "heading" ]]; then prot=1; fi
    case "$ct_seen" in
      *" $h "*) isdup=1 ;;
      *) isdup=0 ;;
    esac
    ct_seen="$ct_seen$h "
    if [[ "$prot" -eq 0 ]]; then
      if [[ "$isdup" -eq 1 ]]; then
        ct_dup_idx="$ct_dup_idx $i"
        ct_lane1_hashes="$ct_lane1_hashes$h "
      else
        ct::evaluate "${CT_FILE[$i]}"
        if [[ $((CT_EV_DEAD + CT_EV_LIVE + CT_EV_UNPROVEN)) -gt 0 && "$CT_EV_LIVE" -eq 0 && "$CT_EV_UNPROVEN" -eq 0 ]]; then
          ct_dead_idx="$ct_dead_idx $i"
          ct_lane1_hashes="$ct_lane1_hashes$h "
        fi
      fi
    fi
    i=$((i+1))
  done
  if [[ -n "$ct_dead_idx$ct_dup_idx" && ! -f "$CT_APPENDIX" ]]; then
    govern::log "trim: block(s) qualify for auto-move but CLAUDE-APPENDIX.md is absent: nowhere to move to, skipping lane 1 (create it, then re-run)"
    ct_dead_idx=""; ct_dup_idx=""; ct_lane1_hashes=" "
  fi
fi

ct_removed_ranges=""
ct_removed_bytes=0
for i in $ct_dead_idx; do
  ct::evaluate "${CT_FILE[$i]}"
  if [[ "$CT_DRY" -eq 1 ]]; then
    govern::log "trim: would move dead-citation block ${CT_HASH[$i]:0:12} (${CT_BYTES[$i]} bytes, ${CT_KIND[$i]}, line ${CT_START[$i]}) to CLAUDE-APPENDIX.md (dead: $CT_EV_DEADLIST)"
  else
    ct::append_block "dead citations" \
      "moved from CLAUDE.md by claudemd-trim.sh on $CT_UTC_TS; every citation is dead: $CT_EV_DEADLIST" \
      "${CT_FILE[$i]}"
    govern::log "trim: moved dead-citation block ${CT_HASH[$i]:0:12} (${CT_BYTES[$i]} bytes, ${CT_KIND[$i]}, line ${CT_START[$i]}) to CLAUDE-APPENDIX.md (dead: $CT_EV_DEADLIST)"
  fi
  ct_removed_ranges="$ct_removed_ranges ${CT_START[$i]}-${CT_END[$i]}"
  ct_removed_bytes=$((ct_removed_bytes + CT_BYTES[i] + 1))
done
for i in $ct_dup_idx; do
  if [[ "$CT_DRY" -eq 1 ]]; then
    govern::log "trim: would move duplicate block ${CT_HASH[$i]:0:12} (${CT_BYTES[$i]} bytes, ${CT_KIND[$i]}, line ${CT_START[$i]}) to CLAUDE-APPENDIX.md (first copy kept)"
  else
    ct::append_block "duplicate" \
      "moved from CLAUDE.md by claudemd-trim.sh on $CT_UTC_TS; exact duplicate (hash ${CT_HASH[$i]:0:12}), first copy kept in place" \
      "${CT_FILE[$i]}"
    govern::log "trim: moved duplicate block ${CT_HASH[$i]:0:12} (${CT_BYTES[$i]} bytes, ${CT_KIND[$i]}, line ${CT_START[$i]}) to CLAUDE-APPENDIX.md (first copy kept)"
  fi
  ct_removed_ranges="$ct_removed_ranges ${CT_START[$i]}-${CT_END[$i]}"
  ct_removed_bytes=$((ct_removed_bytes + CT_BYTES[i] + 1))
done
if [[ -n "$ct_removed_ranges" && "$CT_DRY" -eq 0 ]]; then
  # shellcheck disable=SC2086
  ct::remove_ranges "$CT_CLAUDE" $ct_removed_ranges
fi

# ── budget check, then lane 2: propose, never edit ──────────────────────────
ct_size="$(wc -c < "$CT_CLAUDE" | tr -d '[:space:]')"
if [[ "$CT_DRY" -eq 1 ]]; then
  # A dry pass cannot shrink the file; estimate the post-lane-1 size instead.
  ct_size=$((ct_size - ct_removed_bytes))
fi
if [[ "$ct_size" -le "$CT_BUDGET" ]]; then
  if [[ "$CT_DRY" -eq 0 && -f "$CT_PROPOSALS" ]]; then
    rm -f "$CT_PROPOSALS"
    govern::log "trim: removed stale $CT_PROPOSALS (file is under budget)"
  fi
  govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, under budget"
  exit 0
fi

ct::load "$CT_CLAUDE"
ct_cand="$CT_WORK/candidates.tsv"
: > "$ct_cand"
ct_stamped=0
i=0
while [[ "$i" -lt "$CT_N" ]]; do
  h="${CT_HASH[$i]}"
  keep=0
  if [[ "$i" -eq 0 || "${CT_KIND[$i]}" == "heading" ]]; then keep=1; fi
  case "$ct_lane1_hashes" in
    *" $h "*) keep=1 ;;   # dry run only: lane 1 would already move it
  esac
  if [[ "$keep" -eq 0 ]] && ct::verdict_live "$h"; then
    keep=1
    ct_stamped=$((ct_stamped+1))
  fi
  if [[ "$keep" -eq 0 ]]; then
    ct::evaluate "${CT_FILE[$i]}"
    ct_ev="$(ct::evidence_line | tr '\t' ' ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${CT_BYTES[$i]}" "$h" "${CT_KIND[$i]}" "${CT_START[$i]}" "$ct_ev" "$(ct::first_line "${CT_FILE[$i]}")" \
      >> "$ct_cand"
  fi
  i=$((i+1))
done
sort -t "$(printf '\t')" -k1,1nr -o "$ct_cand" "$ct_cand"
ct_nprops="$(grep -c . "$ct_cand" 2>/dev/null || true)"
ct_nprops="${ct_nprops:-0}"

if [[ "$CT_DRY" -eq 1 ]]; then
  while IFS=$'\t' read -r bytes h kind start ev snip; do
    govern::log "trim: would propose ${h:0:12} ($bytes bytes, $kind, line $start): $ev"
  done < "$ct_cand"
  govern::log "trim: CLAUDE.md ~$ct_size/$CT_BUDGET chars after lane 1, still over budget: would write $ct_nprops proposal(s) to $CT_PROPOSALS"
  exit 0
fi

mkdir -p "$GOVERNOR_DIR"
{
  printf '# CLAUDE.md trim proposals\n\n'
  printf 'Generated by claudemd-trim.sh on %s. CLAUDE.md is %s chars against a %s char budget.\n' "$CT_UTC_TS" "$ct_size" "$CT_BUDGET"
  printf 'Nothing below was changed automatically. For each candidate, either:\n\n'
  printf '    bash scripts/govern/claudemd-trim.sh --apply <hash>       move it to CLAUDE-APPENDIX.md\n'
  printf '    bash scripts/govern/claudemd-trim.sh --still-true <hash>  keep it; not re-proposed until its text changes\n\n'
  printf 'This file is regenerated on every run; do not edit it by hand.\n'
  if [[ "$ct_stamped" -gt 0 ]]; then
    printf '(%s block(s) stamped still-true were skipped.)\n' "$ct_stamped"
  fi
  printf '\n## Candidates (largest first)\n'
  if [[ "$ct_nprops" -eq 0 ]]; then
    printf '\nNo candidates: every remaining block is a heading, the first block, or stamped still-true.\n'
    printf 'The remaining weight has to be cut by hand.\n'
  fi
  while IFS=$'\t' read -r bytes h kind start ev snip; do
    printf -- '\n- `%s`\n  %s bytes, %s, line %s: %s\n  > %s\n' "$h" "$bytes" "$kind" "$start" "$ev" "$snip"
  done < "$ct_cand"
} > "$CT_PROPOSALS"
govern::log "trim: CLAUDE.md $ct_size/$CT_BUDGET chars, still over budget: $ct_nprops proposal(s) in $CT_PROPOSALS (review, then --apply the blocks you approve, or stamp keepers --still-true)"
exit 3
