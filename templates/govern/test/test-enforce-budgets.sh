#!/usr/bin/env bash
# #94 — `govern-bookkeep.sh --enforce-budgets` decouples context-budget enforcement from a dispatch.
#
# The lesson char cap and the CLAUDE.md total budget used to run ONLY inside a per-ticket bookkeep, so
# a fleet that stops dispatching stops enforcing: measured 2026-09-03, one fleet's root CLAUDE.md sat
# at 24,366 chars against a 14,000 budget (74% over, re-sent on every turn of ~395 sessions) purely
# because no bookkeep had run since August. Budgets are a property of the FILES, not of the run.
#
#   A. An over-budget CLAUDE.md comes back UNDER budget, and nothing is lost: every demoted section
#      lands verbatim in CLAUDE-APPENDIX.md.
#   B. The PREAMBLE (everything above the first flush-left `## `) is never touched.
#   C. A healthy file is a no-op, exit 0.
#   D. `--dry` reports without writing a byte.
#   E. No CLAUDE-APPENDIX.md means nowhere to demote TO: refuse (exit 3), never delete.
#   F. Learnings TTL (opt-in) archives an entry past the window instead of deleting it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

mk_ws() { # <T> -> a workspace whose CLAUDE.md is deliberately over a small budget
  local T="$1" i
  mkdir -p "$T/scripts/lib" "$T/queue" "$T/governor"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  mk_ws_stub "$T"
  {
    printf '# Workspace rules\n\n'
    printf 'PREAMBLE: this framing line is not a section and must survive every pass.\n\n'
    for i in 1 2 3; do
      printf '## Rule %s\n\n' "$i"
      awk -v n=900 'BEGIN{s="";while(length(s)<n)s=s "rule-body ";print s}'
      printf '\n'
    done
  } > "$T/CLAUDE.md"
  printf '# Appendix\n' > "$T/CLAUDE-APPENDIX.md"
  printf '## #1 — a\n**Severity:** High\n' > "$T/queue/tickets.md"
}

size() { wc -c < "$1" | tr -d '[:space:]'; }

# ── A — over budget in, under budget out; nothing lost ─────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
before="$(size "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
after="$(size "$T/CLAUDE.md")"
assert_eq "$rc" "0" "A1: exit 0 once the file is under budget"
if [[ "$before" -gt 1200 ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "A2: the fixture really was over budget ($before chars > 1200)"
if [[ "$after" -le 1200 ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "A3: CLAUDE.md is back UNDER budget ($after chars <= 1200)"
assert_contains "$out" "CLAUDE.md $after/1200 chars" "A4: the pass reports the final measurement"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "## Rule 1" "A5: the demoted section landed in the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "rule-body" "A6: …with its full text, not a pointer"

# ── B — the preamble is never touched ──────────────────────────────────────────────────────────
assert_contains "$(cat "$T/CLAUDE.md")" "PREAMBLE: this framing line" "B1: content above the first ## survives"
rm -rf "$T"

# ── C — a healthy file is a no-op ──────────────────────────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
printf '# Small\n\n## Rule\n\nshort.\n' > "$T/CLAUDE.md"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=14000 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "0" "C1: a healthy workspace exits 0"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "C2: …and the file is byte-identical"
rm -rf "$T"

# ── D — --dry writes nothing ───────────────────────────────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets --dry 2>&1)" || true
assert_contains "$out" "would demote" "D1: --dry names what it would move"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "D2: …and leaves CLAUDE.md byte-identical"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "D3: …and writes nothing to the appendix"
rm -rf "$T"

# ── E — no appendix means nowhere to demote to: refuse, never delete ───────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
rm -f "$T/CLAUDE-APPENDIX.md"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "3" "E1: over budget with nowhere to demote is exit 3 (doctor gates on this)"
assert_contains "$out" "nowhere to demote to" "E2: …and says exactly why"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "E3: …and never deletes a byte to hit the number"
rm -rf "$T"

# ── F — learnings TTL archives, never deletes ──────────────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
printf '# Small\n\n## Rule\n\nshort.\n' > "$T/CLAUDE.md"
cat > "$T/learnings.md" <<'LEARN'
# Learnings

preamble, never an entry.

## provider X flaky (2026-01-01)

timed out on 4 of 9 dispatches.

## measured yesterday (2026-08-30)

still true.
LEARN
out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_LEARNINGS_TTL=1 SHIPLOOP_LEARNINGS_TTL_DAYS=14 \
  SHIPLOOP_LEARNINGS_TODAY=2026-09-03 bash "$BK" --enforce-budgets 2>&1)" || true
assert_contains "$out" "archived learnings entry" "F1: an entry past the TTL window is archived"
if grep -qF 'provider X flaky' "$T/learnings.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "F2: …removed from learnings.md"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "provider X flaky" "F3: …and kept verbatim in the appendix"
assert_contains "$(cat "$T/learnings.md")" "measured yesterday" "F4: an in-window entry is untouched"
assert_contains "$(cat "$T/learnings.md")" "preamble, never an entry" "F5: the learnings preamble survives"
rm -rf "$T"

assert_done
