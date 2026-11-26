#!/usr/bin/env bash
# tools/launcher-setup.sh: installs, from a model profile, the wiring that lets Claude Code run on
# a model family: a settings file, a machine-owned conf of placeholders, and a marked block in the
# shell rc defining <family>().
#
# Every run here is against a fixture HOME. The installer is never pointed at the real one, and
# the launcher is exercised with a stub `claude` function so no model endpoint is ever contacted.
#
#   1. a fresh install writes all three things; the conf is mode 600 with placeholders
#   2. the glm settings file is byte-exact what the profile and the reference shape dictate
#   3. a second run changes nothing: settings, conf and rc are byte-identical
#   4. the rc outside the marked block is untouched, before and after a re-run
#   5. a stale block is replaced in place: sibling family block, inode and a missing final
#      newline all survive
#   6. a pre-populated conf is kept byte for byte, mode and all, and its contents never reach
#      the installer's output
#   7. a profile without WINDOW (the shipped claude one) yields no modelSettings and no
#      CLAUDE_CODE_* exports, and calls the claude binary through `command`; a fixture profile
#      covers odd ids, labels, and WINDOW present
#   8. refusals write nothing: ambiguous or misordered markers, an unknown family, a malformed
#      profile, a tool copied out of the hub
#   9. the launcher itself: refuses on placeholders naming the conf path, launches with the
#      settings path, the hub path and its arguments otherwise, under bash and zsh
#  10. a same-named function outside the block draws one warning; none draws none
#  11. no arguments is a usage error
#
# This is a HUB-CONTEXT test: it runs the hub's tools/launcher-setup.sh against the hub's
# templates/lib/model-profiles/, so it exits 77 outside a hub checkout and is listed in
# tools/hub-context-tests.txt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
INSTALLER="$HUB/tools/launcher-setup.sh"
PROFILES="$HUB/templates/lib/model-profiles"
[ -f "$INSTALLER" ] && [ -d "$PROFILES" ] || { echo "SKIP: not running from a hub checkout ($HUB)"; exit 77; }
# The block embeds the hub's physical path; resolve the same way the installer does.
HUB_P="$(cd "$HUB" && pwd -P)"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mode_of() { # <path> -> permission bits
  if [ "$(uname)" = "Darwin" ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
inode_of() { # <path> -> inode
  if [ "$(uname)" = "Darwin" ]; then stat -f %i "$1"; else stat -c %i "$1"; fi
}

# run_installer <home> <rc> <family> [profile_dir]
# Captures stdout+stderr in $out and the exit status in $rc. GOVERN_MODEL_PROFILE_DIR is cleared
# unless a fixture profile directory is passed: a live session may export it.
run_installer() {
  if [ "$#" -ge 4 ]; then
    out="$(HOME="$1" SHELL_RC="$2" GOVERN_MODEL_PROFILE_DIR="$4" bash "$INSTALLER" "$3" 2>&1)"; rc=$?
  else
    out="$(env -u GOVERN_MODEL_PROFILE_DIR HOME="$1" SHELL_RC="$2" bash "$INSTALLER" "$3" 2>&1)"; rc=$?
  fi
}

# launch <home> <rc> <shell> [args...]
# Sources the rc in a clean environment (only HOME and PATH) with a stub `claude` that prints its
# arguments and the variables the launcher exports, then calls <family> from the rc.
LAUNCH_SCRIPT='
claude() {
  echo "STUB-CLAUDE"
  for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN API_TIMEOUT_MS CLAUDE_CODE_MAX_CONTEXT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL SHIPLOOP_MODEL_PROFILE; do
    eval "echo \"$v=\${$v}\""
  done
  for a in "$@"; do echo "ARG:$a"; done
}
. "$HOME/.zshrc"
glm "$@"
'
launch() { # <home> <shell> [args...] -> output; exit status in $rc
  local home="$1" shell="$2"; shift 2
  out="$(env -i HOME="$home" PATH="$PATH" "$shell" -c "$LAUNCH_SCRIPT" launcher "$@" 2>&1)"; rc=$?
}

count_block_markers() { grep -c '^# >>> shiploop launcher' "$1" 2>/dev/null || true; }

# ── 1. fresh install ───────────────────────────────────────────────────────────────────────────
H1="$ROOT/h1"; RC1="$H1/.zshrc"; mkdir -p "$H1"
printf '# my zshrc\nexport EDITOR=vim\n' > "$RC1"
run_installer "$H1" "$RC1" glm
assert_eq "$rc" "0" "1. a fresh glm install succeeds"
S1="$H1/.claude/settings-glm.json"; C1="$H1/.shiploop/launchers/glm.conf"
[ -f "$S1" ] && printf 'ok   - 1. the settings file exists at ~/.claude/settings-glm.json\n' || { echo "FAIL - 1. the settings file exists"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ -f "$C1" ] && printf 'ok   - 1. the conf exists at ~/.shiploop/launchers/glm.conf\n' || { echo "FAIL - 1. the conf exists"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_eq "$(mode_of "$C1")" "600" "1. the conf is mode 600"
conf_text="$(cat "$C1")"
assert_contains "$conf_text" 'BASE_URL="REPLACE_WITH_ENDPOINT_URL"' "1. the conf holds a BASE_URL placeholder"
assert_contains "$conf_text" 'AUTH_TOKEN="REPLACE_WITH_API_TOKEN"' "1. the conf holds an AUTH_TOKEN placeholder"
assert_contains "$out" "$C1 created with mode 600" "1. the installer says the conf was created"
assert_contains "$out" "block added to $RC1" "1. the installer says the block was added"
assert_eq "$(count_block_markers "$RC1")" "1" "1. the rc holds exactly one launcher block"
assert_contains "$(cat "$RC1")" "$(printf '# my zshrc\nexport EDITOR=vim')" "1. the rc's own lines survive the append"
assert_contains "$(cat "$RC1")" "--plugin-dir \"$HUB_P\"" "1. the block embeds the running hub checkout's path"

# ── 2. the settings file is byte-exact ────────────────────────────────────────────────────────
EXPECTED_GLM='{
  "modelPicker": {
    "replaceBuiltInOptions": true,
    "options": [
      { "model": "glm-5.4[1m]", "label": "GLM 5.4", "description": "Advisor tier, 1M context" },
      { "model": "glm-5.3[1m]", "label": "GLM 5.3", "description": "No shiploop role, 1M context" },
      { "model": "glm-5.3-flash[1m]", "label": "GLM 5.3 Flash", "description": "Worker tier, 1M context" }
    ]
  },
  "modelSettings": {
    "glm-5.4": { "autoCompactWindow": 1000000 },
    "glm-5.3": { "autoCompactWindow": 1000000 },
    "glm-5.3-flash": { "autoCompactWindow": 1000000 }
  }
}'
assert_eq "$(cat "$S1")" "$EXPECTED_GLM" "2. the glm settings file is exactly what the profile dictates (labels derived, roles described, bare ids given the window)"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$S1" >/dev/null 2>&1 && printf 'ok   - 2. the settings file parses as JSON\n' || { echo "FAIL - 2. the settings file parses as JSON"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
else
  echo "info - jq not on PATH: JSON parse check skipped"
fi

# ── 3. a second run changes nothing ───────────────────────────────────────────────────────────
cp "$S1" "$ROOT/s1.first"; cp "$C1" "$ROOT/c1.first"; cp "$RC1" "$ROOT/rc1.first"
run_installer "$H1" "$RC1" glm
assert_eq "$rc" "0" "3. the second run succeeds"
cmp -s "$S1" "$ROOT/s1.first" && printf 'ok   - 3. the settings file is byte-identical across runs\n' || { echo "FAIL - 3. the settings file is byte-identical across runs"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
cmp -s "$C1" "$ROOT/c1.first" && printf 'ok   - 3. the placeholder conf is byte-identical across runs\n' || { echo "FAIL - 3. the placeholder conf is byte-identical across runs"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
cmp -s "$RC1" "$ROOT/rc1.first" && printf 'ok   - 3. the rc is byte-identical across runs (block updated in place)\n' || { echo "FAIL - 3. the rc is byte-identical across runs"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$out" "block updated in $RC1" "3. the second run reports an update, not an add"

# ── 4. the rc outside the block is untouched ─────────────────────────────────────────────────
strip_block() { # <rc> -> every line outside the glm block
  awk '$0 == "# >>> shiploop launcher (glm) >>>" { skipping = 1; next } $0 == "# <<< shiploop launcher (glm) <<<" { skipping = 0; next } !skipping' "$1"
}
assert_eq "$(strip_block "$RC1")" "$(printf '# my zshrc\nexport EDITOR=vim')" "4. after two runs the rc holds exactly its original lines plus the block"

# ── 5. a stale block is replaced in place ────────────────────────────────────────────────────
H5="$ROOT/h5"; RC5="$H5/.zshrc"; mkdir -p "$H5"
# No final newline on purpose: the splice must give it back the same way.
printf '# head\n# >>> shiploop launcher (glm) >>>\nSTALE BLOCK LINE\n# <<< shiploop launcher (glm) <<<\n# mid\n# >>> shiploop launcher (claude) >>>\n# SIBLING BLOCK LINE\n# <<< shiploop launcher (claude) <<<\n# tail' > "$RC5"
ino5="$(inode_of "$RC5")"
run_installer "$H5" "$RC5" glm
assert_eq "$rc" "0" "5. replacing a stale block succeeds"
assert_eq "$(inode_of "$RC5")" "$ino5" "5. the rc keeps its inode"
assert_not_contains "$(cat "$RC5")" "STALE BLOCK LINE" "5. the stale block content is gone"
assert_contains "$(cat "$RC5")" "--plugin-dir \"$HUB_P\"" "5. the new block is in"
assert_contains "$(cat "$RC5")" "# SIBLING BLOCK LINE" "5. another family's block is left alone"
assert_eq "$(strip_block "$RC5")" "$(printf '# head\n# mid\n# >>> shiploop launcher (claude) >>>\n# SIBLING BLOCK LINE\n# <<< shiploop launcher (claude) <<<\n# tail')" "5. every line outside the glm block is byte-identical"
[ -n "$(tail -c1 "$RC5")" ] && printf 'ok   - 5. a missing final newline stays missing\n' || { echo "FAIL - 5. a missing final newline stays missing"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# Block order survives: the glm block still sits where the stale one was, between head and mid.
l_open5="$(grep -n '^# >>> shiploop launcher (glm) >>>$' "$RC5" | cut -d: -f1)"
l_close5="$(grep -n '^# <<< shiploop launcher (glm) <<<$' "$RC5" | cut -d: -f1)"
l_mid5="$(grep -n '^# mid$' "$RC5" | cut -d: -f1)"
assert_eq "$l_open5" "2" "5. the glm block opens on the line the stale one opened on"
[ "$l_close5" -lt "$l_mid5" ] && printf 'ok   - 5. the glm block closes before the lines that followed it\n' || { echo "FAIL - 5. the glm block closes before the lines that followed it"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 6. a pre-populated conf is kept ──────────────────────────────────────────────────────────
H6="$ROOT/h6"; RC6="$H6/.zshrc"; mkdir -p "$H6/.shiploop/launchers"
: > "$RC6"
printf 'BASE_URL="https://example.invalid/v1"\nAUTH_TOKEN="fixture-secret-0p3n"\nAPI_TIMEOUT_MS="3000000"\n' > "$H6/.shiploop/launchers/glm.conf"
chmod 640 "$H6/.shiploop/launchers/glm.conf"; ino6="$(inode_of "$H6/.shiploop/launchers/glm.conf")"
run_installer "$H6" "$RC6" glm
assert_eq "$rc" "0" "6. installing over a filled-in conf succeeds"
assert_eq "$(cat "$H6/.shiploop/launchers/glm.conf")" "$(printf 'BASE_URL="https://example.invalid/v1"\nAUTH_TOKEN="fixture-secret-0p3n"\nAPI_TIMEOUT_MS="3000000"\n')" "6. the conf is byte-identical after the run"
assert_eq "$(inode_of "$H6/.shiploop/launchers/glm.conf")" "$ino6" "6. the conf keeps its inode"
assert_eq "$(mode_of "$H6/.shiploop/launchers/glm.conf")" "640" "6. the conf keeps its mode"
assert_not_contains "$out" "fixture-secret-0p3n" "6. the conf's token never appears in the installer's output"
assert_not_contains "$out" "example.invalid" "6. the conf's endpoint never appears in the installer's output"
assert_contains "$out" "kept as it is" "6. the installer says the conf was kept"
run_installer "$H6" "$RC6" glm
assert_not_contains "$(cat "$H6/.shiploop/launchers/glm.conf")" "REPLACE_WITH_" "6. a second run still leaves the filled-in conf alone"

# ── 7. WINDOW-less and fixture profiles ──────────────────────────────────────────────────────
H7="$ROOT/h7"; RC7="$H7/.zshrc"; mkdir -p "$H7"; : > "$RC7"
run_installer "$H7" "$RC7" claude
assert_eq "$rc" "0" "7. the shipped claude profile installs"
assert_not_contains "$(cat "$H7/.claude/settings-claude.json")" "modelSettings" "7. no WINDOW: no modelSettings block"
assert_not_contains "$(cat "$H7/.claude/settings-claude.json")" "autoCompactWindow" "7. no WINDOW: no autoCompactWindow anywhere"
assert_contains "$(cat "$H7/.claude/settings-claude.json")" '{ "model": "claude-haiku-5-5", "label": "CLAUDE Haiku 5.5", "description": "Lookup tier" }' "7. no WINDOW: the description is the role tier alone"
assert_not_contains "$(cat "$RC7")" "CLAUDE_CODE_" "7. no WINDOW: no CLAUDE_CODE_* exports in the block"
assert_contains "$(cat "$RC7")" 'command claude --settings "$HOME/.claude/settings-claude.json"' "7. the claude family calls the binary through command (its own function would recurse)"

P7="$ROOT/profiles"; mkdir -p "$P7"
cat > "$P7/od.conf" <<'PROFILE'
FAMILY=od
# ROLE_fake="commented-out"
PICKER="od-4[1m]|od-4|od-4-mini-32b[2m]|od-2025-11-27-flash|od3-turbo|od-lite"
WINDOW=250000
ROLE_advisor="od-4[1m]"
ROLE_investigator="od-4-mini-32b[2m]"
ROLE_worker="od-lite"
TIER_ORDER="advisor investigator worker"
PROFILE
run_installer "$H7" "$RC7" od "$P7"
assert_eq "$rc" "0" "7. a fixture profile installs"
assert_contains "$(cat "$H7/.claude/settings-od.json")" '{ "model": "od-4[1m]", "label": "OD 4", "description": "Advisor tier, 250K context" },' "7. label: first word uppercased, digits joined; description: highest tier role, window in K"
assert_contains "$(cat "$H7/.claude/settings-od.json")" '{ "model": "od-4-mini-32b[2m]", "label": "OD 4 Mini 32b", "description": "Investigator tier, 250K context" },' "7. label: later words title-cased, a token that is not a word stays lowercase"
assert_contains "$(cat "$H7/.claude/settings-od.json")" '{ "model": "od-2025-11-27-flash", "label": "OD 2025.11.27 Flash", "description": "No shiploop role, 250K context" },' "7. label: a run of digit tokens joins with dots; a commented ROLE_ line is not a role"
assert_contains "$(cat "$H7/.claude/settings-od.json")" '{ "model": "od-lite", "label": "OD Lite", "description": "Worker tier, 250K context" }' "7. the last row carries no trailing comma"
modelsettings7="$(sed -n '/"modelSettings"/,/^  }/p' "$H7/.claude/settings-od.json")"
assert_eq "$(grep -c '"autoCompactWindow"' <<<"$modelsettings7")" "5" "7. modelSettings holds one entry per bare id (od-4 with and without a suffix is written once)"
assert_contains "$modelsettings7" "$(printf ' { "autoCompactWindow": 250000 }\n  }')" "7. the last modelSettings entry carries no trailing comma"
assert_contains "$(cat "$RC7")" 'export CLAUDE_CODE_MAX_CONTEXT_TOKENS="250000"' "7. the block exports the profile's window"
assert_contains "$(cat "$RC7")" 'export ANTHROPIC_DEFAULT_SONNET_MODEL="od-4-mini-32b[2m]"' "7. the sonnet slot takes ROLE_investigator"
assert_contains "$(cat "$RC7")" 'export ANTHROPIC_DEFAULT_HAIKU_MODEL="od-lite"' "7. the haiku slot takes ROLE_worker"
assert_contains "$(cat "$RC7")" 'export SHIPLOOP_MODEL_PROFILE="od"' "7. the block exports the family as SHIPLOOP_MODEL_PROFILE"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$H7/.claude/settings-od.json" >/dev/null 2>&1 && printf 'ok   - 7. the fixture settings file parses as JSON\n' || { echo "FAIL - 7. the fixture settings file parses as JSON"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
fi

# ── 8. refusals write nothing ────────────────────────────────────────────────────────────────
H8="$ROOT/h8"; RC8="$H8/.zshrc"; mkdir -p "$H8"
# Two opening markers.
printf '# rc\n# >>> shiploop launcher (glm) >>>\n# <<< shiploop launcher (glm) <<<\n# >>> shiploop launcher (glm) >>>\n' > "$RC8"; cp "$RC8" "$ROOT/rc8.copy"
run_installer "$H8" "$RC8" glm
[ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && printf 'ok   - 8. two opening markers: refused\n' || { echo "FAIL - 8. two opening markers: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
cmp -s "$RC8" "$ROOT/rc8.copy" && printf 'ok   - 8. two opening markers: the rc is untouched\n' || { echo "FAIL - 8. two opening markers: the rc is untouched"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
[ ! -e "$H8/.claude" ] && [ ! -e "$H8/.shiploop" ] && printf 'ok   - 8. two opening markers: no settings file, no conf\n' || { echo "FAIL - 8. two opening markers: nothing else written"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# Closing marker before the opening one.
printf '# <<< shiploop launcher (glm) <<<\n# >>> shiploop launcher (glm) >>>\n' > "$RC8"; cp "$RC8" "$ROOT/rc8.copy"
run_installer "$H8" "$RC8" glm
[ "$rc" -eq 1 ] && printf 'ok   - 8. misordered markers: refused with exit 1\n' || { echo "FAIL - 8. misordered markers: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
cmp -s "$RC8" "$ROOT/rc8.copy" && printf 'ok   - 8. misordered markers: the rc is untouched\n' || { echo "FAIL - 8. misordered markers: the rc is untouched"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# A lone opening marker.
printf '# rc\n# >>> shiploop launcher (glm) >>>\n' > "$RC8"; cp "$RC8" "$ROOT/rc8.copy"
run_installer "$H8" "$RC8" glm
[ "$rc" -eq 1 ] && cmp -s "$RC8" "$ROOT/rc8.copy" && printf 'ok   - 8. a lone marker: refused, rc untouched\n' || { echo "FAIL - 8. a lone marker: refused, rc untouched (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# Unknown family; a family that is not a plain word.
run_installer "$H8" "$RC8" nosuch
[ "$rc" -eq 1 ] && printf 'ok   - 8. unknown family: refused\n' || { echo "FAIL - 8. unknown family: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
run_installer "$H8" "$RC8" '../etc/passwd'
[ "$rc" -eq 1 ] && printf 'ok   - 8. a family that is not a plain lowercase word: refused\n' || { echo "FAIL - 8. a family that is not a plain lowercase word: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# Malformed profiles.
P8="$ROOT/p8"; mkdir -p "$P8"
cp "$PROFILES/glm.conf" "$P8/mismatch.conf"; sed -i.bak 's/^FAMILY=glm/FAMILY=other/' "$P8/mismatch.conf"
cp "$PROFILES/glm.conf" "$P8/badwindow.conf"; sed -i.bak 's/^WINDOW=.*/WINDOW="1e6"/' "$P8/badwindow.conf"
cp "$PROFILES/glm.conf" "$P8/norole.conf"; sed -i.bak '/^ROLE_worker=/d' "$P8/norole.conf"
cp "$PROFILES/glm.conf" "$P8/quote.conf"; sed -i.bak 's/^PICKER=.*/PICKER="glm-5.4[1m]\\"x"/' "$P8/quote.conf"
# mismatch: FAMILY names another family; badwindow: WINDOW is not a whole number; norole: no
# ROLE_worker; quote: an id that would need JSON escaping.
for f in mismatch badwindow norole quote; do
  run_installer "$H8" "$RC8" "$f" "$P8"
  [ "$rc" -eq 1 ] && printf 'ok   - 8. malformed profile (%s): refused\n' "$f" || { echo "FAIL - 8. malformed profile ($f): refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
done
[ ! -e "$H8/.claude" ] && [ ! -e "$H8/.shiploop" ] && printf 'ok   - 8. no refusal wrote a settings file or a conf\n' || { echo "FAIL - 8. a refusal wrote something"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# A copy of the tool outside a hub checkout.
T8="$ROOT/t8/tools"; mkdir -p "$T8"; cp "$INSTALLER" "$T8/launcher-setup.sh"
out="$(HOME="$H8" SHELL_RC="$RC8" bash "$T8/launcher-setup.sh" glm 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf 'ok   - 8. a tool copied outside a hub checkout: refused\n' || { echo "FAIL - 8. a tool copied outside a hub checkout: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
# An rc path that is a directory.
mkdir -p "$H8/rcdir"
out="$(HOME="$H8" SHELL_RC="$H8/rcdir" bash "$INSTALLER" glm 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf 'ok   - 8. an rc that is not a regular file: refused\n' || { echo "FAIL - 8. an rc that is not a regular file: refused (rc=$rc)"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 9. the launcher itself ──────────────────────────────────────────────────────────────────
H9="$ROOT/h9"; RC9="$H9/.zshrc"; mkdir -p "$H9"; : > "$RC9"
run_installer "$H9" "$RC9" glm
assert_eq "$rc" "0" "9. install for the launcher run"
for shell in bash zsh; do
  command -v "$shell" >/dev/null 2>&1 || { echo "info - $shell not on PATH: launcher run skipped for it"; continue; }
  launch "$H9" "$shell" --continue "two words"
  assert_eq "$rc" "1" "9. $shell: placeholders refuse to launch"
  assert_not_contains "$out" "STUB-CLAUDE" "9. $shell: placeholders: claude is not called"
  assert_contains "$out" "BASE_URL in $H9/.shiploop/launchers/glm.conf is still a placeholder" "9. $shell: the refusal names the value and the conf path"
  assert_not_contains "$out" "REPLACE_WITH_" "9. $shell: the refusal prints no conf contents"
  assert_eq "$(launch "$H9" "$shell"; grep -c 'is still a placeholder' <<<"$out")" "1" "9. $shell: one refusal names one value, not every placeholder"
done
printf 'BASE_URL="https://example.invalid/v1"\nAUTH_TOKEN="fixture-secret-0p3n"\n' > "$H9/.shiploop/launchers/glm.conf"
for shell in bash zsh; do
  command -v "$shell" >/dev/null 2>&1 || continue
  launch "$H9" "$shell" --continue "two words"
  assert_eq "$rc" "0" "9. $shell: a filled-in conf launches"
  assert_contains "$out" "STUB-CLAUDE" "9. $shell: claude is called"
  assert_contains "$out" "ARG:--settings" "9. $shell: --settings is passed"
  assert_contains "$out" "ARG:$H9/.claude/settings-glm.json" "9. $shell: the generated settings file is the one passed"
  assert_contains "$out" "ARG:--plugin-dir" "9. $shell: --plugin-dir is passed"
  assert_contains "$out" "ARG:$HUB_P" "9. $shell: --plugin-dir points at the hub checkout the installer ran from"
  assert_contains "$out" "ARG:--continue" "9. $shell: the caller's flags are passed on"
  assert_contains "$out" "ARG:two words" "9. $shell: an argument with a space arrives as one argument"
  assert_contains "$out" "ANTHROPIC_BASE_URL=https://example.invalid/v1" "9. $shell: the endpoint comes from the conf"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN=fixture-secret-0p3n" "9. $shell: the token comes from the conf"
  assert_contains "$out" "API_TIMEOUT_MS=3000000" "9. $shell: the conf's default timeout applies"
  assert_contains "$out" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000" "9. $shell: the context window export"
  assert_contains "$out" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000" "9. $shell: the auto-compact export"
  assert_contains "$out" "ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.4[1m]" "9. $shell: opus slot is ROLE_advisor"
  assert_contains "$out" "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.4[1m]" "9. $shell: sonnet slot is ROLE_investigator"
  assert_contains "$out" "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash[1m]" "9. $shell: haiku slot is ROLE_worker"
  assert_contains "$out" "SHIPLOOP_MODEL_PROFILE=glm" "9. $shell: the profile is exported"
  # Nothing leaks: after the function returns, the caller's shell has none of it.
  out="$(env -i HOME="$H9" PATH="$PATH" "$shell" -c '. "$HOME/.zshrc"; (glm --x >/dev/null 2>&1); echo "after=${ANTHROPIC_BASE_URL:-unset} ${SHIPLOOP_MODEL_PROFILE:-unset}"' 2>&1)"; rc=$?
  assert_contains "$out" "after=unset unset" "9. $shell: the exports never reach the caller's shell"
done
# A custom timeout in the conf wins over the default.
printf 'BASE_URL="https://example.invalid/v1"\nAUTH_TOKEN="fixture-secret-0p3n"\nAPI_TIMEOUT_MS="123"\n' > "$H9/.shiploop/launchers/glm.conf"
launch "$H9" bash
assert_contains "$out" "API_TIMEOUT_MS=123" "9. bash: a timeout set in the conf overrides the default"
# A missing conf refuses.
mv "$H9/.shiploop/launchers/glm.conf" "$H9/.shiploop/launchers/glm.conf.away"
launch "$H9" bash
assert_eq "$rc" "1" "9. bash: a missing conf refuses"
assert_contains "$out" "cannot read $H9/.shiploop/launchers/glm.conf" "9. bash: the refusal names the missing conf path"
mv "$H9/.shiploop/launchers/glm.conf.away" "$H9/.shiploop/launchers/glm.conf"

# ── 10. a same-named function outside the block ──────────────────────────────────────────────
H10="$ROOT/h10"; RC10="$H10/.zshrc"; mkdir -p "$H10"
printf '# rc\nglm() {\n  echo hand-written\n}\n' > "$RC10"
run_installer "$H10" "$RC10" glm
assert_eq "$rc" "0" "10. a stray definition does not block the install"
assert_contains "$out" "warning: $RC10 line 2 also defines glm()" "10. a same-named function outside the block draws one warning naming its line"
assert_eq "$(grep -c 'warning:' <<<"$out")" "1" "10. exactly one warning"
assert_contains "$(cat "$RC10")" '  echo hand-written' "10. the stray definition itself is left in place"
run_installer "$H10" "$RC10" glm
assert_eq "$(grep -c 'warning:' <<<"$out")" "1" "10. the warning repeats on a re-run, still once"
run_installer "$H1" "$RC1" glm
assert_not_contains "$out" "warning:" "10. no stray definition, no warning"
# `function glm` and leading whitespace count; a longer name does not.
printf '# rc\n  function glm () {\n}\nfunction glmx () {\n}\nglm_extra() {\n}\n' > "$RC10"
run_installer "$H10" "$RC10" glm
assert_contains "$out" "line 2 also defines glm()" '10. the zsh "function glm" spelling with leading whitespace counts'
assert_eq "$(grep -c 'warning:' <<<"$out")" "1" "10. glmx and glm_extra do not count"

# ── 11. usage ────────────────────────────────────────────────────────────────────────────────
out="$(HOME="$H1" bash "$INSTALLER" 2>&1)"; rc=$?
assert_eq "$rc" "2" "11. no arguments: exit 2 with usage"
assert_contains "$out" "usage: tools/launcher-setup.sh <family>" "11. usage names the argument"
out="$(HOME="$H1" bash "$INSTALLER" glm claude 2>&1)"; rc=$?
assert_eq "$rc" "2" "11. two families: exit 2 with usage"

assert_done
