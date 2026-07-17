#!/usr/bin/env bash
# Durable validation runner (spec §5): govern::flows_stamp — the runner-facing terminal-verdict
# entry point over govern::flows_stamp_from_report. Covers PASS/FAIL → resolve/gate-park translation,
# ABORT/ERROR refusing to stamp, that a stamp touches EXACTLY its own flow's block (a multi-flow
# registry's other blocks are byte-for-byte untouched), the evidence file landing under
# .claude/shiploop/validation/evidence/ (never .claude/context/validation/), and a stamp RACING a concurrent registry
# edit — proving cas_edit's rebase-retry fires on the runner's path, not just the raw-cas_edit path
# test-flows-cas-edit.sh already covers.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
export GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"

gitcfg() { git -C "$1" config user.email ci@test; git -C "$1" config user.name ci; }

# Meta repo M with a sub-repo `backend` carrying one commit.
M="$T/meta"; mkdir -p "$M/.claude/shiploop/validation"
git init -q "$M"; gitcfg "$M"
mkdir -p "$M/backend"; git init -q "$M/backend"; gitcfg "$M/backend"
printf 'v1\n' > "$M/backend/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c1
SHA="$(git -C "$M/backend" rev-parse HEAD)"
FLOWS="$M/.claude/shiploop/validation/flows.md"

seed_flows() {
  cat > "$FLOWS" <<EOF
## deploy.gpu.vastai
- **Kind:** correctness
- **Surface:** provision → snapshot → restore
- **Paths:** backend/**
- **Status:** UNTESTED

## deploy.gpu.other
- **Kind:** correctness
- **Surface:** unrelated flow — must stay untouched by a deploy.gpu.vastai stamp
- **Paths:** backend/**
- **Status:** UNTESTED
EOF
}
status_of() { govern::flow_field "$1" Status "$FLOWS"; }
other_block_before=""

# ── PASS → resolve semantics (correctness kind → Status=PASS), evidence promoted under .claude/shiploop/validation/evidence/.
seed_flows
other_block_before="$(govern::flow_block deploy.gpu.other "$FLOWS")"
rec_pass="$(jq -nc --arg s "$SHA" '{pr:{repo:"backend",number:41,url:"https://github.com/acme/backend/pull/41"},validation:{environment:"prod",evidence:"deploy → provision → snapshot → terminate → restore → verify: all phases green",validatedShas:{backend:$s}}}')"
govern::flows_stamp deploy.gpu.vastai PASS "$rec_pass" "$M"
assert_eq "$(status_of deploy.gpu.vastai)" "PASS" "flows_stamp: PASS verdict → Status=PASS"
assert_contains "$(govern::flow_field deploy.gpu.vastai Validated "$FLOWS")" "backend@${SHA:0:7}" "flows_stamp: PASS records the reachable SHA pin"
assert_eq "$(govern::flow_field deploy.gpu.vastai Evidence "$FLOWS")" ".claude/shiploop/validation/evidence/deploy.gpu.vastai.md" "flows_stamp: Evidence field points at the tier-2 sink"
assert_eq "$([[ -f "$M/.claude/shiploop/validation/evidence/deploy.gpu.vastai.md" ]] && echo yes || echo no)" "yes" "flows_stamp: evidence file written to .claude/shiploop/validation/evidence/"
assert_eq "$([[ -e "$M/.claude/context/validation" ]] && echo yes || echo no)" "no" "flows_stamp: legacy .claude/context/validation/ path never touched"

# Stamping deploy.gpu.vastai must update EXACTLY its own block — the sibling flow's block is untouched.
assert_eq "$(govern::flow_block deploy.gpu.other "$FLOWS")" "$other_block_before" "flows_stamp: sibling flow's block is byte-for-byte untouched"
assert_eq "$(status_of deploy.gpu.other)" "UNTESTED" "flows_stamp: sibling flow's Status left alone"

# ── FAIL → gate-park semantics (correctness kind → Status=FAIL).
seed_flows
rec_fail="$(jq -nc --arg s "$SHA" '{pr:null,validation:{environment:"prod",evidence:"restore verify step mismatched checksum",validatedShas:{backend:$s}}}')"
govern::flows_stamp deploy.gpu.vastai FAIL "$rec_fail" "$M"
assert_eq "$(status_of deploy.gpu.vastai)" "FAIL" "flows_stamp: FAIL verdict → Status=FAIL"

# ── ABORT/ERROR are not registry-stampable — rc 1, nothing written (they route to escalation instead).
seed_flows
if govern::flows_stamp deploy.gpu.vastai ABORT "$rec_fail" "$M"; then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "flows_stamp: ABORT verdict refuses to stamp (rc 1)"
assert_eq "$(status_of deploy.gpu.vastai)" "UNTESTED" "flows_stamp: ABORT leaves the flow untouched"
if govern::flows_stamp deploy.gpu.vastai ERROR "$rec_fail" "$M"; then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "flows_stamp: ERROR verdict refuses to stamp (rc 1)"

# ── CAS retry path: a stamp RACES a concurrent registry edit. Bare origin + working clone A (the
# runner's checkout) + clone B (a concurrent governor bookkeep run advancing origin/main mid-stamp).
# Needs the real push path — unset the local-only GOVERN_NO_PUSH the earlier assertions relied on.
unset GOVERN_NO_PUSH
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/A"; gitcfg "$T/A"
git -C "$T/A" checkout -q -b main
mkdir -p "$T/A/.claude/shiploop/validation"
cat > "$T/A/.claude/shiploop/validation/flows.md" <<EOF
## deploy.gpu.vastai
- **Kind:** correctness
- **Surface:** provision → snapshot → restore
- **Paths:** backend/**
- **Status:** UNTESTED

## deploy.gpu.other
- **Kind:** correctness
- **Surface:** unrelated flow — must stay untouched
- **Paths:** backend/**
- **Status:** UNTESTED
EOF
git -C "$T/A" add -A; git -C "$T/A" commit -q -m init; git -C "$T/A" push -q -u origin main
git clone -q "$T/origin.git" "$T/B"; gitcfg "$T/B"
git -C "$T/B" checkout -q main 2>/dev/null || git -C "$T/B" checkout -q -b main

# flows_stamp_from_report's edit-fn is a nested local function (`_flows_stamp_edit`) invisible from
# outside its call frame, so — like test-flows-cas-edit.sh's `myedit` fires the concurrent push from
# INSIDE the edit-fn — we hook the field-write primitive the edit-fn calls (govern::flow_set_field)
# instead: wrap it to fire the concurrent push exactly once, on the FIRST field it writes (Status),
# which happens between cas_edit's pre-edit pull and its commit/push — the same window
# test-flows-cas-edit.sh exercises, just reached via the runner's real call path this time.
CONCURRENT_ONCE="$T/.concurrent-fired"
eval "$(declare -f govern::flow_set_field | sed '1s/^govern::flow_set_field/_orig_flow_set_field/')"
govern::flow_set_field() {
  local rc=0; _orig_flow_set_field "$@" || rc=$?
  if [[ "$2" == "Status" && ! -e "$CONCURRENT_ONCE" ]]; then
    : > "$CONCURRENT_ONCE"
    printf 'concurrent bookkeep commit\n' > "$T/B/bookkeep.txt"
    git -C "$T/B" add -A; git -C "$T/B" commit -q -m "concurrent bookkeep run"
    git -C "$T/B" push -q origin main
  fi
  return "$rc"
}

GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
  govern::flows_stamp deploy.gpu.vastai PASS "$rec_pass" "$T/A"

assert_eq "$(govern::flow_field deploy.gpu.vastai Status "$T/A/.claude/shiploop/validation/flows.md")" "PASS" "flows_stamp+race: local checkout carries our stamp"

V="$T/verify"; git clone -q "$T/origin.git" "$V"
assert_contains "$(cat "$V/.claude/shiploop/validation/flows.md")" "**Status:** PASS" "flows_stamp+race: our stamp reached origin/main despite the race"
assert_eq "$([[ -f "$V/bookkeep.txt" ]] && echo yes || echo no)" "yes" "flows_stamp+race: concurrent bookkeep commit preserved on origin/main"
assert_eq "$([[ -f "$V/.claude/shiploop/validation/evidence/deploy.gpu.vastai.md" ]] && echo yes || echo no)" "yes" "flows_stamp+race: evidence file committed to origin/main alongside the stamp"
log="$(git -C "$V" log --oneline | tr '\n' '|')"
assert_contains "$log" "concurrent bookkeep run" "flows_stamp+race: concurrent commit present in origin history"
assert_contains "$log" "stamp deploy.gpu.vastai" "flows_stamp+race: our stamp commit present in origin history"
# Sibling flow untouched even across the CAS retry replay.
assert_contains "$(cat "$V/.claude/shiploop/validation/flows.md")" "## deploy.gpu.other"$'\n''- **Kind:** correctness' "flows_stamp+race: sibling flow block intact on origin/main"

assert_done
