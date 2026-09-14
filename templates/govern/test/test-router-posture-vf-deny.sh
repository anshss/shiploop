#!/usr/bin/env bash
# router-posture-guard.sh: the verify-filter DENIAL (promoted from advisory-only, see the file's
# "Second advisory" header paragraph), separate from and complementary to
# test-router-posture-vf-nudge.sh, which covers the advisory half of the same lever.
#
# The guard is copied into a sandboxed hooks/ directory per case so wrapper presence/absence is
# fully controlled instead of depending on the ambient template tree, where
# templates/govern/verify-filter.sh always exists.
#
# Contract under test:
#   1. denial fires on a matching unwrapped command when verify-filter.sh exists at the resolved
#      workspace root, and names the rewrapped command back to the model.
#   2. no denial when the wrapper is absent -- falls through to the advisory instead.
#   3. no denial when the command is already wrapped, wrapper present or not.
#   4. no denial when GOVERN_VF_DENY=0, even with the wrapper present.
#   5. the denial is not rate limited: it fires on every one of several calls in one session.
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

# ── 1. wrapper present + unwrapped command → DENY, naming the rewrapped command ─────────────
vf_present
sid="vfdeny-fires"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "1a. wrapper present + unwrapped 'npm test' is DENIED"
assert_contains "$out" "npm run vf -- npm test" "1b. deny reason names the rewrapped command"
assert_contains "$out" "GOVERN_VF_DENY=0" "1c. deny reason names its own kill switch"
clear_counter "$sid"

# ── 2. wrapper absent → no denial, falls through to the advisory ───────────────────────────
vf_absent
sid="vfdeny-absent"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "2a. wrapper absent: no denial (never bricks a workspace without it)"
assert_contains "$out" "verify-filter" "2b. wrapper absent: the advisory still fires in its place"
clear_counter "$sid"

# ── 3. command already wrapped → no denial, wrapper present or absent ──────────────────────
vf_present
sid="vfdeny-wrapped-a"; clear_counter "$sid"
out="$(payload "npm run vf -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "3a. already wrapped ('npm run vf --'): no denial, wrapper present"
clear_counter "$sid"

sid="vfdeny-wrapped-b"; clear_counter "$sid"
out="$(payload "bash scripts/govern/verify-filter.sh -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "3b. already wrapped (direct verify-filter.sh): no denial, wrapper present"
clear_counter "$sid"

# ── 4. GOVERN_VF_DENY=0 → no denial even with the wrapper present ──────────────────────────
vf_present
sid="vfdeny-killswitch"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=0 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "4a. GOVERN_VF_DENY=0 silences the denial even with the wrapper present"
assert_contains "$out" "verify-filter" "4b. GOVERN_VF_DENY=0 leaves the advisory on (GOVERN_VF_NUDGE governs it separately)"
clear_counter "$sid"

# ── 5. not rate limited: fires on every one of several calls in one session ────────────────
vf_present
sid="vfdeny-noratelimit"; clear_counter "$sid"
denies=0
for i in 1 2 3 4 5; do
  out="$(payload "npm test" "$sid" "/tmp/fake-transcript-$i.jsonl" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
  case "$out" in *'"permissionDecision": "deny"'*) denies=$((denies + 1)) ;; esac
done
assert_eq "$denies" "5" "5. all 5 calls in one session are denied (the shared warn cap never gates this)"
clear_counter "$sid"

assert_done
