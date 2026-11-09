#!/usr/bin/env bash
# Regression for anshss/shiploop#232: /shiploop:update must never silently overwrite a
# workspace-local edit to a mechanism script (core-scripts, worktrees, govern).
#
# Contract (mechanism_install in scaffold.sh):
#   1. a locally edited file is KEPT; the hub version lands beside it as <file>.shiploop-new
#      (exec bit kept), the run prints a loud summary, and .harness-version is NOT advanced
#   2. an UNEDITED copy of an older shipped version IS upgraded (hash is in mechanism-hashes.txt)
#   3. an absent file is installed
#   4. --overwrite-local-edits restores the old overwrite (and drops the stale .shiploop-new)
#   5. check-manifests `mechanism-hashes-current` fails when a current mechanism file's hash is
#      missing from the manifest (positive control: passes on the untouched copy)
#   6. the same holds for a worktrees and a core-scripts file, not only govern
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] && [ -f "$HUB/tools/check-manifests.sh" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LOG="$ROOT/out.log"

run_scaffold() { # <workspace> <templates> [extra scaffold args...]
  local ws="$1" tpl="$2"; shift 2
  bash "$SCAFFOLD" --workspace-dir "$ws" --templates "$tpl" "$@" --yes </dev/null >"$LOG" 2>&1 &
  wait $!
}

W="$ROOT/ws"; mkdir -p "$W"
run_scaffold "$W" "$TEMPLATES" --pm npm --org testorg --repos "alpha::echo alpha" \
  --merge-allowlist "" --worktree-base "$W.wt" --component workspace-sh
for c in core-scripts worktrees govern githooks commands agents workflows; do
  run_scaffold "$W" "$TEMPLATES" --component "$c"
done
v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$HUB/VERSION")"
stamp() { awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W/scripts/lib/.harness-version" 2>/dev/null; }
assert_eq "$(stamp)" "$v" "0. fresh converged workspace is stamped with the hub VERSION"

# ── 1. local edit survives, hub copy lands beside it, summary is loud, stamp holds ──
F="scripts/govern/ticket-proposal.sh"; TPL="$TEMPLATES/govern/ticket-proposal.sh"
[ -f "$W/$F" ] && [ -f "$TPL" ] || { echo "FAIL - fixture file $F missing"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
printf '\n# LOCAL FIX: part-aware lookup\n' >> "$W/$F"
cp "$W/$F" "$ROOT/local-copy"
printf '0.0.1\n' > "$W/scripts/lib/.harness-version"
run_scaffold "$W" "$TEMPLATES" --component govern --verbose
out="$(cat "$LOG")"
cmp -s "$W/$F" "$ROOT/local-copy" && r=same || r=changed
assert_eq "$r" "same" "1. locally edited govern script is left untouched"
cmp -s "$W/$F.shiploop-new" "$TPL" && r=hub || r=other
assert_eq "$r" "hub" "1. hub version written beside it as .shiploop-new"
[ -x "$W/$F.shiploop-new" ] && r=exec || r=noexec
assert_eq "$r" "exec" "1. .shiploop-new keeps the exec bit"
assert_contains "$out" "KEPT 1 file(s) with LOCAL EDITS" "1. loud kept summary printed"
assert_contains "$out" "$F" "1. summary names the kept file"
assert_eq "$(stamp)" "0.0.1" "1. stamp NOT advanced while a file is kept"
# Every OTHER govern file is still current (the keep is per file, not per component).
out_d="$(bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --diff-only 2>&1)"
assert_contains "$out_d" "govern: behind" "1. --diff-only still reports the kept file as drift"

# ── 6. same for a worktrees file and a core-scripts file ───────────────────────────
printf '\n# LOCAL FIX\n' >> "$W/scripts/worktree/rm.sh"
printf '\n# LOCAL FIX\n' >> "$W/scripts/doctor.sh"
run_scaffold "$W" "$TEMPLATES" --component worktrees
run_scaffold "$W" "$TEMPLATES" --component core-scripts
assert_contains "$(tail -c 200 "$W/scripts/worktree/rm.sh")" "LOCAL FIX" "6. worktrees edit survives"
assert_contains "$(tail -c 200 "$W/scripts/doctor.sh")" "LOCAL FIX" "6. core-scripts edit survives"
[ -f "$W/scripts/worktree/rm.sh.shiploop-new" ] && [ -f "$W/scripts/doctor.sh.shiploop-new" ] && r=both || r=missing
assert_eq "$r" "both" "6. .shiploop-new written for worktrees and core-scripts"

# ── 3. an absent file is installed ──────────────────────────────────────────────────
rm -f "$W/scripts/govern/select-ticket.sh"
run_scaffold "$W" "$TEMPLATES" --component govern
[ -f "$W/scripts/govern/select-ticket.sh" ] && r=present || r=absent
assert_eq "$r" "present" "3. absent mechanism file is installed"

# ── 4. --overwrite-local-edits restores the old behaviour ───────────────────────────
run_scaffold "$W" "$TEMPLATES" --component govern --overwrite-local-edits
cmp -s "$W/$F" "$TPL" && r=hub || r=local
assert_eq "$r" "hub" "4. --overwrite-local-edits overwrites the local edit"
[ ! -e "$W/$F.shiploop-new" ] && r=gone || r=left
assert_eq "$r" "gone" "4. the stale .shiploop-new is removed"
run_scaffold "$W" "$TEMPLATES" --component worktrees --overwrite-local-edits
run_scaffold "$W" "$TEMPLATES" --component core-scripts --overwrite-local-edits
assert_eq "$(stamp)" "$v" "4. overwritten + converged workspace stamps again"

# ── 2. an UNEDITED older shipped version is upgraded ────────────────────────────────
# Hermetic: a templates copy whose current version of one script is NEW, while the workspace
# holds the previously shipped (recorded) one.
T2="$ROOT/tpl2"; cp -R "$TEMPLATES" "$T2"
printf '\n# a newer hub release\n' >> "$T2/govern/ticket-proposal.sh"
run_scaffold "$W" "$T2" --component govern
cmp -s "$W/$F" "$T2/govern/ticket-proposal.sh" && r=upgraded || r=stale
assert_eq "$r" "upgraded" "2. unedited (recorded) older version is upgraded"
[ ! -e "$W/$F.shiploop-new" ] && r=none || r=present
assert_eq "$r" "none" "2. no .shiploop-new for a clean upgrade"
assert_not_contains "$(cat "$LOG")" "KEPT" "2. no kept summary on a clean upgrade"
# And the new (unrecorded) version, once edited locally, is now kept.
printf '\n# my fix\n' >> "$W/$F"
run_scaffold "$W" "$T2" --component govern
assert_contains "$(tail -c 100 "$W/$F")" "my fix" "2. edit on top of the upgraded version is kept"

# ── 5. manifest check fails when a current mechanism hash is missing ────────────────
H2="$ROOT/hub2"; mkdir -p "$H2"
cp -R "$HUB/tools" "$HUB/templates" "$HUB/scaffold.sh" "$HUB/VERSION" "$H2/"
out="$(cd "$H2" && bash tools/check-manifests.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "5. positive control: untouched copy passes check-manifests"
assert_contains "$out" "ok - mechanism-hashes-current" "5. positive control: mechanism-hashes-current ok"
sha="$(shasum -a 256 "$H2/templates/govern/ticket-proposal.sh" | cut -d' ' -f1)"
grep -v "^$sha  govern/ticket-proposal.sh" "$H2/templates/lib/mechanism-hashes.txt" > "$ROOT/mh" \
  && cp "$ROOT/mh" "$H2/templates/lib/mechanism-hashes.txt"
out="$(cd "$H2" && bash tools/check-manifests.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "5. missing current hash makes check-manifests exit 1"
assert_contains "$out" "MISSING: govern/ticket-proposal.sh" "5. names the missing file"

assert_done
