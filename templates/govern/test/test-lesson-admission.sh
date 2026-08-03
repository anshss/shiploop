#!/usr/bin/env bash
# Regression for the #87 always-on context ratchet gates in govern-bookkeep.sh.
#
# The problem these encode: promotion into root CLAUDE.md is automatic, removal is a human noticing.
# GOVERN_LESSON_MAX_CHARS caps how BIG one lesson may be; nothing caps how MANY. The three gates
# below add an admission test and an eviction, and every one of them must SHIP INERT — the default
# behaviour has to stay byte-for-byte what it was, so this file asserts the OFF direction as hard as
# the ON direction.
#
# Covered:
#   - defaults (no knobs set): a lesson still lands in CLAUDE.md, appendix untouched
#   - GOVERN_LESSON_SINK=appendix: unclaimed lesson -> appendix ONLY (nothing in CLAUDE.md)
#   - GOVERN_LESSON_SINK=appendix: a complete always-on claim (alwaysOn+frequency+reversibility)
#     still takes the CLAUDE.md slot; a PARTIAL claim does not
#   - GOVERN_LESSON_LADDER=1: rung must be "always-on" AND carry rungWhyNot
#   - GOVERN_LESSON_EVICT=1 under budget: no eviction demanded
#   - GOVERN_LESSON_EVICT=1 at budget WITHOUT .evicts -> appendix, incumbent untouched
#   - GOVERN_LESSON_EVICT=1 at budget WITH a matching .evicts -> incumbent REMOVED, lesson promoted
#   - .evicts that matches zero or many lines is a refusal, never a guess
#   - no CLAUDE-APPENDIX.md present: every gate is skipped (a lesson is never lost)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T"
mkdir -p "$T/governor"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

LESSON='Never mutate an open PR with gh pr edit — it fails silently.'

mk_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets

## #9 — gh pr edit silently no-ops

**Severity:** Medium

body

---
EOF
}

# A CLAUDE.md with two distinguishable incumbents: a bullet rule (with an indented continuation)
# and a `##` section. Both are eviction targets of different shapes.
mk_claude() { cat > "$T/CLAUDE.md" <<'EOF'
# <workspace>

## Anti-patterns

- INCUMBENT_BULLET — the weakest incumbent rule.
  continuation line that belongs to the bullet
- KEEPER_BULLET — must survive every eviction.

## INCUMBENT_SECTION

section body that must go with its heading

## KEEPER_SECTION

keeper body
EOF
}

reset_ws() { # [with-appendix]
  mk_tickets
  mk_claude
  if [[ "${1:-yes}" == "yes" ]]; then printf '# Appendix\n' > "$T/CLAUDE-APPENDIX.md"
  else rm -f "$T/CLAUDE-APPENDIX.md"; fi
  ( cd "$T" && git add -A && git commit -q -m reset >/dev/null 2>&1 || true )
}

# report builder: $1 = extra lessonPatch fields as a jq object expression (or 'null')
rpt() { # <extra-jq-object>
  jq -n --arg t "$LESSON" --argjson extra "$1" \
    '{status:"resolved",pr:{repo:"alpha",number:1},newTickets:[],
      lessonPatch:({file:"CLAUDE.md",anchor:null,text:$t} + $extra)}'
}

run() { # <report-json> <env-assignments...>
  local r="$1"; shift
  printf '%s' "$r" | env GOVERN_NO_PUSH=1 GOVERN_TICKETS_FILE="$T/tickets.md" "$@" bash "$BK" 9 >/dev/null 2>&1
}

# ── 1. DEFAULTS: ships inert — unchanged behaviour ───────────────────────────
reset_ws yes
run "$(rpt '{}')"
assert_contains "$(cat "$T/CLAUDE.md")" "$LESSON" "defaults: lesson still lands in CLAUDE.md (gates ship inert)"
assert_not_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "defaults: appendix untouched"
assert_contains "$(cat "$T/CLAUDE.md")" "INCUMBENT_BULLET" "defaults: nothing is ever evicted"

# ── 2. SINK INVERSION: appendix is the default target ────────────────────────
reset_ws yes
run "$(rpt '{}')" GOVERN_LESSON_SINK=appendix
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "sink=appendix: unclaimed lesson lands in the appendix"
assert_not_contains "$(cat "$T/CLAUDE.md")"          "$LESSON" "sink=appendix: nothing inserted into always-on CLAUDE.md"
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "gh pr edit silently no-ops" "sink=appendix: appendix heading derived from the ticket title"
assert_eq "$(cd "$T" && git status --porcelain CLAUDE.md CLAUDE-APPENDIX.md | wc -l | tr -d ' ')" "0" \
  "sink=appendix: the appendix write is committed, not left dirty"

# a COMPLETE always-on claim buys the always-on slot back
reset_ws yes
run "$(rpt '{"alwaysOn":true,"frequency":"every multi-repo PR pair, ~weekly","reversibility":"silent: gh reports success and the base is unchanged"}')" \
    GOVERN_LESSON_SINK=appendix
assert_contains     "$(cat "$T/CLAUDE.md")"          "$LESSON" "sink=appendix + full claim: takes the always-on slot"
assert_not_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "sink=appendix + full claim: not double-written to the appendix"

# a PARTIAL claim (severity stated, frequency missing) does NOT
reset_ws yes
run "$(rpt '{"alwaysOn":true,"reversibility":"silent failure"}')" GOVERN_LESSON_SINK=appendix
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "sink=appendix + partial claim (no .frequency): demoted to the appendix"
assert_not_contains "$(cat "$T/CLAUDE.md")"          "$LESSON" "sink=appendix + partial claim: kept out of CLAUDE.md"

# ── 3. LADDER: guard > lint/test > appendix > always-on ──────────────────────
reset_ws yes
run "$(rpt '{"rung":"lint"}')" GOVERN_LESSON_LADDER=1
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "ladder: rung=lint routes to the appendix, not always-on"
assert_not_contains "$(cat "$T/CLAUDE.md")"          "$LESSON" "ladder: a lower rung never takes the always-on slot"

reset_ws yes
run "$(rpt '{"rung":"always-on"}')" GOVERN_LESSON_LADDER=1
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "ladder: rung=always-on WITHOUT rungWhyNot is still demoted"

reset_ws yes
run "$(rpt '{"rung":"always-on","rungWhyNot":"no lint can see a GraphQL call that exits 0"}')" GOVERN_LESSON_LADDER=1
assert_contains     "$(cat "$T/CLAUDE.md")"          "$LESSON" "ladder: declared top rung + justification takes the always-on slot"
assert_not_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON" "ladder: satisfied gate does not also write the appendix"

# ── 4. FORCED EVICTION ───────────────────────────────────────────────────────
# 4a. UNDER budget: no eviction demanded, unchanged behaviour.
reset_ws yes
run "$(rpt '{}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=100000
assert_contains "$(cat "$T/CLAUDE.md")" "$LESSON"           "evict under budget: lesson promoted normally"
assert_contains "$(cat "$T/CLAUDE.md")" "INCUMBENT_BULLET"  "evict under budget: no eviction demanded"

# 4b. AT budget WITHOUT .evicts: demoted; the file does NOT grow and no incumbent is harmed.
reset_ws yes
run "$(rpt '{}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON"          "evict at budget, no .evicts: demoted to the appendix"
assert_not_contains "$(cat "$T/CLAUDE.md")"          "$LESSON"          "evict at budget, no .evicts: CLAUDE.md does not grow"
assert_contains     "$(cat "$T/CLAUDE.md")"          "INCUMBENT_BULLET" "evict at budget, no .evicts: incumbents untouched"

# 4c. AT budget WITH a matching .evicts (bullet rule): incumbent removed, lesson promoted.
reset_ws yes
run "$(rpt '{"evicts":"INCUMBENT_BULLET"}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
claude_now="$(cat "$T/CLAUDE.md")"
assert_contains     "$claude_now" "$LESSON"          "evict at budget + named incumbent: lesson promoted to CLAUDE.md"
assert_not_contains "$claude_now" "INCUMBENT_BULLET" "evict at budget + named incumbent: the named bullet is GONE"
assert_not_contains "$claude_now" "continuation line that belongs to the bullet" \
  "evict: the bullet's indented continuation goes with it"
assert_contains     "$claude_now" "KEEPER_BULLET"    "evict: the neighbouring bullet survives"
assert_contains     "$claude_now" "KEEPER_SECTION"   "evict: unrelated sections survive"

# 4d. AT budget WITH a matching .evicts (heading): the heading AND its body go, next heading survives.
reset_ws yes
run "$(rpt '{"evicts":"## INCUMBENT_SECTION"}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
claude_now="$(cat "$T/CLAUDE.md")"
assert_contains     "$claude_now" "$LESSON"                                "evict heading: lesson promoted"
assert_not_contains "$claude_now" "INCUMBENT_SECTION"                      "evict heading: the named section heading is gone"
assert_not_contains "$claude_now" "section body that must go with its heading" "evict heading: its body goes with it"
assert_contains     "$claude_now" "KEEPER_SECTION"                         "evict heading: the following section survives"
assert_contains     "$claude_now" "keeper body"                            "evict heading: the following body survives"

# 4e. .evicts naming something absent -> refusal (demote), never a silent no-op promotion.
reset_ws yes
run "$(rpt '{"evicts":"NO_SUCH_RULE_ANYWHERE"}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON"          "evict: unmatched .evicts is a refusal -> appendix"
assert_not_contains "$(cat "$T/CLAUDE.md")"          "$LESSON"          "evict: unmatched .evicts does not grow CLAUDE.md"
assert_contains     "$(cat "$T/CLAUDE.md")"          "INCUMBENT_BULLET" "evict: unmatched .evicts deletes nothing"

# 4f. .evicts matching MANY lines -> refusal (never guess which one).
reset_ws yes
run "$(rpt '{"evicts":"KEEPER"}')" GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
claude_now="$(cat "$T/CLAUDE.md")"
assert_contains     "$(cat "$T/CLAUDE-APPENDIX.md")" "$LESSON"        "evict: ambiguous .evicts (2 matches) is a refusal -> appendix"
assert_contains     "$claude_now" "KEEPER_BULLET"                     "evict: ambiguous .evicts deletes neither match (bullet)"
assert_contains     "$claude_now" "KEEPER_SECTION"                    "evict: ambiguous .evicts deletes neither match (section)"

# ── 5. NO APPENDIX PRESENT: every gate is skipped — a lesson is never lost ───
reset_ws no
run "$(rpt '{}')" GOVERN_LESSON_SINK=appendix GOVERN_LESSON_LADDER=1 GOVERN_LESSON_EVICT=1 GOVERN_LESSON_BUDGET_CHARS=10
assert_contains "$(cat "$T/CLAUDE.md")" "$LESSON" "no appendix on disk: all gates skipped, lesson still lands (never lost)"
assert_eq "$(test -f "$T/CLAUDE-APPENDIX.md" && echo y || echo n)" "n" "no appendix on disk: none conjured up"

assert_done
