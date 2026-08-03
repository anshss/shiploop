#!/usr/bin/env bash
# Proves the SessionStart learnings digest injects ENTRIES rather than LINES, and injects nothing at
# all when there is nothing to say. This is a context-cost mechanism: its output lands in every
# session's window, so "emits nothing on an empty file" is a correctness property, not a nicety.
#
# Covered:
#   - an entry-less file (the pristine seed) produces ZERO bytes
#   - the file's instructional preamble is never injected — only entries are
#   - entries are date-ranked, so an APPEND-ordered file still surfaces its NEWEST entries
#     (the legacy `head -30` surfaced the oldest ones)
#   - fenced code blocks are not entry boundaries (`## comment` in a shell snippet must not split)
#   - undated headings still surface, ranked last, rather than vanishing
#   - the entry and line caps are honoured, and truncation is disclosed
#   - settings-merge REWRITES a legacy inline `head -N learnings.md` hook in place instead of
#     appending a second learnings hook beside it (which would double the injection)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Runs in BOTH layouts: the hub (templates/govern/test/ → templates/hooks/) and a scaffolded
# workspace (scripts/govern/test/ → scripts/), which is where CI's scaffold-and-test recipe runs it.
HUB="$(cd "$DIR/../../.." && pwd)"
DIGEST=""
for c in "$HUB/templates/hooks/learnings-digest.sh" "$DIR/../../learnings-digest.sh"; do
  [ -f "$c" ] && { DIGEST="$c"; break; }
done
[ -n "$DIGEST" ] || { echo "SKIP: learnings-digest.sh not present"; exit 77; }
# Hub-only assets: the shipped seed and scaffold.sh don't exist inside a scaffolded workspace, so the
# assertions that need them are guarded rather than skipping the whole file.
SEED="$HUB/templates/seed/learnings.md"
SCAFFOLD="$HUB/scaffold.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'digest under test: %s\n' "$DIGEST"

# Passed as $2/$3 on every invocation below to isolate this test from whatever the CURRENT
# MACHINE happens to have at its real workspace-root CLAUDE.md or its real installed plugin
# (~/.claude/skills/shiploop, CLAUDE_PLUGIN_ROOT, …) — neither is under test here, and letting
# either resolve for real would leak size-trigger output into these entries-only assertions.
# See test-claudemd-size-trigger.sh / test-manifest-size-trigger.sh for those checks.
NO_CLAUDE="$T/no-claude-here.md"
NO_PLUGIN="$T/no-plugin-here"

# ── the pristine seed injects NOTHING (hub only) ─────────────────────────────
# The seed carries a preamble AND a fenced format example. Both must be invisible. This is the guard
# against someone re-introducing a `###` heading into the seed and silently re-taxing every fleet.
if [ -f "$SEED" ]; then
  assert_eq "$(bash "$DIGEST" "$SEED" "$NO_CLAUDE" "$NO_PLUGIN" | wc -c | tr -d ' ')" "0" \
    "the shipped seed learnings.md costs ZERO bytes at session start"
fi

# Same property, layout-independent: a file with a preamble but no entries emits nothing.
printf '# Workspace learnings\n\nPREAMBLE_SENTINEL only, no entries yet.\n' > "$T/entryless.md"
assert_eq "$(bash "$DIGEST" "$T/entryless.md" "$NO_CLAUDE" "$NO_PLUGIN" | wc -c | tr -d ' ')" "0" \
  "an entry-less learnings.md costs ZERO bytes at session start"

# ── preamble is never injected; entries are, newest first ────────────────────
# Deliberately APPEND-ordered (oldest at top) — the order the seed tells operators to write in, and
# the exact case the legacy `head -30` got backwards.
cat > "$T/append-ordered.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL — format doc that must never reach the model.
Promote when stable; work items go to tickets.md.

---

### 2026-01-02 — oldest
OLDEST_SENTINEL

### 2026-05-09 — middle
MIDDLE_SENTINEL

### 2026-07-20 — newest
NEWEST_SENTINEL
MD

out="$(bash "$DIGEST" "$T/append-ordered.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_not_contains "$out" "PREAMBLE_SENTINEL" "the instructional preamble is never injected"
assert_contains     "$out" "NEWEST_SENTINEL"   "the newest entry is injected"

out2="$(SHIPLOOP_LEARNINGS_MAX_ENTRIES=2 bash "$DIGEST" "$T/append-ordered.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains     "$out2" "NEWEST_SENTINEL" "cap=2 keeps the newest entry"
assert_contains     "$out2" "MIDDLE_SENTINEL" "cap=2 keeps the second-newest entry"
assert_not_contains "$out2" "OLDEST_SENTINEL" \
  "cap=2 drops the OLDEST entry — an append-ordered file is date-ranked, not head-truncated"
assert_contains     "$out2" "2 newest of 3" "truncation is disclosed, not silent"

# ── fenced code is not an entry boundary ─────────────────────────────────────
cat > "$T/fenced.md" <<'MD'
# Workspace learnings

PREAMBLE_SENTINEL

### 2026-03-01 — entry quoting a shell snippet

```bash
## NOT_A_HEADING — a comment inside a fence
echo hi
```
TAIL_SENTINEL
MD

out3="$(bash "$DIGEST" "$T/fenced.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains     "$out3" "TAIL_SENTINEL"      "a fenced '##' comment does not split the entry"
assert_not_contains "$out3" "PREAMBLE_SENTINEL"  "a fenced heading does not drag the preamble in"
assert_contains     "$out3" "learnings (1)"      "the fenced comment is not counted as a second entry"

# ── undated headings degrade to 'shown, ranked last' rather than vanishing ───
cat > "$T/undated.md" <<'MD'
# Workspace learnings

### a heading with no date
UNDATED_SENTINEL

### 2026-04-04 — dated
DATED_SENTINEL
MD

out4="$(bash "$DIGEST" "$T/undated.md" "$NO_CLAUDE" "$NO_PLUGIN")"
assert_contains "$out4" "UNDATED_SENTINEL" "an undated entry still surfaces (no silent drop)"
assert_contains "$out4" "DATED_SENTINEL"   "the dated entry surfaces alongside it"

# ── the line cap is a hard ceiling ───────────────────────────────────────────
{ echo "# Workspace learnings"; echo; echo "### 2026-09-09 — huge"
  i=0; while [ "$i" -lt 200 ]; do echo "filler line $i"; i=$((i+1)); done; } > "$T/huge.md"
lines="$(SHIPLOOP_LEARNINGS_MAX_LINES=10 bash "$DIGEST" "$T/huge.md" "$NO_CLAUDE" "$NO_PLUGIN" | wc -l | tr -d ' ')"
# 10 body lines + the one-line header.
assert_eq "$lines" "11" "SHIPLOOP_LEARNINGS_MAX_LINES caps the injected body"

# ── a missing file is silent, not an error ───────────────────────────────────
rc=0; bash "$DIGEST" "$T/does-not-exist.md" "$NO_CLAUDE" "$NO_PLUGIN" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "an absent learnings.md exits 0 (a SessionStart hook must never block)"

# ── settings-merge migrates the legacy inline hook IN PLACE ──────────────────
if command -v jq >/dev/null 2>&1 && [ -f "$SCAFFOLD" ]; then
  W="$T/legacy"; mkdir -p "$W/.claude"
  cat > "$W/.claude/settings.json" <<'MD'
{ "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash OLDROOT/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 },
  { "type": "command", "command": "if [ -f OLDROOT/learnings.md ]; then echo 'x'; head -30 OLDROOT/learnings.md; echo '...'; fi", "timeout": 5 }
] } ] }, "custom": {"keep": "me"} }
MD
  bash "$SCAFFOLD" --workspace-dir "$W" --templates "$HUB/templates" --pm npm --org t \
       --repos "a::echo a" --merge-allowlist "" --worktree-base "$W.wt" \
       --component settings-merge >/dev/null 2>&1 || true
  merged="$(cat "$W/.claude/settings.json")"
  assert_not_contains "$merged" "head -30" "the legacy inline head -30 hook is rewritten away"
  assert_eq "$(grep -c 'learnings-digest' <<<"$merged")" "1" \
    "exactly ONE learnings hook after migration (rewritten in place, not appended beside)"
  assert_contains "$merged" '"keep"' "unrelated settings keys survive the migration"
  assert_eq "$(grep -c 'session-snapshot' <<<"$merged")" "1" "sibling hooks are not duplicated"

  before="$(cat "$W/.claude/settings.json")"
  bash "$SCAFFOLD" --workspace-dir "$W" --templates "$HUB/templates" --pm npm --org t \
       --repos "a::echo a" --merge-allowlist "" --worktree-base "$W.wt" \
       --component settings-merge >/dev/null 2>&1 || true
  assert_eq "$(cat "$W/.claude/settings.json")" "$before" "the migration is idempotent"
fi

assert_done
