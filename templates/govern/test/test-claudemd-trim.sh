#!/usr/bin/env bash
# claudemd-trim.sh: evidence-based, SUGGEST-ONLY compression detection for the root CLAUDE.md.
#
# The script used to auto-move blocks it judged mechanically dead. On 2026-09-08 that silently moved
# 81 lines out of a 7,109-byte CLAUDE.md, every load-bearing anti-pattern included, because those
# rules cite hub-only paths a scaffolded workspace legitimately does not have. Nothing automatic
# edits CLAUDE.md any more.
#
#   A. An automatic run leaves CLAUDE.md and CLAUDE-APPENDIX.md BYTE-IDENTICAL, even when blocks
#      qualify as dead-citation or duplicate. Those become classified proposals instead.
#   B. Classes: dead-citation / duplicate / jit-candidate. A `judgment` block (no citations, or only
#      uncheckable ones) is never a candidate and never appears in the proposals file.
#   C. Regression for the false positive: a citation that resolves only under a templates/ tree
#      (`test/assert.sh` -> templates/govern/test/assert.sh) is LIVE, not dead.
#   D. Load-bearing guard: a block under an `## Anti-patterns (load-bearing)` heading, or whose own
#      text says load-bearing, is never proposed, and the run says how many it protected.
#   E. --apply <hash> still moves exactly one block; a stale hash and an ambiguous hash are refused.
#   F. --still-true <hash> suppresses re-proposal; editing the block's text revives it.
#   G. A corrupt verdicts file reads as unstamped, never as an error.
#   H. The suggestion line carries the candidate count when candidates exist, is absent when there
#      are none, and GOVERN_CLAUDEMD_SUGGEST=0 silences it.
#   I. `govern-bookkeep.sh --enforce-budgets` never edits CLAUDE.md, bare OR with a per-entry cap low
#      enough that the old (retired) demotion lane would have fired.
#   J. A `<placeholder>` segment and a git refspec (`origin/main`) are unproven, never dead.
#   K. A bare basename citation resolves LIVE via the suffix fallback, not just a templates/ path.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
CT="$DIR/../claudemd-trim.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# Hermetic knobs: a live fleet's exported budget values must not steer these fixtures.
unset GOVERN_LESSON_BUDGET_CHARS SHIPLOOP_CLAUDEMD_MAX_CHARS GOVERN_LESSON_MAX_CHARS GOVERN_CLAUDEMD_SUGGEST

SUGGEST="run /shiploop:compress"

mk_ws() { # <T> -> workspace stub with one live root script and one live sub-repo file
  local T="$1"
  mkdir -p "$T/governor" "$T/alpha"
  mk_ws_stub "$T"
  printf '#!/usr/bin/env bash\necho live\n' > "$T/scripts/existing.sh"
  printf 'lives in the alpha sub-repo\n' > "$T/alpha/alpha-only.md"
  printf '# Appendix\n' > "$T/CLAUDE-APPENDIX.md"
}

# The classification fixture. $1 = T, $2 = extra text woven into the judgment bullet (for the
# hash-revival case: changing it changes that block's content hash and nothing else).
write_claude() { # <T> [judgment-suffix]
  local T="$1" extra="${2:-}"
  cat > "$T/CLAUDE.md" <<MD
# Workspace rules

Preamble paragraph that frames the file.

## Rules

- live rule: run \`scripts/existing.sh\` before every dispatch, and read \`alpha-only.md\`.
- dead rule: the retired \`scripts/retired-helper.sh\` flow, gated by \`GOVERN_ZOMBIE_KNOB\`.
  Continuation line under the dead bullet, kept with it.
- no citations here: pure judgment prose that must never be proposed.$extra

Repeated paragraph appears twice in this file for the duplicate class.

Repeated paragraph appears twice in this file for the duplicate class.

## Anti-patterns (load-bearing)

- anti-pattern 12: never call \`scripts/gone-forever.sh\` unguarded.
MD
}

# ── A + B + D: an automatic run reports and classifies; it edits nothing ───────────────────────
T="$(mktemp -d)"; mk_ws "$T"; write_claude "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "3" "A1: candidates exist -> exit 3"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "A2: CLAUDE.md is BYTE-IDENTICAL after an automatic run"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "A3: CLAUDE-APPENDIX.md is untouched too"
assert_not_contains "$out" "moved dead-citation block" "A4: nothing was moved, dead citations included"
assert_not_contains "$out" "moved duplicate block" "A5: nor the duplicate"
assert_contains "$(cat "$T/CLAUDE.md")" 'dead rule: the retired' "A6: the dead-citation block is still in CLAUDE.md"
props="$(cat "$T/governor/claudemd-trim-proposals.md")"
assert_contains "$props" "Class: dead-citation" "B1: the dead-citation block is a classified proposal"
assert_contains "$props" "Class: duplicate" "B2: so is the second copy of the duplicate"
assert_contains "$props" "Class: jit-candidate" "B3: a block citing a live path is a jit-candidate"
assert_not_contains "$props" "Class: judgment" "B4: judgment is never a proposal class"
assert_not_contains "$props" "no citations here" "B5: a block with no citations is never proposed"
assert_not_contains "$props" "Preamble paragraph" "B6: nor the citation-free preamble paragraph"
assert_contains "$props" "judgment block(s) were skipped" "B7: the skipped judgment blocks are counted"
assert_not_contains "$props" "anti-pattern 12" "D1: a load-bearing block is never proposed"
assert_contains "$out" "load-bearing guard protected 1 block(s)" "D2: the guard reports how many it protected"
# mechanical classes rank above jit-candidates
dl="$(grep -n "Class: dead-citation" "$T/governor/claudemd-trim-proposals.md" | sed -n '1p' | cut -d: -f1)"
jl="$(grep -n "Class: jit-candidate" "$T/governor/claudemd-trim-proposals.md" | sed -n '1p' | cut -d: -f1)"
if [[ -n "$dl" && -n "$jl" && "$dl" -lt "$jl" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "B8: dead-citation ranks above jit-candidate"
# --dry-run writes nothing anywhere
rm -f "$T/governor/claudemd-trim-proposals.md"
out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" --dry-run 2>&1)" || true
assert_contains "$out" "would propose" "A7: --dry-run previews the candidates"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "A8: --dry-run leaves CLAUDE.md byte-identical"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "A9: --dry-run writes no proposals file"
rm -rf "$T"

# ── D (text form): a block whose own text says load-bearing is protected wherever it sits ──────
T="$(mktemp -d)"; mk_ws "$T"
cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- this rule is load-bearing: the retired `scripts/retired-helper.sh` is gone but the rule stays.
- ordinary dead rule: `scripts/also-retired.sh` is gone.
MD
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=50 bash "$CT" 2>&1)" || rc=$?
props="$(cat "$T/governor/claudemd-trim-proposals.md")"
assert_not_contains "$props" "this rule is load-bearing" "D3: a block saying load-bearing is never proposed"
assert_contains "$props" "ordinary dead rule" "D4: its neighbour is still classified normally"
assert_contains "$out" "load-bearing guard protected 1 block(s)" "D5: and the guard counts it"
rm -rf "$T"

# ── C: REGRESSION. A path that exists only under a templates/ tree is LIVE, not dead ───────────
# `test/assert.sh` is absent from a scaffolded workspace because the govern test suite is hub-only
# BY DESIGN. It lives at templates/govern/test/assert.sh in the hub. Reading that citation as dead
# is what demoted 17 load-bearing anti-patterns on 2026-09-08.
mk_hubonly() { # <T> <make-templates: 1|0>
  local T="$1" tmpl="$2"
  mk_ws "$T"
  if [[ "$tmpl" == "1" ]]; then
    mkdir -p "$T/templates/govern/test"
    printf '#!/usr/bin/env bash\n' > "$T/templates/govern/test/assert.sh"
  fi
  cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- hub only rule: the govern suite lives at `test/assert.sh` and ships from the hub, so a scaffolded
  workspace has no copy of it. The citation is correct; the file is simply not here.
MD
}
T="$(mktemp -d)"; mk_hubonly "$T" 1
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=50 bash "$CT" 2>&1)" || rc=$?
props="$(cat "$T/governor/claudemd-trim-proposals.md")"
assert_contains "$props" "hub only rule" "C1: the block is still classified"
assert_contains "$props" "Class: jit-candidate" "C2: as a jit-candidate, because its citation is LIVE"
assert_not_contains "$props" "Class: dead-citation" "C3: NOT as dead-citation (the 2026-09-08 false positive)"
assert_not_contains "$props" "every citation is dead" "C4: and no dead evidence is claimed"
rm -rf "$T"
# Control: with no templates/ tree anywhere, the same citation really is unresolvable.
T="$(mktemp -d)"; mk_hubonly "$T" 0
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=50 bash "$CT" 2>&1)" || rc=$?
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "Class: dead-citation" \
  "C5: control: without any templates/ tree the citation is genuinely dead, so the check is real"
rm -rf "$T"

# ── E: --apply moves exactly the addressed block; stale and ambiguous hashes are refused ───────
mk_jit() { # <T> -> two jit-candidates, the big one ranking first by byte size
  local T="$1"
  mk_ws "$T"
  cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- big rule: run `scripts/existing.sh` first, padded padded padded padded padded padded padded padded padded so it ranks first by byte size.
- small rule: also `scripts/existing.sh`.
MD
}
T="$(mktemp -d)"; mk_jit "$T"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
h_big="$(grep -B3 "big rule" "$T/governor/claudemd-trim-proposals.md" | grep -o '[0-9a-f]\{64\}' | sed -n '1p')"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --apply "$h_big" 2>&1)" || rc=$?
assert_eq "$rc" "0" "E1: --apply on a live hash succeeds"
if grep -qF 'big rule' "$T/CLAUDE.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "E2: the addressed block left CLAUDE.md"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "big rule" "E3: and landed in the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "(operator apply)" "E4: under the operator-apply heading"
assert_contains "$(cat "$T/CLAUDE.md")" "small rule" "E5: every other block untouched"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --apply "$h_big" 2>&1)" || rc=$?
assert_eq "$rc" "1" "E6: re-applying the moved block's hash is refused (no longer matches)"
assert_contains "$out" "refusing" "E7: and says so"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "E8: a refused --apply changes nothing"
rm -rf "$T"
# Ambiguity: two identical paragraphs share one content hash, so --apply cannot pick one.
T="$(mktemp -d)"; mk_ws "$T"
cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

Repeated paragraph appears twice in this file.

Repeated paragraph appears twice in this file.
MD
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=50 bash "$CT" >/dev/null 2>&1 || rc=$?
h_dup="$(grep -o '[0-9a-f]\{64\}' "$T/governor/claudemd-trim-proposals.md" | sed -n '1p')"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --apply "$h_dup" 2>&1)" || rc=$?
assert_eq "$rc" "1" "E9: an ambiguous hash (two identical blocks) is refused"
assert_contains "$out" "matches 2 blocks" "E10: and names the ambiguity"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "E11: the refusal changed nothing"
rm -rf "$T"

# ── F: --still-true suppresses re-proposal; editing the text revives it ────────────────────────
T="$(mktemp -d)"; mk_jit "$T"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
h_small="$(grep -B3 "small rule" "$T/governor/claudemd-trim-proposals.md" | grep -o '[0-9a-f]\{64\}' | sed -n '1p')"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --still-true "$h_small" 2>&1)" || rc=$?
assert_eq "$rc" "0" "F1: --still-true records a verdict"
assert_eq "$(jq -r --arg h "$h_small" '.[$h].verdict' "$T/governor/claudemd-verdicts.json")" "still-true" "F2: verdict stored under the block's full hash"
if [[ -n "$(jq -r --arg h "$h_small" '.[$h].ts // empty' "$T/governor/claudemd-verdicts.json")" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "F3: with a timestamp"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
if grep -qF "$h_small" "$T/governor/claudemd-trim-proposals.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "F4: a stamped block is not re-proposed"
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "stamped still-true were skipped" "F5: the skip is visible in the proposals file"
# Edit the block's text: the hash changes, the verdict no longer covers it, the proposal revives.
sed -e 's/small rule: also/small rule, reworded: also/' "$T/CLAUDE.md" > "$T/CLAUDE.md.new"
mv "$T/CLAUDE.md.new" "$T/CLAUDE.md"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "small rule, reworded" "F6: editing the text revives the proposal under a new hash"
if grep -qF "$h_small" "$T/governor/claudemd-trim-proposals.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "F7: the dead verdict's old hash matches nothing"

# ── G: a corrupt verdicts file reads as unstamped ──────────────────────────────────────────────
printf '{this is not json' > "$T/governor/claudemd-verdicts.json"
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "3" "G1: a corrupt verdicts file is not an error"
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "small rule, reworded" "G2: every block reads as unstamped again"
rm -rf "$T"

# ── H: the suggestion line ─────────────────────────────────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"; write_claude "$T"
out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || true
n="$(grep -c '^- `' "$T/governor/claudemd-trim-proposals.md" || true)"
assert_contains "$out" "$n compression candidate(s) - $SUGGEST" "H1: the suggestion line carries the real candidate count"
assert_contains "$out" "CLAUDE.md $(wc -c < "$T/CLAUDE.md" | tr -d '[:space:]')/100 chars" "H2: and the measured size against the budget"
out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 GOVERN_CLAUDEMD_SUGGEST=0 bash "$CT" 2>&1)" || true
assert_not_contains "$out" "$SUGGEST" "H3: GOVERN_CLAUDEMD_SUGGEST=0 silences the line"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "H4: …but the candidates file is still written"
# Under budget: no suggestion at all, and a stale proposals file is cleared.
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100000 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "0" "H5: under budget exits 0"
assert_not_contains "$out" "$SUGGEST" "H6: and says nothing about compressing"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "H7: the stale candidates file is removed"
rm -rf "$T"
# Over budget with nothing but judgment blocks: no candidates, no suggestion, exit 0.
T="$(mktemp -d)"; mk_ws "$T"
cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- pure judgment: think before you dispatch, and say what you actually measured.
- more judgment: the least flattering true version goes first.
MD
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=50 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "0" "H8: over budget with zero candidates is exit 0, not an alarm from this script"
assert_contains "$out" "no compression candidate(s)" "H9: and says there is nothing mechanical left"
assert_not_contains "$out" "$SUGGEST" "H10: no suggestion when there is nothing to suggest"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "H11: and no empty candidates file is left behind"
rm -rf "$T"

# ── I: govern-bookkeep --enforce-budgets never edits CLAUDE.md ─────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
mkdir -p "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
printf '## #1 : a\n**Severity:** High\n' > "$T/queue/tickets.md"
write_claude "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=100 GOVERN_LESSON_MAX_CHARS=100000 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "3" "I1: the budget alarm still fires when the file stays over"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "I2: bookkeep's trim call left CLAUDE.md byte-identical"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "I3: and the appendix untouched"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "I4: it wrote classified candidates instead"
assert_contains "$out" "/shiploop:compress" "I5: the STILL OVER message points at the compress playbook"
assert_contains "$(cat "$T/CLAUDE.md")" "no citations here" "I6: no blind eviction: every block stayed put"
# A per-entry cap low enough that the RETIRED demotion lane would have fired: this is the loophole a
# prior attempt at #110 left open (it gated the demote behind a --report flag that only run-loop.sh's
# call passed, so a bare `npm run govern:budgets` still silently demoted). There is no writer left
# here at all now, bare or not.
rm -f "$T/governor/claudemd-trim-proposals.md"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=100 GOVERN_LESSON_MAX_CHARS=10 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "3" "I7: a bare call with a tiny per-entry cap still raises the over-budget alarm"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "I8: BARE (no flag) leaves CLAUDE.md byte-identical even with the lesson cap at 10 chars"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "I9: and demotes nothing into the appendix"
assert_contains "$out" "report only" "I10: and says it is a report"
assert_contains "$out" "$SUGGEST" "I11: and suggests /shiploop:compress"
assert_contains "$out" "section(s) exceed GOVERN_LESSON_MAX_CHARS" "I12: the oversized section is still named, informationally"
rm -rf "$T"

# ── J: a placeholder segment and a git refspec are unproven, never dead ────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- see `logs/investigations/<bug>/` for the evidence trail, and compare against `origin/main`.
MD
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=10 bash "$CT" 2>&1)" || rc=$?
props="$(cat "$T/governor/claudemd-trim-proposals.md" 2>/dev/null || true)"
assert_not_contains "$props" "investigations" "J1: a block citing only a placeholder + a refspec is never proposed (both unproven, so it reads as judgment)"
assert_contains "$out" "no compression candidate(s)" "J2: it is counted as judgment, not silently dropped as if it were live or dead"
rm -rf "$T"

# ── K: a bare basename resolves LIVE via the suffix fallback, not only under templates/ ────────
T="$(mktemp -d)"; mk_ws "$T"
mkdir -p "$T/alpha/scripts"
printf '#!/usr/bin/env bash\n' > "$T/alpha/scripts/check-indexed-urls-live.sh"
cat > "$T/CLAUDE.md" <<'MD'
# Workspace rules

## Rules

- run `check-indexed-urls-live.sh` before publishing (named by basename, lives in a sub-repo's
  nested scripts/ dir, not at any workspace or sub-repo ROOT).
MD
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=10 bash "$CT" 2>&1)" || rc=$?
props="$(cat "$T/governor/claudemd-trim-proposals.md" 2>/dev/null || true)"
assert_contains "$props" "Class: jit-candidate" "K1: the basename citation resolves LIVE (suffix fallback), so it's a jit-candidate"
assert_not_contains "$props" "Class: dead-citation" "K2: NOT dead-citation (this is the aquanode false-positive class)"
rm -rf "$T"

assert_done
