#!/usr/bin/env bash
# router-posture-guard.sh: the verify-filter REWRITE (promoted from a straight denial for
# `permission_mode: "bypassPermissions"` only, see the file's "same lever REWRITES" header
# paragraph), separate from and complementary to test-router-posture-vf-nudge.sh, which covers the
# advisory half of the same lever.
#
# The guard is copied into a sandboxed hooks/ directory per case so wrapper presence/absence is
# fully controlled instead of depending on the ambient template tree, where
# templates/govern/verify-filter.sh always exists.
#
# Contract under test:
#   1. bypassPermissions + a simple unwrapped command, wrapper present, is ALLOWED with an
#      `updatedInput` that wraps `command` in verify-filter.sh and carries every OTHER field of
#      the original tool_input (timeout, run_in_background, description) unchanged.
#   2. every mode OTHER than bypassPermissions (default, acceptEdits, plan, dontAsk, and a payload
#      with no permission_mode field at all) DENIES instead, with the same wrap-it-yourself
#      message as before -- and NEVER names its own kill switch in that text.
#   3. a COMPOUND command (containing `;`, `&&`, `||`, `|`, a newline, a backtick, or `$(`), even
#      under bypassPermissions, DENIES instead of rewriting: splicing it after
#      `bash <verify-filter.sh> --` would let the outer shell re-parse the operator against the
#      wrapper call, not the original command, changing which commands run and in what order.
#   4. no rewrite (and no deny) when the wrapper is absent -- falls through to the advisory instead.
#   5. no rewrite (and no deny) when the command is already wrapped, wrapper present or not.
#   6. GOVERN_VF_DENY=0 skips this whole lever (neither rewrite nor deny), even with the wrapper
#      present and bypassPermissions active -- falls through to the advisory.
#   7. the rewrite/deny is not rate limited: it fires on every one of several calls in one session.
#   8. the same checks (1, 3, 6) hold for `node --test`, the stdlib runner form.
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

payload() { # <command> <session_id> <permission_mode|""> [timeout] [run_in_background]
  python3 -c '
import json, sys
command, session_id, mode = sys.argv[1:4]
timeout = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else ""
rib = sys.argv[5] if len(sys.argv) > 5 else ""
ti = {"command": command, "description": "delegated test run"}
if timeout:
    ti["timeout"] = int(timeout)
if rib:
    ti["run_in_background"] = (rib == "true")
d = {
    "tool_name": "Bash",
    "transcript_path": "/tmp/fake-transcript.jsonl",
    "session_id": session_id,
    "tool_input": ti,
}
if mode:
    d["permission_mode"] = mode
print(json.dumps(d))
' "$1" "$2" "$3" "${4:-}" "${5:-}"
}

clear_counter() { rm -f "${TMPDIR:-/tmp}/metarepo-router-posture-guard-$1" 2>/dev/null || true; }

# ── 1. bypassPermissions + simple + wrapper present → ALLOW, full tool_input preserved ──────
vf_present
sid="vfrewrite-fires"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "bypassPermissions" 120000 false | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "1a. bypassPermissions + unwrapped 'npm test' is never denied"
assert_contains "$out" '"permissionDecision": "allow"' "1b. it is explicitly ALLOWED"
assert_contains "$out" '"updatedInput"' "1c. the allow carries an updatedInput"
assert_contains "$out" "$T/govern/verify-filter.sh" "1d. updatedInput.command wraps the real resolved verify-filter.sh path"
assert_contains "$out" "\" -- npm test" "1e. updatedInput.command preserves the original command after the -- separator"
assert_contains "$out" '"timeout": 120000' "1f. updatedInput preserves the original timeout field"
assert_contains "$out" '"run_in_background": false' "1g. updatedInput preserves the original run_in_background field"
assert_contains "$out" '"description": "delegated test run"' "1h. updatedInput preserves the original description field"
clear_counter "$sid"

# ── 2. every OTHER permission_mode denies instead, and never names the kill switch ──────────
vf_present
for mode in default acceptEdits plan dontAsk; do
  sid="vfrewrite-mode-$mode"; clear_counter "$sid"
  out="$(payload "npm test" "$sid" "$mode" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
  assert_contains "$out" '"permissionDecision": "deny"' "2.$mode permission_mode=$mode DENIES instead of rewriting"
  assert_not_contains "$out" "GOVERN_VF_DENY" "2.$mode.b the deny text never names the kill switch"
  clear_counter "$sid"
done

sid="vfrewrite-mode-missing"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "2e. a payload with NO permission_mode field DENIES instead of rewriting"
assert_not_contains "$out" "GOVERN_VF_DENY" "2e.b the deny text never names the kill switch"
clear_counter "$sid"

# ── 3. a COMPOUND command, even under bypassPermissions, denies instead of rewriting ────────
vf_present
compound_cases=(
  "cd /tmp && npm test"
  "npm test || echo fail"
  "npm test ; echo done"
  "npm test | tail -20"
  'npm test $(date)'
  'npm test `date`'
)
i=0
for cmd in "${compound_cases[@]}"; do
  i=$((i + 1))
  sid="vfrewrite-compound-$i"; clear_counter "$sid"
  out="$(payload "$cmd" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
  assert_not_contains "$out" '"updatedInput"' "3.$i a compound command ('$cmd') is never rewritten, even under bypassPermissions"
  assert_contains "$out" '"permissionDecision": "deny"' "3.$i.b ...and DENIES instead"
  clear_counter "$sid"
done

# A multi-line command (embedded newline) is compound by the same rule -- it must never be
# spliced into a one-line rewrite, which would silently join two lines into one command.
sid="vfrewrite-multiline"; clear_counter "$sid"
out="$(payload "$(printf 'echo one\necho npm test')" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "3b. a multi-line command is never rewritten"
clear_counter "$sid"

# ── 4. wrapper absent → no rewrite, no deny, falls through to the advisory ──────────────────
vf_absent
sid="vfrewrite-absent"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "4a. wrapper absent: no rewrite (never bricks a workspace without it)"
assert_not_contains "$out" '"permissionDecision": "deny"' "4b. wrapper absent: no deny either"
assert_contains "$out" "verify-filter" "4c. wrapper absent: the advisory still fires in its place"
clear_counter "$sid"

# ── 5. command already wrapped → no rewrite, no deny, wrapper present or absent ─────────────
vf_present
sid="vfrewrite-wrapped-a"; clear_counter "$sid"
out="$(payload "npm run vf -- npm test" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "5a. already wrapped ('npm run vf --'): no rewrite, wrapper present"
assert_not_contains "$out" '"permissionDecision"' "5a.b ...and no permissionDecision at all"
clear_counter "$sid"

sid="vfrewrite-wrapped-b"; clear_counter "$sid"
out="$(payload "bash scripts/govern/verify-filter.sh -- npm test" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "5b. already wrapped (direct verify-filter.sh): no rewrite, wrapper present"
clear_counter "$sid"

# ── 6. GOVERN_VF_DENY=0 → skips the WHOLE lever, even bypassPermissions + simple ────────────
vf_present
sid="vfrewrite-killswitch"; clear_counter "$sid"
out="$(payload "npm test" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=0 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "6a. GOVERN_VF_DENY=0 disables the rewrite even with bypassPermissions + wrapper present"
assert_not_contains "$out" '"permissionDecision"' "6b. no permissionDecision at all once the lever is off"
assert_contains "$out" "verify-filter" "6c. GOVERN_VF_DENY=0 leaves the advisory on (GOVERN_VF_NUDGE governs it separately)"
clear_counter "$sid"

# ── 7. not rate limited: fires on every one of several calls in one session ────────────────
vf_present
sid="vfrewrite-noratelimit"; clear_counter "$sid"
rewrites=0
for i in 1 2 3 4 5; do
  out="$(payload "npm test" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
  case "$out" in *'"updatedInput"'*) rewrites=$((rewrites + 1)) ;; esac
done
assert_eq "$rewrites" "5" "7. all 5 calls in one session are rewritten (the shared warn cap never gates this)"
clear_counter "$sid"

# ── 8. `node --test` (the stdlib runner form) → same checks as npm test ────────────────────
vf_present
sid="vfrewrite-node-fires"; clear_counter "$sid"
out="$(payload "node --test test/x.test.js" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_contains "$out" '"permissionDecision": "allow"' "8a. bypassPermissions + unwrapped 'node --test' is rewritten"
assert_contains "$out" "\" -- node --test test/x.test.js" "8b. updatedInput.command names the original command"
clear_counter "$sid"

sid="vfrewrite-node-mode"; clear_counter "$sid"
out="$(payload "node --test test/x.test.js" "$sid" "default" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "8c. non-bypass mode DENIES 'node --test' too"
clear_counter "$sid"

sid="vfrewrite-node-wrapped"; clear_counter "$sid"
out="$(payload "npm run vf -- node --test test/x.test.js" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=1 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "8d. already wrapped 'node --test': no rewrite, wrapper present"
clear_counter "$sid"

sid="vfrewrite-node-killswitch"; clear_counter "$sid"
out="$(payload "node --test test/x.test.js" "$sid" "bypassPermissions" | env -u GOVERN_RUN GOVERN_VF_DENY=0 "$GUARD" 2>&1)"
assert_not_contains "$out" '"updatedInput"' "8e. GOVERN_VF_DENY=0 disables the rewrite for 'node --test' too"
clear_counter "$sid"

assert_done
