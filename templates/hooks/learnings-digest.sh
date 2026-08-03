#!/usr/bin/env bash
# SessionStart hook: inject the N most RECENT learnings — and nothing else.
#
# Replaces the inline `head -30 learnings.md` this slot used to run. That command
# was a net token LOSS on every fleet, in three compounding ways:
#
#   1. It paid for the file's INSTRUCTIONS, not its content. learnings.md opens
#      with ~16 lines of format doc ("what belongs here", "promote when stable",
#      "work items go to tickets.md"). `head -30` therefore spent most of its
#      budget re-teaching the session how to WRITE the file before reaching a
#      single thing the file had to SAY.
#   2. On a FRESH fleet it injected 18 lines whose entire payload is
#      "_(empty — append dated entries as you discover things)_" — a per-session
#      tax, forever, for zero information.
#   3. `head` reads the TOP of the file, but the seed tells operators to APPEND
#      entries. On any fleet that followed that instruction, the hook surfaced the
#      OLDEST learnings and truncated the newest ones away.
#
# This reads entries instead of lines: skip the preamble, sort by the date in each
# entry heading (ISO dates sort lexically, so this is correct whether the fleet
# prepends or appends), emit the newest few, and — crucially — emit NOTHING when
# there are no entries. Silence is the correct output for an empty file.
#
# Entry format (documented in the seed learnings.md):
#   ### YYYY-MM-DD — short title
# Any `##`-or-deeper heading counts; the date is read from the heading text.
# Undated headings still surface, ordered last, so a fleet that drifted from the
# convention degrades to "shown, just not date-ranked" rather than to silence.
#
# Output contract: a SessionStart hook's stdout (exit 0) is added to the session's
# context. Never block — always exit 0.
set -uo pipefail

# --- tuning knobs -----------------------------------------------------------
MAX_ENTRIES="${SHIPLOOP_LEARNINGS_MAX_ENTRIES:-3}"   # newest N entries
MAX_LINES="${SHIPLOOP_LEARNINGS_MAX_LINES:-40}"      # hard ceiling on injected lines

# TTL demotion (#87). Past the ~2-week window the seed documents, an entry degrades to a
# TITLE-ONLY line instead of being dropped: deleting a still-true measurement just makes a future
# session re-derive it, while re-injecting its full body forever is the ratchet we're trying to
# stop. Ships INERT — SHIPLOOP_LEARNINGS_TTL=0 is today's behaviour exactly; set it to 1 to enable.
TTL_ON="${SHIPLOOP_LEARNINGS_TTL:-0}"                # 0 = off (no behaviour change)
TTL_DAYS="${SHIPLOOP_LEARNINGS_TTL_DAYS:-14}"        # the window the seed documents
# Structure lint (#87): ONE line, and only when the file is actually malformed. Ships INERT;
# set SHIPLOOP_LEARNINGS_LINT=1 to enable. Silent when healthy — that is the whole contract.
LINT_ON="${SHIPLOOP_LEARNINGS_LINT:-0}"              # 0 = off (no behaviour change)
# Test seam: pin "today" so TTL assertions don't drift with the wall clock.
TODAY="${SHIPLOOP_LEARNINGS_TODAY:-$(date +%Y-%m-%d 2>/dev/null || echo 0000-00-00)}"

# Day number for a YYYY-MM-DD, for DIFFERENCES only. Deliberately not `date -d` (GNU-only) or
# `date -j -f` (BSD-only) — this hook runs on both. Prints nothing for an unparseable date.
_ld_days() { # YYYY-MM-DD -> integer
  awk -v d="$1" 'BEGIN {
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) exit 1
    y = substr(d,1,4) + 0; m = substr(d,6,2) + 0; dd = substr(d,9,2) + 0
    if (m < 3) { y--; m += 12 }
    printf "%d\n", int(365.25 * y) + int(30.6001 * (m + 1)) + dd
  }' 2>/dev/null
}

# --- free size-trigger: root CLAUDE.md over budget --------------------------
# Pure `wc -c`, no model invocation — costs nothing when the file is healthy. Runs
# unconditionally (before any of the learnings-entry logic/early-exits below) so it fires
# regardless of whether learnings.md has entries. CLAUDE.md is re-sent every turn, so letting
# it grow unbounded is a permanent per-turn tax; this just flags the budget breach so a session
# re-triages it (move topic-local narrative to CLAUDE-APPENDIX.md, delete anything the code/
# tests/git history already record) rather than silently accreting forever.
CLAUDE_MAX_CHARS="${SHIPLOOP_CLAUDEMD_MAX_CHARS:-14000}"
CLAUDE_FILE="${2:-}"
if [ -z "$CLAUDE_FILE" ]; then
  _claude_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || _claude_root=""
  [ -n "$_claude_root" ] && CLAUDE_FILE="$_claude_root/CLAUDE.md"
fi
if [ -n "$CLAUDE_FILE" ] && [ -f "$CLAUDE_FILE" ]; then
  claude_size="$(wc -c < "$CLAUDE_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$claude_size" ] && [ "$claude_size" -gt "$CLAUDE_MAX_CHARS" ] 2>/dev/null; then
    printf '── CLAUDE.md over budget (%s chars, budget %s) — move narrative to CLAUDE-APPENDIX.md, drop what code/tests/git already record ──\n' "$claude_size" "$CLAUDE_MAX_CHARS"
  fi
fi

# --- free size-trigger: plugin manifest description surface over budget ----
# CLAUDE.md isn't the only always-on tax: the INSTALLED PLUGIN's own manifest metadata —
# the `description:` frontmatter of SKILL.md plus every commands/*.md — is loaded into
# every session and re-sent every turn too (a command body only loads on invocation; its
# frontmatter description does not wait for that). Nothing measured this surface before,
# so it can silently regrow after a trim (precedent: the harness's own core-CLAUDE-30%
# trim). Same pure `wc -c`-style measurement, no model call: sum just the description
# field VALUES (not whole files — the body text only counts against budget on invocation).
#
# Locating the plugin dir is inherently best-effort — a user's workspace may have shiploop
# installed as a plugin elsewhere on disk, checked out as a sub-repo, or not installed at
# all. Mirror doctor.sh's hub-resolution candidate order (CLAUDE_PLUGIN_ROOT env, then the
# known install paths, then a glob fallback) and DEGRADE SILENTLY — no output, no error —
# the moment none of them resolve. Never let "I couldn't find the plugin" become an error
# in what is otherwise a zero-cost, always-succeeds hook.
MANIFEST_MAX_CHARS="${SHIPLOOP_MANIFEST_MAX_CHARS:-1400}"
PLUGIN_DIR="${3:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN_DIR" ]; then
  for _cand in "$HOME/.claude/skills/shiploop" \
               "$HOME/.claude/plugins/cache/claude-plugins-official/shiploop"; do
    [ -f "$_cand/SKILL.md" ] && { PLUGIN_DIR="$_cand"; break; }
  done
fi
if [ -z "$PLUGIN_DIR" ]; then
  for _cand in "$HOME"/.claude/plugins/*/shiploop "$HOME"/.claude/plugins/*/*/shiploop; do
    [ -f "$_cand/SKILL.md" ] 2>/dev/null && { PLUGIN_DIR="$_cand"; break; }
  done
fi
if [ -n "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/SKILL.md" ]; then
  _manifest_files=("$PLUGIN_DIR/SKILL.md")
  if [ -d "$PLUGIN_DIR/commands" ]; then
    for _f in "$PLUGIN_DIR"/commands/*.md; do
      [ -f "$_f" ] && _manifest_files+=("$_f")
    done
  fi
  # FNR==1 resets `fence` per file, so each file's OWN frontmatter block is scoped
  # independently — without this, concatenating multiple files' `---` delimiters
  # would misalign which lines awk treats as "inside frontmatter".
  manifest_size="$(
    awk '
      FNR == 1 { fence = 0 }
      /^---[ \t]*$/ { fence++; next }
      fence == 1 && /^description:[ \t]*/ {
        val = $0
        sub(/^description:[ \t]*/, "", val)
        total += length(val)
      }
      END { print total + 0 }
    ' "${_manifest_files[@]}"
  )"
  if [ -n "$manifest_size" ] && [ "$manifest_size" -gt "$MANIFEST_MAX_CHARS" ] 2>/dev/null; then
    printf '── plugin manifest description surface over budget (%s chars, budget %s) — move prose from description: frontmatter into command bodies ──\n' "$manifest_size" "$MANIFEST_MAX_CHARS"
  fi
fi

# --- locate the file (arg wins; else the workspace root this script lives in) ---
FILE="${1:-}"
if [ -z "$FILE" ]; then
  SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
  FILE="$SELF_ROOT/learnings.md"
fi
[ -f "$FILE" ] || exit 0

# --- structure lint: orphaned heading / orphaned body ------------------------
# The digest slices the file at headings, so a heading whose body drifted away from it (a later
# entry appended BETWEEN the two — a real, observed failure) gets injected as a garbled slice at
# every single SessionStart, silently, forever. Two shapes are detectable without judgement:
#   * ORPHANED HEADING — an entry whose body has no non-blank line at all.
#   * ORPHANED BODY    — non-blank content sitting after the preamble's last `---` rule but BEFORE
#                        the first entry heading, in a file that DOES have entries. (The seed's
#                        `_(empty — …)_` placeholder is excluded, and a file with no entries at all
#                        is never linted — neither is a defect.)
# One line, only when broken, never an error. Off unless SHIPLOOP_LEARNINGS_LINT=1.
if [ "$LINT_ON" = "1" ]; then
  lint="$(awk '
    {
      if ($0 ~ /^[ \t]*(```|~~~)/) { fence = !fence; next }
      if (!fence && $0 ~ /^##+[ \t]/) {
        if (nh > 0 && body == 0) { oh++; if (ohl == 0) ohl = curline }
        nh++; curline = NR; body = 0; next
      }
      if (nh == 0) {
        if (!fence && $0 ~ /^---[ \t]*$/) { ob = 0; obl = 0; rule = NR; next }
        if (rule > 0 && !fence && $0 !~ /^[ \t]*$/ && $0 !~ /^_\(/) {
          ob++; if (obl == 0) obl = NR
        }
        next
      }
      if ($0 !~ /^[ \t]*$/) body++
    }
    END {
      if (nh > 0 && body == 0) { oh++; if (ohl == 0) ohl = curline }
      if (nh == 0) { oh = 0; ob = 0 }
      printf "%d\t%d\t%d\t%d\n", oh + 0, ohl + 0, ob + 0, obl + 0
    }
  ' "$FILE" 2>/dev/null)" || lint=""
  if [ -n "$lint" ]; then
    l_oh="$(printf '%s' "$lint" | cut -f1)"; l_ohl="$(printf '%s' "$lint" | cut -f2)"
    l_ob="$(printf '%s' "$lint" | cut -f3)"; l_obl="$(printf '%s' "$lint" | cut -f4)"
    l_msg=""
    [ "${l_oh:-0}" -gt 0 ] 2>/dev/null && l_msg="${l_oh} heading(s) with no body (first at line ${l_ohl})"
    if [ "${l_ob:-0}" -gt 0 ] 2>/dev/null; then
      [ -n "$l_msg" ] && l_msg="$l_msg, "
      l_msg="${l_msg}${l_ob} orphaned body line(s) before the first heading (first at line ${l_obl})"
    fi
    [ -n "$l_msg" ] && printf '── %s is malformed: %s — the digest slices at headings, so this injects garbled every session; reunite the heading with its body ──\n' "$FILE" "$l_msg"
  fi
fi

# --- index the entries: "date<TAB>start<TAB>end", one per heading -------------
# Zero-padded line numbers so a plain `sort -r` orders by date DESC and then by
# position DESC (later entry = newer) without a second numeric key.
#
# KNOWN, DELIBERATELY UNFIXED FLAW — read this before trusting the ranking. The date below is the
# one TYPED INTO THE HEADING: a self-report about when someone wrote the entry, not a fact about
# whether the entry is still TRUE. When several entries share a date, ties break by file position,
# so "3 newest of 7" really means "whichever same-date entries sit lowest in the file". The
# consequence is asymmetric: this ranking can promote an entry into every session forever, and it
# can never demote one. The TTL demotion above is a MITIGATION of that asymmetry, not a fix — the
# fix is the convention the seed documents (entries are dated OBSERVATIONS carrying source and n; a
# new measurement REWRITES the old entry in place rather than sitting beside it), because no TTL
# can tell "was true, now false" apart from "was never true".
index="$(awk '
  # Fenced code blocks are NOT entry boundaries. Learnings routinely quote shell (`## comment`) or
  # markdown, and the seed itself documents the entry format inside a fence — without this guard the
  # digest treats those lines as headings and slices the file at the wrong places.
  /^[ \t]*(```|~~~)/ { fence = !fence }
  !fence && /^##+[ \t]/ {
    n++; start[n] = NR
    d = "0000-00-00"
    if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) d = substr($0, RSTART, RLENGTH)
    date[n] = d
  }
  { last = NR }
  END {
    for (i = 1; i <= n; i++) {
      end = (i < n ? start[i+1] - 1 : last)
      printf "%s\t%06d\t%06d\n", date[i], start[i], end
    }
  }
' "$FILE" 2>/dev/null)" || exit 0

# No entries → no output. The whole point: an empty learnings.md costs nothing.
[ -n "$index" ] || exit 0

total="$(printf '%s\n' "$index" | grep -c .)"
picked="$(printf '%s\n' "$index" | sort -r | head -n "$MAX_ENTRIES")"
[ -n "$picked" ] || exit 0

TODAY_DAYS="$(_ld_days "$TODAY")"

body="$(
  printf '%s\n' "$picked" | while IFS="$(printf '\t')" read -r _d s e; do
    [ -n "$s" ] || continue
    # TTL demotion: past TTL_DAYS the entry degrades to its TITLE ONLY. Never deleted — a still-true
    # measurement that vanishes just gets re-derived at full cost by a future session. Undated
    # entries (0000-00-00) are never aged out: there is no date to age them against.
    if [ "$TTL_ON" = "1" ] && [ "$_d" != "0000-00-00" ] && [ -n "$TODAY_DAYS" ]; then
      _ed="$(_ld_days "$_d")"
      if [ -n "$_ed" ] && [ "$((TODAY_DAYS - _ed))" -gt "$TTL_DAYS" ] 2>/dev/null; then
        sed -n "${s}p" "$FILE" 2>/dev/null
        printf '  _(older than %s days — title only; body in %s)_\n' "$TTL_DAYS" "$FILE"
        continue
      fi
    fi
    sed -n "${s},${e}p" "$FILE" 2>/dev/null
  done | sed -e 's/[[:space:]]*$//' | cat -s | head -n "$MAX_LINES"
)"
[ -n "$body" ] || exit 0

shown="$(printf '%s\n' "$picked" | grep -c .)"
if [ "$total" -gt "$shown" ]; then
  printf '── workspace learnings (%s newest of %s — full file: %s) ──\n' "$shown" "$total" "$FILE"
else
  printf '── workspace learnings (%s) ──\n' "$total"
fi
printf '%s\n' "$body"
exit 0
