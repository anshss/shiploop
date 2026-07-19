#!/usr/bin/env bash
# Regression for the v1.2.0 update channel — VERSION + stamp + doctor
# staleness + scaffold --version + --diff-only + relocations warning +
# knob-migration guard + settings-merge component.
#
# Contract:
#   1. hub VERSION file readable via scaffold --version
#   2. N7: a partial run on a NON-converged workspace does NOT write the stamp
#   3. --diff-only against a fresh scaffold → in-sync (exit 0); convergence stamps = VERSION
#   4. --diff-only after mutating an installed file → behind (exit 3)
#   5. --component workspace-sh detects legacy array knobs → migration warning
#   6. --component settings-merge inserts stanzas into existing settings.json (idempotent)
#   7. relocations.txt hit → --verify prints stale-relocated warning
#   8. doctor.sh warns when stamp is behind hub VERSION
#   9. N7: a partial --component run does not flip doctor to "up to date" while another
#      mechanism component is behind; the converging bump then advances the stamp
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Hub layout resolver — this test only makes sense IN a hub checkout (needs
# scaffold.sh + templates/ + VERSION). assert.sh sits in templates/govern/test/,
# so ../../.. is the hub root.
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── 1. hub VERSION resolvable ───────────────────────────────────────────────
v="$(bash "$SCAFFOLD" --version 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. scaffold --version → exit 0"
[ -n "$v" ] && printf 'ok   - 1. --version printed: %s\n' "$v" || { printf 'FAIL - 1. --version empty\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ "$v" = "$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$HUB/VERSION")" ] && \
  printf 'ok   - 1. --version matches VERSION file\n' || \
  { printf 'FAIL - 1. --version mismatch\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 2. N7: a partial run on a NON-converged workspace does NOT stamp ────────
W1="$ROOT/ws1"; mkdir -p "$W1"
# Feed the minimum required flags for a fresh workspace.sh. Only workspace.sh is
# installed — all six mechanism components are absent → drift → the stamp gate
# (workspace_converged) must refuse to write .harness-version.
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W1.wt" --component workspace-sh --yes >/tmp/scaf-w1.log 2>&1 || \
  { printf 'FAIL - 2. workspace-sh scaffold errored (see /tmp/scaf-w1.log)\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ ! -f "$W1/scripts/lib/.harness-version" ] && printf 'ok   - 2. partial run on non-converged workspace left NO stamp (N7)\n' || \
  { printf 'FAIL - 2. stamp written despite mechanism drift (N7 regression)\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 3. --diff-only after a full component sync → in-sync per component ─────
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component core-scripts --yes >/dev/null 2>&1
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component worktrees    --yes >/dev/null 2>&1
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component govern       --yes >/dev/null 2>&1
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component githooks     --yes >/dev/null 2>&1
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component commands     --yes >/dev/null 2>&1
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component workflows    --yes >/dev/null 2>&1
out="$(bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "0" "3. --diff-only after full sync → exit 0 (in-sync)"
assert_contains "$out" "core-scripts: in-sync" "3. reports core-scripts in-sync"
assert_contains "$out" "govern: in-sync" "3. reports govern in-sync"
# N7: convergence stamps. Now that every mechanism component matches templates,
# the last bump's component_stamp DID write .harness-version = hub VERSION.
stamp_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W1/scripts/lib/.harness-version" 2>/dev/null)"
assert_eq "$stamp_v" "$v" "3. converged workspace stamps = hub VERSION (N7)"

# ── 4. mutate an installed file → --diff-only reports behind (exit 3) ──────
echo "# drift" >> "$W1/scripts/govern/run-loop.sh"
out="$(bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "3" "4. after drift → --diff-only exit 3"
assert_contains "$out" "govern: behind" "4. govern reported behind"

# ── 5. legacy array knob → migration warning ────────────────────────────────
W2="$ROOT/ws2"; mkdir -p "$W2/scripts/lib"
# Seed a workspace.sh with the legacy array shape.
cat > "$W2/scripts/lib/workspace.sh" <<'EOF'
#!/usr/bin/env bash
GOVERN_MERGE_REPOS=(foo bar)
GOVERN_LOCAL_FIRST_REPOS=(baz)
EOF
out="$(bash "$SCAFFOLD" --workspace-dir "$W2" --templates "$TEMPLATES" \
   --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
   --worktree-base "$W2.wt" --component workspace-sh 2>&1)"; rc=$?
# rc may be 0 (refused overwrite) — the *warning* is what we assert.
assert_contains "$out" "LEGACY bash-array" "5. legacy array knob warning"
assert_contains "$out" 'GOVERN_MERGE_REPOS="foo bar"' "5. warning shows mechanical migration"

# ── 6. --component settings-merge into an existing settings.json ───────────
W3="$ROOT/ws3"; mkdir -p "$W3/.claude"
echo '{"hooks": {}, "custom": {"my": "config"}}' > "$W3/.claude/settings.json"
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
   --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
   --worktree-base "$W3.wt" --component settings-merge >/tmp/scaf-w3.log 2>&1
merged="$(cat "$W3/.claude/settings.json")"
assert_contains "$merged" "session-snapshot.sh" "6. SessionStart hook added"
assert_contains "$merged" "router-posture-reminder.sh" "6. UserPromptSubmit hook added"
assert_contains "$merged" "ticket-sweep-reminder.sh" "6. Stop hook added"
assert_contains "$merged" '"my": "config"' "6. pre-existing custom top-level key preserved"
# Idempotent: run it again, expect no additional stanzas.
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
   --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
   --worktree-base "$W3.wt" --component settings-merge >>/tmp/scaf-w3.log 2>&1
merged2="$(cat "$W3/.claude/settings.json")"
# Same count of session-snapshot references before + after → idempotent.
n1=$(grep -c 'session-snapshot' <<<"$merged")
n2=$(grep -c 'session-snapshot' <<<"$merged2")
assert_eq "$n1" "$n2" "6. idempotent (no duplicate stanzas on re-run)"

# ── 6b. a NEWLY-introduced hook lands on an install whose event already has SOME harness hooks ──
# Regression: the old whole-event marker test skipped SessionStart entirely if ANY marker matched, so
# validations-pending-hook.sh (added after an install already carried session-snapshot.sh) never
# appended. Per-hook checking must add the missing hook WITHOUT duplicating the sibling already there.
W3b="$ROOT/ws3b"; mkdir -p "$W3b/.claude"
cat > "$W3b/.claude/settings.json" <<'EOF'
{ "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash SOMEROOT/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 },
  { "type": "command", "command": "bash SOMEROOT/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
] } ] } }
EOF
bash "$SCAFFOLD" --workspace-dir "$W3b" --templates "$TEMPLATES" \
   --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
   --worktree-base "$W3b.wt" --component settings-merge >>/tmp/scaf-w3.log 2>&1
merged3="$(cat "$W3b/.claude/settings.json")"
assert_contains "$merged3" "validations-pending-hook.sh" "6b. newly-introduced SessionStart hook appended despite an existing sibling"
assert_eq "$(grep -c 'session-snapshot' <<<"$merged3")" "1" "6b. pre-existing sibling hook not duplicated"
assert_contains "$merged3" "router-posture-reminder.sh" "6b. an entirely-missing event is still wired"

# ── 7. relocations.txt hit → --verify prints stale-relocated warning ───────
W4="$ROOT/ws4"
cp -R "$W1" "$W4"
# Simulate a stale-relocated file at the OLD path per the manifest.
mkdir -p "$W4/scripts/worktree/test"
echo "# stale" > "$W4/scripts/worktree/test/test-base-ref.sh"
out="$(bash "$SCAFFOLD" --workspace-dir "$W4" --templates "$TEMPLATES" \
   --component core-scripts --yes --verify 2>&1)"
assert_contains "$out" "stale-relocated" "7. --verify warns about relocated file"
assert_contains "$out" "test-base-ref.sh" "7. warning names the file"

# ── 8. doctor.sh staleness warning ─────────────────────────────────────────
# Seed workspace with a stamp = "0.9.0", point CLAUDE_PLUGIN_ROOT at a fake hub with VERSION=99.0.0.
FAKE_HUB="$ROOT/fake-hub"; mkdir -p "$FAKE_HUB"
echo "99.0.0" > "$FAKE_HUB/VERSION"
mkdir -p "$W1/scripts/lib"
printf '0.9.0\n' > "$W1/scripts/lib/.harness-version"
out="$(CLAUDE_PLUGIN_ROOT="$FAKE_HUB" bash "$W1/scripts/doctor.sh" 2>&1 || true)"
assert_contains "$out" "BEHIND" "8. doctor warns BEHIND hub"
assert_contains "$out" "99.0.0" "8. shows the hub version"

# ── 9. N7: a partial --component run doesn't flip doctor to "up to date" ─────
#      while another mechanism component is still behind; the converging bump
#      then advances the stamp. This is finding N7's done-when, end-to-end.
W5="$ROOT/ws5"; mkdir -p "$W5"
# Full scaffold → W5 starts fully converged (stamp = hub VERSION).
bash "$SCAFFOLD" --workspace-dir "$W5" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "" \
  --worktree-base "$W5.wt" --yes >/tmp/scaf-w5.log 2>&1
# Simulate an OLDER, drifted workspace: stamp behind + real drift in one component.
printf '0.9.0\n' > "$W5/scripts/lib/.harness-version"
echo "# drift" >> "$W5/scripts/govern/run-loop.sh"
# A partial bump of an UNRELATED component must NOT re-stamp — govern is still behind.
bash "$SCAFFOLD" --workspace-dir "$W5" --templates "$TEMPLATES" \
  --component githooks --yes >/dev/null 2>&1
stamp5="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W5/scripts/lib/.harness-version" 2>/dev/null)"
assert_eq "$stamp5" "0.9.0" "9. partial run left stamp behind (govern still drifted)"
# doctor must still report BEHIND, not "up to date".
out="$(CLAUDE_PLUGIN_ROOT="$HUB" bash "$W5/scripts/doctor.sh" 2>&1 || true)"
assert_contains "$out" "BEHIND" "9. doctor still reports BEHIND after the partial run"
# Now converge the drift → the next bump stamps current.
bash "$SCAFFOLD" --workspace-dir "$W5" --templates "$TEMPLATES" \
  --component govern --yes >/dev/null 2>&1
stamp5b="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W5/scripts/lib/.harness-version" 2>/dev/null)"
assert_eq "$stamp5b" "$v" "9. convergence bump advances stamp to hub VERSION"

assert_done
