#!/usr/bin/env bash
# #94 — `govern-bookkeep.sh --enforce-budgets` decouples context-budget enforcement from a dispatch.
#
# The lesson char cap and the CLAUDE.md total budget used to run ONLY inside a per-ticket bookkeep, so
# a fleet that stops dispatching stops enforcing: measured 2026-09-03, one fleet's root CLAUDE.md sat
# at 24,366 chars against a 14,000 budget (74% over, re-sent on every turn of ~395 sessions) purely
# because no bookkeep had run since August. Budgets are a property of the FILES, not of the run.
#
#   A. An over-budget CLAUDE.md STAYS over budget (exit 3, alarm) and byte-identical: #110 retired
#      the demotion this test originally covered — see test-claudemd-trim.sh test I for the
#      "never edits CLAUDE.md, bare or with a tiny per-entry cap" regression coverage.
#   B. The PREAMBLE (everything above the first flush-left `## `) is never touched (trivially true
#      now nothing in this file touches CLAUDE.md, but still worth pinning).
#   C. A healthy file is a no-op, exit 0.
#   D. `--dry` reports without writing a byte, same as a non-dry run.
#   E. No CLAUDE-APPENDIX.md is no longer a blocker for the CLAUDE.md report path at all (only
#      `claudemd-trim.sh --apply` still needs one) — the alarm fires and CLAUDE.md is untouched.
#   F. Learnings TTL (opt-in) archives an entry past the window instead of deleting it — the one
#      lane in this script that still writes anything, and out of #110's scope (not CLAUDE.md).
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

# ── A — over budget in, STILL over budget out; nothing lost, nothing edited ─────────────────────
T="$(mktemp -d)"; mk_ws "$T"
before="$(size "$T/CLAUDE.md")"
preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
after="$(size "$T/CLAUDE.md")"
assert_eq "$rc" "3" "A1: exit 3 (alarm) while the file stays over budget — this script never fixes it"
if [[ "$before" -gt 1200 ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "A2: the fixture really was over budget ($before chars > 1200)"
assert_eq "$after" "$before" "A3: CLAUDE.md is BYTE-IDENTICAL, still over the 1200 budget — nothing demotes it any more"
assert_contains "$out" "CLAUDE.md $after/1200 chars" "A4: the pass reports the final measurement"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "A5: CLAUDE-APPENDIX.md is untouched: nothing is demoted into it from here"
assert_contains "$out" "/shiploop:compress" "A6: the alarm message points at the operator playbook, not a fixed number"

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

# ── D — --dry writes nothing (same as non-dry: nothing ever writes to CLAUDE.md here) ───────────
T="$(mktemp -d)"; mk_ws "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets --dry 2>&1)" || rc=$?
assert_eq "$rc" "3" "D1: --dry still raises the same alarm as a non-dry run"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "D2: …and leaves CLAUDE.md byte-identical"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "D3: …and writes nothing to the appendix"
rm -rf "$T"

# ── E — no CLAUDE-APPENDIX.md is no longer a blocker: report path needs nowhere to write ────────
T="$(mktemp -d)"; mk_ws "$T"
rm -f "$T/CLAUDE-APPENDIX.md"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=1200 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "3" "E1: over budget still alarms (exit 3, doctor gates on this) even with no appendix"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "E2: …and never deletes a byte to hit the number"
if [[ -f "$T/CLAUDE-APPENDIX.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "E3: …and does not conjure an appendix into existence either — this path never writes one"
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
