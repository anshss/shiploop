#!/usr/bin/env bash
# Regression for the "merge-tier" scaffold.sh components that let /shiploop:update
# converge CONFIG on an EXISTING workspace, not just the byte-comparable mechanism
# scripts (core-scripts/worktrees/govern/githooks/commands/workflows).
#
# Contract:
#   1. package-json-merge adds missing harness script keys, never overwrites an
#      operator key that collides (e.g. a pre-set "doctor").
#   2. package-json-merge is idempotent (byte-identical second run).
#   3. workspace-sh-merge appends an absent knob exactly once, and the file still
#      `source`s cleanly afterward.
#   4. workspace-sh-merge never appends identity fields (e.g. SLOT_PORT_STEP) and
#      never appends a line whose TEMPLATE form still carries a __placeholder__
#      (e.g. GOVERN_MERGE_REPOS, which is filled in only by component_workspace_sh).
#   5. seeds: a workspace seed file that is byte-identical to SOME historical
#      version recorded in templates/lib/seed-hashes.txt is upgraded losslessly.
#      Uses real git history of templates/seed/CLAUDE.md; skips gracefully if the
#      hub checkout has no usable history.
#   6. seeds: a file with ONE byte appended to a known-pristine seed is NEVER
#      touched — this is the critical safety invariant behind seed_pristine().
#   7. settings-merge repairs a stale harness hook (wrong flags + wrong timeout) to
#      canonical, while an operator hook whose command matches the same script
#      NAME but lives OUTSIDE the workspace root is left byte-for-byte untouched
#      (the contains($root) guard).
#   8. gitignore merge is idempotent — second run is byte-identical and only ONE
#      "shiploop scaffolded additions" banner ever appears.
#   9. --diff-only exits 0 when the byte-comparable mechanism components are in
#      sync even though config_drift_report has real (non-byte-comparable) drift
#      to report — config drift must never flip the exit code.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout — scaffold.sh + templates/ at ../../../.. (assert.sh
# sits in templates/govern/test/, same layout test-update-channel.sh resolves).
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed — merge-tier components need it"; exit 0; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── 1+2. package-json-merge: add missing keys, preserve operator collision, idempotent ──
W1="$ROOT/ws1"; mkdir -p "$W1"
cat > "$W1/package.json" <<'EOF'
{
  "name": "test-ws",
  "scripts": {
    "doctor": "my-own-thing",
    "custom:thing": "echo hi"
  }
}
EOF
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component package-json-merge --yes >/tmp/scaf-cfg-w1.log 2>&1
rc=$?
assert_eq "$rc" "0" "1. package-json-merge exits 0"
doctor_val="$(jq -r '.scripts.doctor' "$W1/package.json")"
assert_eq "$doctor_val" "my-own-thing" "1. operator-defined 'doctor' key survives the merge"
custom_val="$(jq -r '.scripts["custom:thing"]' "$W1/package.json")"
assert_eq "$custom_val" "echo hi" "1. unrelated operator key untouched"
dev_val="$(jq -r '.scripts.dev' "$W1/package.json")"
assert_eq "$dev_val" "bash scripts/dev.sh" "1. missing harness key 'dev' added"
wnew_val="$(jq -r '.scripts["worktree:new"]' "$W1/package.json")"
assert_eq "$wnew_val" "bash scripts/worktree/new.sh" "1. missing harness key 'worktree:new' added"
gval_val="$(jq -r '.scripts["govern:validations"]' "$W1/package.json")"
assert_eq "$gval_val" "bash scripts/govern/govern-validations.sh" "1. missing harness key 'govern:validations' added"

first_pkg="$(cat "$W1/package.json")"
bash "$SCAFFOLD" --workspace-dir "$W1" --templates "$TEMPLATES" \
  --component package-json-merge --yes >>/tmp/scaf-cfg-w1.log 2>&1
second_pkg="$(cat "$W1/package.json")"
assert_eq "$second_pkg" "$first_pkg" "2. package-json-merge second run is byte-identical (idempotent)"

# ── 3+4. workspace-sh-merge ──────────────────────────────────────────────────
W3="$ROOT/ws3"; mkdir -p "$W3"
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "alpha" \
  --worktree-base "$W3.wt" --component workspace-sh --yes >/tmp/scaf-cfg-w3.log 2>&1
WS_TARGET="$W3/scripts/lib/workspace.sh"
[ -f "$WS_TARGET" ] && printf 'ok   - 3. fresh workspace.sh scaffolded\n' || \
  { printf 'FAIL - 3. fresh workspace.sh missing\n'; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# Remove one genuine, non-identity knob line entirely — simulates a workspace
# scaffolded BEFORE the hub added this knob.
grep -v '^export GOVERN_PARALLEL_DEFAULT=' "$WS_TARGET" > "$WS_TARGET.tmp" && mv "$WS_TARGET.tmp" "$WS_TARGET"
n0=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOVERN_PARALLEL_DEFAULT=' "$WS_TARGET")
assert_eq "$n0" "0" "3. knob genuinely absent before merge (sanity)"

bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
  --component workspace-sh-merge --yes >>/tmp/scaf-cfg-w3.log 2>&1
n1=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOVERN_PARALLEL_DEFAULT=' "$WS_TARGET")
assert_eq "$n1" "1" "3. absent knob appended exactly once"

if bash -c "source '$WS_TARGET' && echo SOURCED_OK" 2>/tmp/scaf-cfg-source.log | grep -q SOURCED_OK; then
  printf 'ok   - 3. workspace.sh still sources cleanly after merge\n'
else
  printf 'FAIL - 3. workspace.sh failed to source after merge (see /tmp/scaf-cfg-source.log)\n'
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# Re-run merge — must not duplicate the knob it just appended.
bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
  --component workspace-sh-merge --yes >>/tmp/scaf-cfg-w3.log 2>&1
n2=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOVERN_PARALLEL_DEFAULT=' "$WS_TARGET")
assert_eq "$n2" "1" "3. re-running merge does not duplicate the knob"

# 4. Remove an IDENTITY field (SLOT_PORT_STEP) and the placeholder-carrying knob
# (GOVERN_MERGE_REPOS, whose TEMPLATE line still reads __GOVERN_MERGE_REPOS__) —
# neither must ever be re-appended by the knob merge, no matter how "absent" they are.
grep -v '^SLOT_PORT_STEP=' "$WS_TARGET" > "$WS_TARGET.tmp" && mv "$WS_TARGET.tmp" "$WS_TARGET"
grep -v '^GOVERN_MERGE_REPOS=' "$WS_TARGET" > "$WS_TARGET.tmp" && mv "$WS_TARGET.tmp" "$WS_TARGET"
n3=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SLOT_PORT_STEP=' "$WS_TARGET")
n4=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOVERN_MERGE_REPOS=' "$WS_TARGET")
assert_eq "$n3" "0" "4. identity field SLOT_PORT_STEP removed (sanity)"
assert_eq "$n4" "0" "4. GOVERN_MERGE_REPOS removed (sanity)"

bash "$SCAFFOLD" --workspace-dir "$W3" --templates "$TEMPLATES" \
  --component workspace-sh-merge --yes >>/tmp/scaf-cfg-w3.log 2>&1
n3b=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SLOT_PORT_STEP=' "$WS_TARGET")
n4b=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GOVERN_MERGE_REPOS=' "$WS_TARGET")
assert_eq "$n3b" "0" "4. identity field SLOT_PORT_STEP never re-appended"
assert_eq "$n4b" "0" "4. placeholder-carrying GOVERN_MERGE_REPOS never re-appended"

# ── 5. seeds: a provably-unedited HISTORICAL seed is upgraded losslessly ────
if git -C "$HUB" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cur_hash="$(shasum -a 256 "$TEMPLATES/seed/CLAUDE.md" | cut -d' ' -f1)"
  OLD_SEED_FILE="$ROOT/old-claude-seed.md"
  old_hash=""
  for c in $(git -C "$HUB" log --format=%H -- templates/seed/CLAUDE.md 2>/dev/null); do
    if git -C "$HUB" show "$c:templates/seed/CLAUDE.md" > "$OLD_SEED_FILE.cand" 2>/dev/null; then
      h="$(shasum -a 256 "$OLD_SEED_FILE.cand" | cut -d' ' -f1)"
      if [ "$h" != "$cur_hash" ] && grep -qE "^$h  CLAUDE\.md\$" "$TEMPLATES/lib/seed-hashes.txt"; then
        old_hash="$h"; mv "$OLD_SEED_FILE.cand" "$OLD_SEED_FILE"; break
      fi
    fi
  done
  rm -f "$OLD_SEED_FILE.cand"

  if [ -n "$old_hash" ]; then
    W5="$ROOT/ws5"; mkdir -p "$W5"
    cp "$OLD_SEED_FILE" "$W5/CLAUDE.md"
    bash "$SCAFFOLD" --workspace-dir "$W5" --templates "$TEMPLATES" \
      --component seeds --yes >/tmp/scaf-cfg-w5.log 2>&1
    if diff -q "$W5/CLAUDE.md" "$TEMPLATES/seed/CLAUDE.md" >/dev/null 2>&1; then
      printf 'ok   - 5. pristine historical seed (hash %s) upgraded to current CLAUDE.md\n' "$old_hash"
    else
      printf 'FAIL - 5. pristine historical seed (hash %s) was NOT upgraded\n' "$old_hash"
      ASSERT_FAILS=$((ASSERT_FAILS+1))
    fi
  else
    printf 'SKIP - 5. no historical CLAUDE.md seed hash found in seed-hashes.txt via git log (hub history unavailable/pruned) — skipping\n'
  fi
else
  printf 'SKIP - 5. hub checkout has no usable git history — skipping\n'
fi

# ── 6. seeds: CRITICAL SAFETY — one byte appended to a pristine seed = NEVER touched ──
W6="$ROOT/ws6"; mkdir -p "$W6"
cp "$TEMPLATES/seed/CLAUDE.md" "$W6/CLAUDE.md"
printf 'X' >> "$W6/CLAUDE.md"          # one byte, no longer hashes to any manifest entry
before_edit="$(cat "$W6/CLAUDE.md")"
bash "$SCAFFOLD" --workspace-dir "$W6" --templates "$TEMPLATES" \
  --component seeds --yes >/tmp/scaf-cfg-w6.log 2>&1
after_edit="$(cat "$W6/CLAUDE.md")"
assert_eq "$after_edit" "$before_edit" "6. CRITICAL SAFETY: a seed with ONE unrecorded byte is left completely untouched by component_seeds"

# ── 7. settings-merge: repair a stale harness hook; leave a same-named foreign hook alone ──
W7="$ROOT/ws7"; mkdir -p "$W7/.claude"
cat > "$W7/.claude/settings.json" <<EOF
{ "hooks": { "SessionStart": [ { "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $W7/scripts/session-snapshot.sh --wrong-flag 2>/dev/null || true", "timeout": 999 },
  { "type": "command", "command": "bash /opt/other-workspace/scripts/session-snapshot.sh --custom 2>/dev/null || true", "timeout": 5 }
] } ] } }
EOF
bash "$SCAFFOLD" --workspace-dir "$W7" --templates "$TEMPLATES" \
  --component settings-merge --yes >/tmp/scaf-cfg-w7.log 2>&1
rc=$?
assert_eq "$rc" "0" "7. settings-merge exits 0"
if jq empty "$W7/.claude/settings.json" >/dev/null 2>&1; then
  printf 'ok   - 7. resulting settings.json is valid JSON\n'
else
  printf 'FAIL - 7. resulting settings.json is INVALID JSON\n'
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
canonical_cmd="bash $W7/scripts/session-snapshot.sh 2>/dev/null || true"
repaired="$(jq -r --arg root "$W7" \
  '.hooks.SessionStart[].hooks[] | select(.command | contains($root)) | select(.command | contains("session-snapshot.sh")) | .command' \
  "$W7/.claude/settings.json")"
assert_eq "$repaired" "$canonical_cmd" "7. stale in-workspace hook command repaired to canonical"
repaired_timeout="$(jq -r --arg root "$W7" \
  '.hooks.SessionStart[].hooks[] | select(.command | contains($root)) | select(.command | contains("session-snapshot.sh")) | .timeout' \
  "$W7/.claude/settings.json")"
assert_eq "$repaired_timeout" "15" "7. stale in-workspace hook timeout repaired to canonical"
foreign_cmd="$(jq -r '.hooks.SessionStart[].hooks[] | select(.command | contains("/opt/other-workspace")) | .command' "$W7/.claude/settings.json")"
assert_eq "$foreign_cmd" "bash /opt/other-workspace/scripts/session-snapshot.sh --custom 2>/dev/null || true" \
  "7. same-named but OUT-OF-WORKSPACE operator hook command untouched"
foreign_timeout="$(jq -r '.hooks.SessionStart[].hooks[] | select(.command | contains("/opt/other-workspace")) | .timeout' "$W7/.claude/settings.json")"
assert_eq "$foreign_timeout" "5" "7. same-named but OUT-OF-WORKSPACE operator hook timeout untouched"

# ── 8. gitignore merge: idempotent, exactly ONE banner ──────────────────────
W8="$ROOT/ws8"; mkdir -p "$W8"
echo "node_modules/" > "$W8/.gitignore"
bash "$SCAFFOLD" --workspace-dir "$W8" --templates "$TEMPLATES" \
  --component gitignore --yes >/tmp/scaf-cfg-w8.log 2>&1
first_gi="$(cat "$W8/.gitignore")"
banner_count_1=$(grep -c "shiploop scaffolded additions" "$W8/.gitignore")
assert_eq "$banner_count_1" "1" "8. exactly one banner after first (appending) run"

bash "$SCAFFOLD" --workspace-dir "$W8" --templates "$TEMPLATES" \
  --component gitignore --yes >>/tmp/scaf-cfg-w8.log 2>&1
second_gi="$(cat "$W8/.gitignore")"
assert_eq "$second_gi" "$first_gi" "8. second run is byte-identical (idempotent)"
banner_count_2=$(grep -c "shiploop scaffolded additions" "$W8/.gitignore")
assert_eq "$banner_count_2" "1" "8. still exactly one banner after second (no-op) run"

# ── 9. --diff-only: config drift reported, but exit code stays 0 ────────────
W9="$ROOT/ws9"; mkdir -p "$W9"
bash "$SCAFFOLD" --workspace-dir "$W9" --templates "$TEMPLATES" \
  --pm npm --org testorg --repos "alpha::echo alpha" --merge-allowlist "alpha" \
  --worktree-base "$W9.wt" --yes >/tmp/scaf-cfg-w9.log 2>&1
rm -f "$W9/README.md"        # config drift: README absent — NOT a MECH_COMPONENTS file
out="$(bash "$SCAFFOLD" --workspace-dir "$W9" --templates "$TEMPLATES" --diff-only 2>&1)"; rc=$?
assert_eq "$rc" "0" "9. --diff-only exit 0 even though config drift exists"
assert_contains "$out" "README.md" "9. config drift report names README.md as absent"
assert_not_contains "$out" "behind (" "9. no mechanism component reports drift"

assert_done
