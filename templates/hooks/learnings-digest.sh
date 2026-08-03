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
    printf '── root CLAUDE.md is over budget (%s chars, budget %s) — re-triage: move topic-local narrative to CLAUDE-APPENDIX.md, delete anything already recorded in code/tests/git history ──\n' "$claude_size" "$CLAUDE_MAX_CHARS"
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
    printf '── plugin manifest description surface is over budget (%s chars, budget %s) — re-triage: move prose from SKILL.md/commands/*.md `description:` frontmatter into the command body, which only loads on invocation ──\n' "$manifest_size" "$MANIFEST_MAX_CHARS"
  fi
fi

# --- locate the file (arg wins; else the workspace root this script lives in) ---
FILE="${1:-}"
if [ -z "$FILE" ]; then
  SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
  FILE="$SELF_ROOT/learnings.md"
fi
[ -f "$FILE" ] || exit 0

# --- index the entries: "date<TAB>start<TAB>end", one per heading -------------
# Zero-padded line numbers so a plain `sort -r` orders by date DESC and then by
# position DESC (later entry = newer) without a second numeric key.
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

body="$(
  printf '%s\n' "$picked" | while IFS="$(printf '\t')" read -r _d s e; do
    [ -n "$s" ] || continue
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
