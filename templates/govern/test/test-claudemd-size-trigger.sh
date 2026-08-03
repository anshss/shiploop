#!/usr/bin/env bash
# Regression: a free (zero-token) size-trigger detector on the SessionStart learnings-digest hook.
# Root CLAUDE.md is re-sent every turn, so an unbounded CLAUDE.md is a permanent per-turn tax.
# learnings-digest.sh must emit a re-triage reminder when CLAUDE.md exceeds
# SHIPLOOP_CLAUDEMD_MAX_CHARS (default 14000) — using plain `wc -c`, no model call — and stay
# silent when it's under budget. This must fire independent of learnings.md's own content/entries
# (an empty learnings.md must not suppress the CLAUDE.md check, and vice versa).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Runs in BOTH layouts, same resolution as test-learnings-digest.sh.
HUB="$(cd "$DIR/../../.." && pwd)"
DIGEST=""
for c in "$HUB/templates/hooks/learnings-digest.sh" "$DIR/../../learnings-digest.sh"; do
  [ -f "$c" ] && { DIGEST="$c"; break; }
done
[ -n "$DIGEST" ] || { echo "SKIP: learnings-digest.sh not present"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LEARN="$T/learnings.md"; : > "$LEARN"   # entry-less — must not affect the CLAUDE.md check either way
CLAUDE="$T/CLAUDE.md"
# A nonexistent plugin dir, passed as $3 on every call below, to isolate this test from
# whatever the CURRENT MACHINE happens to have installed at ~/.claude/skills/shiploop (or
# CLAUDE_PLUGIN_ROOT) — otherwise the manifest-size check (see test-manifest-size-trigger.sh)
# would bleed its own output into these CLAUDE.md-only assertions.
NO_PLUGIN="$T/no-plugin-here"

# ── under budget: silent ──────────────────────────────────────────────────────
printf 'small file\n' > "$CLAUDE"
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$NO_PLUGIN")"
assert_eq "$out" "" "under budget: no output at all (learnings empty + CLAUDE.md small)"

# ── over budget (default 14000): reminder fires, names the actual size ───────
head -c 21000 /dev/zero | tr '\0' 'x' > "$CLAUDE"
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$NO_PLUGIN")"
assert_contains "$out" "CLAUDE.md" "over budget: reminder mentions CLAUDE.md"
assert_contains "$out" "CLAUDE-APPENDIX.md" "over budget: reminder points at CLAUDE-APPENDIX.md as the overflow destination"
assert_contains "$out" "21000" "over budget: reminder names the measured size"

# ── SHIPLOOP_CLAUDEMD_MAX_CHARS override honored ─────────────────────────────
printf 'twelve chars\n' > "$CLAUDE"   # 13 bytes incl newline
out="$(SHIPLOOP_CLAUDEMD_MAX_CHARS=5 bash "$DIGEST" "$LEARN" "$CLAUDE" "$NO_PLUGIN")"
assert_contains "$out" "budget 5" "override: a lowered SHIPLOOP_CLAUDEMD_MAX_CHARS trips on a normally-small file"

# ── missing CLAUDE.md: no error, no output from this check ───────────────────
rm -f "$CLAUDE"
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$NO_PLUGIN" 2>&1)"
assert_not_contains "$out" "CLAUDE.md is over budget" "missing CLAUDE.md: never fabricates a size warning"

assert_done
