#!/usr/bin/env bash
# validation-record.sh: the standalone validation-evidence sink writer (#252, generalized). Proves:
#   1. writes .claude/shiploop/validation/ticket-<N>-<slug>.md, with the PR(s) and evidence in it.
#   2. the slug rule EXACTLY matches land-resolution.sh's #252 promotion (lowercase,
#      non-alphanumerics -> '-', collapse + trim, cap 60 chars, "validation" fallback).
#   3. NEVER clobbers an existing file: a second call with different evidence leaves it untouched,
#      but still prints the (unchanged) path.
#   4. honours the kill switch: GOVERN_VALIDATION_RECORD=0 is a silent no-op (nothing written,
#      nothing printed, exit 0).
#   5. --evidence-file reads evidence from a file; --print-path-only never writes.
#   6. required-argument validation: missing --ticket/--title/--evidence all refuse (non-zero exit).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
VR="$DIR/../validation-record.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T"     # keep tickets.md at the sandbox root (govern::meta_root needs a
                                  # real dir + a git toplevel to resolve against; mirrors
                                  # test-validation-promote.sh's fixture exactly)
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# ── 1. fresh write ──────────────────────────────────────────────────────────────────────────────
out="$(bash "$VR" --gating machine --ticket 40 --title "VALIDATION: does cross-provider restore round-trip" \
  --evidence "deploy 3045, restore, sha256 match, PASS" --pr alpha#99 --source "governor resolve (run r1)")"
rc=$?
assert_eq "$rc" "0" "1. exits 0 on a fresh write"
assert_eq "$out" ".claude/shiploop/validation/ticket-40-validation-does-cross-provider-restore-round-trip.md" \
  "2. printed path uses the EXACT #252 slug rule"
vfile="$T/$out"
assert_eq "$(test -f "$vfile" && echo y || echo n)" "y" "1. the file actually exists on disk"
assert_contains "$(cat "$vfile")" "sha256 match, PASS" "1. file body carries the evidence"
assert_contains "$(cat "$vfile")" "alpha#99" "1. file body lists the PR"
assert_contains "$(cat "$vfile")" "governor resolve (run r1)" "1. file body names the --source caller"
assert_contains "$(cat "$vfile")" "Ticket #40" "1. file heading names the ticket"

# ── 3. never clobbers ───────────────────────────────────────────────────────────────────────────
out2="$(bash "$VR" --source "test" --gating machine --ticket 40 --title "VALIDATION: does cross-provider restore round-trip" \
  --evidence "TOTALLY DIFFERENT text that must never land")"
rc2=$?
assert_eq "$rc2" "0" "3. re-running for the same ticket still exits 0"
assert_eq "$out2" "$out" "3. re-running prints the SAME path (kept, not moved)"
assert_not_contains "$(cat "$vfile")" "TOTALLY DIFFERENT text that must never land" \
  "3. the original file content is untouched (never clobbered)"

# ── 2b. slug fallback: a title with nothing alphanumeric falls back to \"validation\" ────────────
out3="$(bash "$VR" --ticket 41 --title "!!!" --evidence "x" --source "test" --gating self)"
assert_eq "$out3" ".claude/shiploop/validation/ticket-41-validation.md" \
  "2b. an all-punctuation title falls back to the 'validation' slug"

# ── 5a. --evidence-file ─────────────────────────────────────────────────────────────────────────
efile="$T/evidence.txt"
printf 'multi-line\nevidence body, PASS\n' > "$efile"
out4="$(bash "$VR" --ticket 42 --title "SPIKE: does caching help" --evidence-file "$efile" --source "test" --gating self)"
assert_contains "$(cat "$T/$out4")" "multi-line" "5a. --evidence-file content lands in the body"
assert_contains "$(cat "$T/$out4")" "evidence body, PASS" "5a. --evidence-file body is complete"

# ── 5b. --print-path-only never writes ──────────────────────────────────────────────────────────
out5="$(bash "$VR" --ticket 43 --title "VALIDATION: dry preview" --evidence "x" --source "test" --gating self --print-path-only)"
assert_eq "$out5" ".claude/shiploop/validation/ticket-43-validation-dry-preview.md" \
  "5b. --print-path-only prints the would-be path"
assert_eq "$(test -e "$T/$out5" && echo present || echo absent)" "absent" \
  "5b. --print-path-only writes NOTHING to disk"

# ── 4. kill switch ───────────────────────────────────────────────────────────────────────────────
out6="$(GOVERN_VALIDATION_RECORD=0 bash "$VR" --ticket 44 --title "VALIDATION: killed" --evidence "x" --source "test" --gating self)"
rc6=$?
assert_eq "$rc6" "0" "4. kill switch still exits 0"
assert_eq "$out6" "" "4. kill switch prints nothing"
assert_eq "$(ls "$T/.claude/shiploop/validation" 2>/dev/null | grep -c 'ticket-44-' )" "0" \
  "4. kill switch writes nothing"

# ── 6. required-argument validation ─────────────────────────────────────────────────────────────
bash "$VR" --title x --evidence x >/dev/null 2>&1
assert_eq "$?" "1" "6. missing --ticket refuses"
bash "$VR" --ticket 50 --evidence x >/dev/null 2>&1
assert_eq "$?" "1" "6. missing --title refuses"
bash "$VR" --ticket 50 --title x >/dev/null 2>&1
assert_eq "$?" "1" "6. missing --evidence (and no --evidence-file) refuses"
bash "$VR" --ticket 50 --title x --evidence a --evidence-file "$efile" >/dev/null 2>&1
assert_eq "$?" "1" "6. --evidence AND --evidence-file together refuses"

# --source and --gating are REQUIRED, and --gating is a closed set. An unattributed or ungraded
# record cannot be weighed by a later reader, which is the whole point of storing it.
bash "$VR" --ticket 51 --title x --evidence x --gating self >/dev/null 2>&1
assert_eq "$?" "1" "F: --source missing is refused"
bash "$VR" --ticket 51 --title x --evidence x --source s >/dev/null 2>&1
assert_eq "$?" "1" "F: --gating missing is refused"
bash "$VR" --ticket 51 --title x --evidence x --source s --gating bogus >/dev/null 2>&1
assert_eq "$?" "1" "F: --gating outside {machine,self} is refused"

# The rendered record states HOW it was gated, distinctly for each value.
bash "$VR" --ticket 52 --title "gated self" --evidence "e" --source "interactive session" --gating self >/dev/null
grep -q "Gating: self-attested" "$T/.claude/shiploop/validation/ticket-52-gated-self.md"
assert_eq "$?" "0" "G: a self-attested record says so in the file"
bash "$VR" --ticket 53 --title "gated machine" --evidence "e" --source "governor resolve" --gating machine >/dev/null
grep -q "Gating: machine-checked" "$T/.claude/shiploop/validation/ticket-53-gated-machine.md"
assert_eq "$?" "0" "G: a machine-checked record says so in the file"

assert_done
