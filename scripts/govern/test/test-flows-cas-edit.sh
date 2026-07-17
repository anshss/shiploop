#!/usr/bin/env bash
# govern::cas_edit (validations Phase 1): sync → edit → commit → CAS-push with rebase-retry. Proves
# the retry LOOP by injecting a concurrent push into origin/main BETWEEN cas_edit's pre-edit pull and
# its push (the edit-fn lands a divergent commit from a second clone), so the first push is REJECTED,
# the rebase-retry replays our edit onto the moved main, and BOTH changes end up on origin/main.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

command -v git >/dev/null 2>&1 || { echo "git absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
source "$DIR/../lib/common.sh"

gitcfg() { git -C "$1" config user.email ci@test; git -C "$1" config user.name ci; }

# Bare origin + working clone A (the "governor" checkout) with a main branch.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/A"; gitcfg "$T/A"
git -C "$T/A" checkout -q -b main
mkdir -p "$T/A/.claude/shiploop/validation"
printf '# Flow registry\n\n## deploy.example\n- **Kind:** correctness\n- **Status:** UNTESTED\n' > "$T/A/.claude/shiploop/validation/flows.md"
printf 'base\n' > "$T/A/base.txt"
git -C "$T/A" add -A; git -C "$T/A" commit -q -m init; git -C "$T/A" push -q -u origin main

# Second clone B — the "concurrent driver" whose push advances origin/main under A.
git clone -q "$T/origin.git" "$T/B"; gitcfg "$T/B"
git -C "$T/B" checkout -q main 2>/dev/null || git -C "$T/B" checkout -q -b main

# edit-fn: the REAL registry mutation, plus a ONE-TIME concurrent push from B (fires between cas_edit's
# pre-edit pull and its push, so A's first push is rejected → exercises the rebase-retry loop).
CONCURRENT_ONCE="$T/.concurrent-fired"
myedit() {
  local f="$1"
  govern::flow_set_field deploy.example Status PASS "$f"
  if [[ ! -e "$CONCURRENT_ONCE" ]]; then
    : > "$CONCURRENT_ONCE"
    printf 'concurrent driver was here\n' > "$T/B/other.txt"
    git -C "$T/B" add -A; git -C "$T/B" commit -q -m "concurrent driver commit"
    git -C "$T/B" push -q origin main
  fi
}

GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
  govern::cas_edit "$T/A/.claude/shiploop/validation/flows.md" myedit "chore(flows): stamp deploy.example"

# A's working tree carries our edit.
assert_eq "$(GOVERN_FLOWS_FILE="$T/A/.claude/shiploop/validation/flows.md" govern::flow_field deploy.example Status "$T/A/.claude/shiploop/validation/flows.md")" "PASS" "cas_edit: local edit applied (Status→PASS)"

# origin/main carries BOTH the concurrent commit AND our flows edit — proving the CAS retry replayed
# our commit onto the moved main rather than clobbering or dropping either.
V="$T/verify"; git clone -q "$T/origin.git" "$V"
assert_contains "$(cat "$V/.claude/shiploop/validation/flows.md")" "**Status:** PASS" "cas_edit: our edit reached origin/main"
assert_eq "$([[ -f "$V/other.txt" ]] && echo yes || echo no)" "yes" "cas_edit: concurrent driver's commit preserved on origin/main"
# Exactly one linear history with both commits (no lost update).
log="$(git -C "$V" log --oneline | tr '\n' '|')"
assert_contains "$log" "concurrent driver commit" "cas_edit: concurrent commit in origin history"
assert_contains "$log" "stamp deploy.example" "cas_edit: our commit in origin history"

# ── GOVERN_NO_PUSH=1: edit + local commit, but no push (guarded side effect).
printf 'x\n' >> "$T/A/base.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -q -m "drift" # move A's main ahead locally
noedit() { govern::flow_set_field deploy.example Env local "$1"; }
GOVERN_NO_PUSH=1 GOVERN_BOOKKEEP_LOCK="$T/governor/.bookkeep.lock" \
  govern::cas_edit "$T/A/.claude/shiploop/validation/flows.md" noedit "chore(flows): env"
assert_eq "$(govern::flow_field deploy.example Env "$T/A/.claude/shiploop/validation/flows.md")" "local" "cas_edit(NO_PUSH): local edit applied"

assert_done
