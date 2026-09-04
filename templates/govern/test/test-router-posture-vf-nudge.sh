#!/usr/bin/env bash
# router-posture-guard.sh: the verify-filter nudge advisory.
#
# Contract under test:
#   1. An unwrapped test/build runner (npm test) fires the advisory.
#   2. The SAME command already wrapped in `npm run vf --` (or verify-filter.sh
#      directly) stays silent.
#   3. GOVERN_VF_NUDGE=0 is a kill switch: silent even when unwrapped.
#   4. Silent for a governor worker (GOVERN_RUN set), the delegation target,
#      not the driver.
#   5. Silent for a sub-agent transcript path (.../subagents/...).
#   6. The per-session warn cap is shared and respected: after
#      MAX_WARNS_PER_SESSION warns in a session, the hook goes quiet.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }
GUARD="$GOVERN_HOOKS_DIR/router-posture-guard.sh"

# Each case gets its own session_id so the per-session warn counter never leaks
# across cases; the counter file lives under TMPDIR keyed by session_id.
payload() { # <tool_name> <command> <session_id> <transcript_path>
  python3 -c '
import json, sys
tool_name, command, session_id, transcript_path = sys.argv[1:5]
print(json.dumps({
    "tool_name": tool_name,
    "transcript_path": transcript_path,
    "session_id": session_id,
    "tool_input": {"command": command},
}))
' "$1" "$2" "$3" "$4"
}

clear_counter() { rm -f "${TMPDIR:-/tmp}/metarepo-router-posture-guard-$1" 2>/dev/null || true; }

# ── 1. unwrapped npm test fires the vf nudge ────────────────────────────────
sid="vfnudge-unwrapped-1"; clear_counter "$sid"
out="$(payload Bash "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN "$GUARD" 2>&1)"
assert_contains "$out" "verify-filter" "1. unwrapped 'npm test' gets the vf nudge"
assert_contains "$out" "npm run vf" "1. nudge names the wrap-with-vf fix"
clear_counter "$sid"

# ── 2. already wrapped in npm run vf -- stays silent ────────────────────────
sid="vfnudge-wrapped-npmrun"; clear_counter "$sid"
out="$(payload Bash "npm run vf -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN "$GUARD" 2>&1)"
assert_not_contains "$out" "verify-filter" "2a. 'npm run vf -- npm test' is already wrapped, no nudge"

sid="vfnudge-wrapped-direct"; clear_counter "$sid"
out="$(payload Bash "bash scripts/govern/verify-filter.sh -- npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN "$GUARD" 2>&1)"
assert_not_contains "$out" "verify-filter" "2b. direct verify-filter.sh wrap is already wrapped, no nudge"

# ── 3. kill switch: GOVERN_VF_NUDGE=0 silences it entirely ─────────────────
sid="vfnudge-killswitch"; clear_counter "$sid"
out="$(payload Bash "npm test" "$sid" "/tmp/fake-transcript.jsonl" | env -u GOVERN_RUN GOVERN_VF_NUDGE=0 "$GUARD" 2>&1)"
assert_not_contains "$out" "verify-filter" "3. GOVERN_VF_NUDGE=0 silences the nudge"
clear_counter "$sid"

# ── 4. governor worker (GOVERN_RUN set) never gets nagged, it's the target ──
sid="vfnudge-workertarget"; clear_counter "$sid"
p="$(payload Bash "npm test" "$sid" "/tmp/fake-transcript.jsonl")"
out="$(printf '%s' "$p" | env GOVERN_RUN=1 "$GUARD" 2>&1)"
assert_eq "$out" "" "4. a governor worker session (GOVERN_RUN set) gets no advisory at all"

# ── 5. sub-agent transcript path is silent (it's the delegation target) ────
sid="vfnudge-subagent"; clear_counter "$sid"
out="$(payload Bash "npm test" "$sid" "/tmp/.claude/subagents/xyz/transcript.jsonl" | env -u GOVERN_RUN "$GUARD" 2>&1)"
assert_eq "$out" "" "5. a sub-agent transcript path gets no advisory at all"

# ── 6. per-session warn cap is respected (shared with the existing guard) ──
sid="vfnudge-cap"; clear_counter "$sid"
fires=0
for i in 1 2 3 4 5; do
  out="$(payload Bash "npm test" "$sid" "/tmp/fake-transcript-$i.jsonl" | env -u GOVERN_RUN "$GUARD" 2>&1)"
  [ -n "$out" ] && fires=$((fires + 1))
done
# MAX_WARNS_PER_SESSION=3 in the script under test; 5 calls in the same session
# must not exceed that many non-empty advisories.
[ "$fires" -le 3 ] && printf 'ok   - 6. warn cap respected (%d fires over 5 calls, cap=3)\n' "$fires" || \
  { printf 'FAIL - 6. warn cap exceeded (%d fires over 5 calls, cap=3)\n' "$fires"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
clear_counter "$sid"

assert_done
