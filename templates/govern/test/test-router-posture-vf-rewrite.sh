#!/usr/bin/env bash
# router-posture-guard.sh: the verify-filter REWRITE (promoted from a straight denial, see the
# file's "same lever also REWRITES" header paragraph), separate from and complementary to
# test-router-posture-vf-nudge.sh, which covers the advisory half of the same lever.
#
# The guard is copied into a sandboxed hooks/ directory per case so wrapper presence/absence is
# fully controlled instead of depending on the ambient template tree, where
# templates/govern/verify-filter.sh always exists.
#
# Contract under test:
#   1. an unwrapped command, wrapper present, is ALLOWED with an `updatedInput.command` that
#      wraps it in verify-filter.sh -- no denial, no retry turn.
#   2. no rewrite when the wrapper is absent -- falls through to the advisory instead.
#   3. no rewrite when the command is already wrapped, wrapper present or not.
#   4. no rewrite when GOVERN_VF_DENY=0 (the kill switch, name unchanged from when this lever
#      denied), even with the wrapper present -- falls through to the advisory.
#   5. the rewrite is not rate limited: it fires on every one of several calls in one session.
#   6. the same three checks (1, 3, 4) hold for `node --test`, the stdlib runner form.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Sandbox: copy the real guard under a controlled SELF_ROOT (dirname(guard)/..) so the
# scripts/govern/verify-filter.sh | govern/verify-filter.sh dual-layout resolve lands on a
# location this test owns, not the ambient template tree.
mkdir -p "$T/hooks"
cp "$GOVERN_HOOKS_DIR/router-posture-guard.sh" "$T/hooks/router-posture-guard.sh"
GUARD="$T/hooks/router-posture-guard.sh"

vf_present() { mkdir -p "$T/govern"; : > "$T/govern/verify-filter.sh"; }
vf_absent() { rm -f "$T/govern/verify-filter.sh"; }

payload() { # <command> <session_id> <transcript_path>
  python3 -c '
import json, sys
command, session_id, transcript_path = sys.argv[1:4]
print(json.dumps({
    "tool_name": "Bash",
    "transcript_path": transcript_path,
    "session_id": session_id,
    "tool_input": {"command": command},
}))
' "$1" "$2" "$3"
}

clear_counter() { rm -f "${TMPDIR:-/tmp}/metarepo-router-posture-guard-$1" 2>/dev/null || true; }

# ── 1. wrapper present + unwrapped command → ALLOW with a rewritten updatedInput.command ───
vf_present
sid="vfrewrite-fires"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "1a. wrapper present + unwrapped 'npm test' is never denied"
assert_contains "$out" '"permissionDecision": "allow"' "1b. it is explicitly ALLOWED"
assert_contains "$out" '"updatedInput"' "1c. the allow carries an updatedInput"
assert_contains "$out" "$T/govern/verify-filter.sh" "1d. updatedInput.command wraps the real resolved verify-filter.sh path"
assert_contains "$out" "\" -- npm test" "1e. updatedInput.command preserves the original command after the -- separator"
clear_counter "$sid"

# ── 2. wrapper absent → no rewrite, falls through to the advisory ──────────────────────────
vf_absent
sid="vfrewrite-absent"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "2a. wrapper absent: no rewrite (never bricks a workspace without it)"
assert_contains "$out" "verify-filter" "2b. wrapper absent: the advisory still fires in its place"
clear_counter "$sid"

# ── 3. command already wrapped → no rewrite, wrapper present or absent ─────────────────────
vf_present
sid="vfrewrite-wrapped-a"; clear_counter "$sid"
out="$(payload "npm run vf -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "3a. already wrapped ('npm run vf --'): no rewrite, wrapper present"
clear_counter "$sid"

sid="vfrewrite-wrapped-b"; clear_counter "$sid"
out="$(payload "bash scripts/govern/verify-filter.sh -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "3b. already wrapped (direct verify-filter.sh): no rewrite, wrapper present"
clear_counter "$sid"

# ── 4. GOVERN_VF_DENY=0 → no rewrite even with the wrapper present ─────────────────────────
vf_present
sid="vfrewrite-killswitch"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=0 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "4a. GOVERN_VF_DENY=0 disables the rewrite even with the wrapper present"
assert_not_contains "$out" '"permissionDecision"' "4b. no permissionDecision at all once the rewrite is off"
assert_contains "$out" "verify-filter" "4c. GOVERN_VF_DENY=0 leaves the advisory on (GOVERN_VF_NUDGE governs it separately)"
clear_counter "$sid"

# ── 5. not rate limited: fires on every one of several calls in one session ────────────────
vf_present
sid="vfrewrite-noratelimit"; clear_counter "$sid"
rewrites=0
for i in 1 2 3 4 5; do
  out="$(payload "npm test" "$sid" "/tmp/fake-transcript-$i.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
  case "$out" in *'"updatedInput"'*) rewrites=$((rewrites + 1)) ;; esac
done
assert_eq "$rewrites" "5" "5. all 5 calls in one session are rewritten (the shared warn cap never gates this)"
clear_counter "$sid"

# ── 6. `node --test` (the stdlib runner form) → same three checks as npm test ──────────────
vf_present
sid="vfrewrite-node-fires"; clear_counter "$sid"
out="$(payload "node --test test/x.test.js" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_contains "$out" '"permissionDecision": "allow"' "6a. wrapper present + unwrapped 'node --test' is rewritten"
assert_contains "$out" "\" -- node --test test/x.test.js" "6b. updatedInput.command names the original command"
clear_counter "$sid"

sid="vfrewrite-node-wrapped"; clear_counter "$sid"
out="$(payload "npm run vf -- node --test test/x.test.js" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "6c. already wrapped 'node --test': no rewrite, wrapper present"
clear_counter "$sid"

sid="vfrewrite-node-killswitch"; clear_counter "$sid"
out="$(payload "node --test test/x.test.js" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=0 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "6d. GOVERN_VF_DENY=0 disables the rewrite for 'node --test' too"
clear_counter "$sid"

assert_done
