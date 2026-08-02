#!/usr/bin/env bash
# Regression for the lessonPatch overflow gate: CLAUDE.md is re-sent every turn, so an oversized
# lessonPatch.text inserted verbatim is a PERMANENT per-turn tax. Past GOVERN_LESSON_MAX_CHARS,
# govern-bookkeep.sh must keep only the LEAD paragraph in CLAUDE.md (with a pointer) and move the
# FULL text into CLAUDE-APPENDIX.md under its own heading — but only when CLAUDE-APPENDIX.md
# actually exists at the meta-repo root; otherwise it must fall back to the pre-existing
# insert-everything behavior rather than lose the lesson.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T"
mkdir -p "$T/governor"

mk_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets

## #9 — some fixed bug

**Severity:** Medium

body

---
EOF
}

( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
mk_tickets
printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
( cd "$T" && git add -A && git commit -q -m init >/dev/null 2>&1 )

short_text='A short lesson under the threshold.'
long_lead='This is the lead rule sentence that should survive in CLAUDE.md.'
long_rest='This is a much longer continuation paragraph that should be pushed into the appendix file instead of living in CLAUDE.md forever, padded out with extra words so it clears whatever small threshold the test configures for this run.'
long_text="$long_lead"$'\n\n'"$long_rest"

rpt_short=$(jq -n --arg t "$short_text" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')
rpt_long=$(jq -n --arg t "$long_text" '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],lessonPatch:{file:"CLAUDE.md",anchor:null,text:$t}}')

# ── 1. under-threshold patch: unchanged behavior — full text lands in CLAUDE.md, no appendix touched ──
mk_tickets
printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
rm -f "$T/CLAUDE-APPENDIX.md"
( cd "$T" && git add -A && git commit -q -m reset1 >/dev/null 2>&1 || true )
printf '%s' "$rpt_short" \
  | GOVERN_NO_PUSH=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LESSON_MAX_CHARS=600 bash "$BK" 9 >/dev/null 2>&1
assert_contains "$(cat "$T/CLAUDE.md")" "$short_text" "under-threshold: full text inserted into CLAUDE.md verbatim"
assert_eq "$(test -f "$T/CLAUDE-APPENDIX.md" && echo y || echo n)" "n" "under-threshold: CLAUDE-APPENDIX.md not created"

# ── 2. over-threshold patch WITH CLAUDE-APPENDIX.md present: splits lead vs. full text ──
mk_tickets
printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
printf '# Appendix\n' > "$T/CLAUDE-APPENDIX.md"
( cd "$T" && git add -A && git commit -q -m reset2 >/dev/null 2>&1 || true )
printf '%s' "$rpt_long" \
  | GOVERN_NO_PUSH=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LESSON_MAX_CHARS=50 bash "$BK" 9 >/dev/null 2>&1
assert_contains "$(cat "$T/CLAUDE.md")" "$long_lead" "overflow+appendix-present: lead rule kept in CLAUDE.md"
assert_not_contains "$(cat "$T/CLAUDE.md")" "$long_rest" "overflow+appendix-present: full continuation NOT duplicated into CLAUDE.md"
assert_contains "$(cat "$T/CLAUDE.md")" "CLAUDE-APPENDIX.md" "overflow+appendix-present: CLAUDE.md carries a pointer to the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "$long_text" "overflow+appendix-present: full text landed in CLAUDE-APPENDIX.md"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "some fixed bug" "overflow+appendix-present: appendix heading derived from the ticket title"
# both files committed (not left dirty)
assert_eq "$(cd "$T" && git status --porcelain CLAUDE.md CLAUDE-APPENDIX.md | wc -l | tr -d ' ')" "0" "overflow+appendix-present: both CLAUDE.md and CLAUDE-APPENDIX.md committed"

# ── 3. over-threshold patch WITHOUT CLAUDE-APPENDIX.md: falls back to full-text-in-CLAUDE.md ──
mk_tickets
printf '# <workspace>\n\nsome existing root content.\n' > "$T/CLAUDE.md"
rm -f "$T/CLAUDE-APPENDIX.md"
( cd "$T" && git add -A && git commit -q -m reset3 >/dev/null 2>&1 || true )
printf '%s' "$rpt_long" \
  | GOVERN_NO_PUSH=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LESSON_MAX_CHARS=50 bash "$BK" 9 >/dev/null 2>&1
assert_contains "$(cat "$T/CLAUDE.md")" "$long_rest" "overflow+no-appendix: falls back to full text in CLAUDE.md (never loses the lesson)"
assert_eq "$(test -f "$T/CLAUDE-APPENDIX.md" && echo y || echo n)" "n" "overflow+no-appendix: no CLAUDE-APPENDIX.md conjured up"

assert_done
