#!/usr/bin/env bash
# claudemd-trim.sh: evidence-based, reversible, two-lane trimming for the root CLAUDE.md.
# Replaces the blind largest-first eviction inside `govern-bookkeep.sh --enforce-budgets`.
#
#   A. A block whose EVERY citation is provably dead (path absent from root and every sub-repo,
#      knob mentioned nowhere under scripts/ or templates/) is auto-moved to CLAUDE-APPENDIX.md
#      with its full text, continuation lines included.
#   B. A block citing an EXISTING path (root or sub-repo) is untouched; a block with NO citations
#      is never auto-moved.
#   C. Exact duplicates are deduped keeping the FIRST copy; a fenced block moves whole, fences
#      intact in the appendix.
#   D. Over budget with nothing provable: proposals are written (largest first) and CLAUDE.md is
#      byte-identical. --dry-run changes nothing anywhere.
#   E. --apply <hash> moves exactly the addressed block; a stale hash is refused.
#   F. --still-true <hash> suppresses re-proposal; editing the block's text revives the proposal
#      (the verdict is keyed by content hash, so it dies with the text it covered).
#   G. A corrupt verdicts file reads as unstamped, never as an error.
#   H. GOVERN_TRIM_DEAD=0 skips lane 1 (auto) entirely, leaving proposals only.
#   I. `govern-bookkeep.sh --enforce-budgets` drives the trim: dead blocks move, the rest becomes
#      proposals, and the budget alarm (exit 3) still fires when the file stays over.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
CT="$DIR/../claudemd-trim.sh"
BK="$DIR/../govern-bookkeep.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# Hermetic knobs: a live fleet's exported budget/kill-switch values must not steer these fixtures.
unset GOVERN_TRIM_DEAD GOVERN_LESSON_BUDGET_CHARS SHIPLOOP_CLAUDEMD_MAX_CHARS GOVERN_LESSON_MAX_CHARS

mk_ws() { # <T> -> workspace stub with one live root script and one live sub-repo file
  local T="$1"
  mkdir -p "$T/governor" "$T/alpha"
  mk_ws_stub "$T"
  printf '#!/usr/bin/env bash\necho live\n' > "$T/scripts/existing.sh"
  printf 'lives in the alpha sub-repo\n' > "$T/alpha/alpha-only.md"
  printf '# Appendix\n' > "$T/CLAUDE-APPENDIX.md"
}

# The lane-1 fixture. $1 = T, $2 = extra text woven into the judgment bullet (for the hash-revival
# case: changing it changes that block's content hash and nothing else).
write_claude() { # <T> [judgment-suffix]
  local T="$1" extra="${2:-}"
  cat > "$T/CLAUDE.md" <<MD
# Workspace rules

Preamble paragraph that frames the file.

## Rules

- live rule: run \`scripts/existing.sh\` before every dispatch, and read \`alpha-only.md\`.
- dead rule: the retired \`scripts/retired-helper.sh\` flow, gated by \`GOVERN_ZOMBIE_KNOB\`.
  Continuation line under the dead bullet, kept with it.
- no citations here: pure judgment prose that must never auto-move.$extra

Repeated paragraph appears twice in this file for the duplicate lane.

Repeated paragraph appears twice in this file for the duplicate lane.

\`\`\`bash
echo fenced block one
\`\`\`

\`\`\`bash
echo fenced block one
\`\`\`
MD
}

# ── A + B + C: lane 1: dead citations move, live/no-citation blocks stay, dups dedupe ─────────
T="$(mktemp -d)"; mk_ws "$T"; write_claude "$T"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "0" "A1: under-budget run exits 0 (lane 1 still ran)"
assert_contains "$out" "moved dead-citation block" "A2: the dead-citation move is reported"
if grep -qF 'dead rule:' "$T/CLAUDE.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "A3: the dead-citation block left CLAUDE.md"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "(dead citations)" "A4: appendix has the dated dead-citations heading"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" 'dead rule: the retired `scripts/retired-helper.sh` flow' "A5: full block text landed in the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "Continuation line under the dead bullet" "A6: the bullet's continuation line moved with it"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "moved from CLAUDE.md" "A7: provenance names the source file"
assert_contains "$(cat "$T/CLAUDE.md")" 'live rule: run `scripts/existing.sh`' "B1: a block citing an existing root path is untouched"
assert_contains "$(cat "$T/CLAUDE.md")" 'read `alpha-only.md`' "B2: a sub-repo path counts as existing too"
assert_contains "$(cat "$T/CLAUDE.md")" "no citations here: pure judgment prose" "B3: a block with no citations is never auto-moved"
assert_eq "$(grep -cF 'Repeated paragraph appears twice' "$T/CLAUDE.md")" "1" "C1: duplicate deduped, first copy kept"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "(duplicate)" "C2: the duplicate landed under the duplicate heading"
assert_eq "$(grep -c '^```' "$T/CLAUDE.md")" "2" "C3: one fenced block (both fences) kept in CLAUDE.md"
assert_eq "$(grep -c '^```' "$T/CLAUDE-APPENDIX.md")" "2" "C4: the moved fenced block is whole (both fences) in the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "echo fenced block one" "C5: with its content intact"
rm -rf "$T"

# ── D: over budget with nothing provable: proposals only, CLAUDE.md byte-identical ────────────
mk_clean() { # <T> -> no dead citations, no duplicates; big judgment block first when ranked by size
  local T="$1"
  mk_ws "$T"
  cat > "$T/CLAUDE.md" <<MD
# Workspace rules

## Rules

- live rule: run \`scripts/existing.sh\` before every dispatch.
- big judgment block with no citations at all, padded padded padded padded padded padded padded padded so it ranks first by byte size.
- small judgment block.
MD
}
T="$(mktemp -d)"; mk_clean "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "3" "D1: still over budget exits 3 (the alarm survives)"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "D2: proposals file written"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "D3: CLAUDE.md byte-identical (lane 2 never edits)"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "D4: appendix untouched"
props="$(cat "$T/governor/claudemd-trim-proposals.md")"
assert_contains "$props" "no citations: judgment call" "D5: no-citation candidates say judgment call"
assert_contains "$props" "cannot auto-prove dead" "D6: live-citation candidates say why lane 1 could not act"
big_ln="$(grep -n "big judgment block" "$T/governor/claudemd-trim-proposals.md" | sed -n '1p' | cut -d: -f1)"
small_ln="$(grep -n "small judgment block" "$T/governor/claudemd-trim-proposals.md" | sed -n '1p' | cut -d: -f1)"
if [[ -n "$big_ln" && -n "$small_ln" && "$big_ln" -lt "$small_ln" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "D7: candidates ranked largest first"
# --dry-run: reports both lanes, writes nothing
rm -f "$T/governor/claudemd-trim-proposals.md"
out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" --dry-run 2>&1)" || true
assert_contains "$out" "would propose" "D8: --dry-run previews lane 2"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "D9: --dry-run leaves CLAUDE.md byte-identical"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "D10: --dry-run writes no proposals file"
rm -rf "$T"

# ── E: --apply moves exactly the addressed block; a stale hash is refused ─────────────────────
T="$(mktemp -d)"; mk_clean "$T"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
h_big="$(grep -B2 "big judgment block" "$T/governor/claudemd-trim-proposals.md" | grep -o '[0-9a-f]\{64\}' | sed -n '1p')"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --apply "$h_big" 2>&1)" || rc=$?
assert_eq "$rc" "0" "E1: --apply on a live hash succeeds"
if grep -qF 'big judgment block' "$T/CLAUDE.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "E2: the addressed block left CLAUDE.md"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "big judgment block" "E3: and landed in the appendix"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "(operator apply)" "E4: under the operator-apply heading"
assert_contains "$(cat "$T/CLAUDE.md")" "small judgment block" "E5: every other block untouched"
assert_contains "$(cat "$T/CLAUDE.md")" 'live rule: run `scripts/existing.sh`' "E6: including the live-citation one"
pre="$(cat "$T/CLAUDE.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" bash "$CT" --apply "$h_big" 2>&1)" || rc=$?
assert_eq "$rc" "1" "E7: re-applying the moved block's hash is refused (no longer matches)"
assert_contains "$out" "refusing" "E8: and says so"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "E9: a refused --apply changes nothing"
rm -rf "$T"

# ── F: --still-true suppresses re-proposal; editing the text revives it ───────────────────────
T="$(mktemp -d)"; mk_clean "$T"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
h_small="$(grep -B2 "small judgment block" "$T/governor/claudemd-trim-proposals.md" | grep -o '[0-9a-f]\{64\}' | sed -n '1p')"
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
sed -e 's/small judgment block\./small judgment block, reworded./' "$T/CLAUDE.md" > "$T/CLAUDE.md.new"
mv "$T/CLAUDE.md.new" "$T/CLAUDE.md"
rc=0; GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" >/dev/null 2>&1 || rc=$?
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "small judgment block, reworded" "F6: editing the text revives the proposal under a new hash"
if grep -qF "$h_small" "$T/governor/claudemd-trim-proposals.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "F7: the dead verdict's old hash matches nothing"

# ── G: a corrupt verdicts file reads as unstamped ─────────────────────────────────────────────
printf '{this is not json' > "$T/governor/claudemd-verdicts.json"
rc=0; out="$(GOVERN_WS_ROOT="$T" SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "3" "G1: a corrupt verdicts file is not an error"
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "small judgment block" "G2: every block reads as unstamped again"
rm -rf "$T"

# ── H: GOVERN_TRIM_DEAD=0 skips lane 1, proposals only ────────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"; write_claude "$T"
pre="$(cat "$T/CLAUDE.md")"; preap="$(cat "$T/CLAUDE-APPENDIX.md")"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_TRIM_DEAD=0 SHIPLOOP_CLAUDEMD_MAX_CHARS=100 bash "$CT" 2>&1)" || rc=$?
assert_eq "$rc" "3" "H1: kill switch on, still-over exits 3"
assert_contains "$out" "disabled by GOVERN_TRIM_DEAD=0" "H2: the disabled lane is reported"
assert_eq "$(cat "$T/CLAUDE.md")" "$pre" "H3: nothing auto-moved (dead block included)"
assert_eq "$(cat "$T/CLAUDE-APPENDIX.md")" "$preap" "H4: appendix untouched"
assert_contains "$(cat "$T/governor/claudemd-trim-proposals.md")" "GOVERN_TRIM_DEAD=0" "H5: the provably-dead block is proposed with its evidence instead"
rm -rf "$T"

# ── I: govern-bookkeep --enforce-budgets drives the trim ──────────────────────────────────────
T="$(mktemp -d)"; mk_ws "$T"
mkdir -p "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
printf '## #1 : a\n**Severity:** High\n' > "$T/queue/tickets.md"
write_claude "$T"
rc=0; out="$(GOVERN_WS_ROOT="$T" GOVERN_LESSON_BUDGET_CHARS=100 GOVERN_LESSON_MAX_CHARS=100000 bash "$BK" --enforce-budgets 2>&1)" || rc=$?
assert_eq "$rc" "3" "I1: the budget alarm still fires when proposals are all that is left"
if grep -qF 'dead rule:' "$T/CLAUDE.md"; then f=1; else f=0; fi
assert_eq "$f" "0" "I2: bookkeep's trim call moved the provably dead block"
assert_contains "$(cat "$T/CLAUDE-APPENDIX.md")" "(dead citations)" "I3: into the appendix"
if [[ -f "$T/governor/claudemd-trim-proposals.md" ]]; then f=1; else f=0; fi
assert_eq "$f" "1" "I4: and wrote proposals for the unprovable rest"
assert_contains "$out" "claudemd-trim-proposals.md" "I5: the STILL OVER message points at the proposals file"
assert_contains "$(cat "$T/CLAUDE.md")" "no citations here" "I6: no blind eviction: the unprovable block stayed put"
rm -rf "$T"

assert_done
