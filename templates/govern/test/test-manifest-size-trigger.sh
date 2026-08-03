#!/usr/bin/env bash
# Regression: a free (zero-token) size-trigger detector on the SessionStart learnings-digest hook,
# extended to cover the INSTALLED PLUGIN's own manifest metadata — the `description:` frontmatter
# of SKILL.md + every commands/*.md. That surface is loaded into every session and re-sent every
# turn too (unlike a command's body, which only loads on invocation), so it needs the same free
# `wc -c`-style budget check the root CLAUDE.md already gets. Must fire when the summed description
# field VALUES exceed SHIPLOOP_MANIFEST_MAX_CHARS (default 1400) and stay silent under budget — and
# must degrade SILENTLY (no output, no error) when no plugin dir can be located at all.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Runs in BOTH layouts, same resolution as test-learnings-digest.sh / test-claudemd-size-trigger.sh.
HUB="$(cd "$DIR/../../.." && pwd)"
DIGEST=""
for c in "$HUB/templates/hooks/learnings-digest.sh" "$DIR/../../learnings-digest.sh"; do
  [ -f "$c" ] && { DIGEST="$c"; break; }
done
[ -n "$DIGEST" ] || { echo "SKIP: learnings-digest.sh not present"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LEARN="$T/learnings.md"; : > "$LEARN"           # entry-less — must not affect this check either way
CLAUDE="$T/CLAUDE.md"; printf 'small file\n' > "$CLAUDE"   # small — must not affect this check either way

PLUGIN="$T/plugin"; mkdir -p "$PLUGIN/commands"

write_manifest() {
  # $1 = SKILL.md description length in chars, $2 = commands/a.md description length in chars
  local skill_desc cmd_desc
  skill_desc="$(head -c "$1" /dev/zero | tr '\0' 's')"
  cmd_desc="$(head -c "$2" /dev/zero | tr '\0' 'c')"
  cat > "$PLUGIN/SKILL.md" <<EOF
---
name: shiploop
description: $skill_desc
---
# body — never counted, only loads on invocation
EOF
  cat > "$PLUGIN/commands/a.md" <<EOF
---
description: $cmd_desc
---
# body — never counted, only loads on invocation
EOF
}

# ── under budget (default 1400): silent ──────────────────────────────────────
write_manifest 100 100   # 200 chars total, well under 1400
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$PLUGIN")"
assert_eq "$out" "" "under budget: no output at all"

# ── over budget (default 1400): reminder fires, names the actual size ────────
write_manifest 1000 1000   # 2000 chars total
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$PLUGIN")"
assert_contains "$out" "plugin manifest" "over budget: reminder mentions the plugin manifest"
assert_contains "$out" "2000" "over budget: reminder names the measured size"
assert_contains "$out" "description:" "over budget: reminder points at description frontmatter as the remedy target"

# ── SHIPLOOP_MANIFEST_MAX_CHARS override honored ─────────────────────────────
write_manifest 10 10   # 20 chars total — normally fine
out="$(SHIPLOOP_MANIFEST_MAX_CHARS=5 bash "$DIGEST" "$LEARN" "$CLAUDE" "$PLUGIN")"
assert_contains "$out" "budget 5" "override: a lowered SHIPLOOP_MANIFEST_MAX_CHARS trips on a normally-small manifest"

# ── degrade silently: no plugin dir resolvable at all ─────────────────────────
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$T/does-not-exist" 2>&1)"
assert_not_contains "$out" "plugin manifest" "missing plugin dir: never fabricates a manifest-size warning"

# ── degrade silently: plugin dir exists but has no SKILL.md ───────────────────
EMPTY="$T/empty-plugin"; mkdir -p "$EMPTY"
out="$(bash "$DIGEST" "$LEARN" "$CLAUDE" "$EMPTY" 2>&1)"
assert_not_contains "$out" "plugin manifest" "plugin dir without SKILL.md: never fabricates a manifest-size warning"

assert_done
