#!/usr/bin/env bash
# The per-test sandbox: sourcing assert.sh installs a private HOME (holding the
# canary dotfile), a private TMPDIR and hermetic git config BEFORE the test body
# runs, and assert_done verifies them after. A fixture reading the canary sees
# the sandbox's copy; a fixture writing the escape marker outside its sandbox is
# caught naming the escape; the opt-outs restore host paths; and ambient
# GOVERN_* residue beyond the suite defaults is unset at source.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"

# ── armed: the environment this test sees is the sandbox's ───────────────────
assert_contains "$HOME" "$GOVERN_SANDBOX_ROOT/home" "sandbox HOME is the private HOME inside the sandbox root"
assert_contains "$(cat "$HOME/.govern-sandbox-canary")" "$GOVERN_SANDBOX_ROOT" \
  "the canary dotfile carries the sandbox token"
assert_contains "$TMP" "$GOVERN_SANDBOX_ROOT/tmp" "mktemp lands inside the private TMPDIR"
bare_tmp="$(mktemp -d)"
assert_contains "$bare_tmp" "$GOVERN_SANDBOX_ROOT/tmp" "a bare mktemp -d lands inside the private TMPDIR (BSD mktemp ignores TMPDIR, so it is shimmed)"
rm -rf "$bare_tmp"
# A template'd call keeps the caller's template: the shim must not drop it, or the
# files land in the host's shared temp dir under a generic name and any mechanism
# (or test) matching on the template's distinctive prefix silently loses that path.
tpl_tmp="$(mktemp -d "${TMPDIR}/govern-sandbox-shim-probe.XXXXXX")"
assert_contains "$tpl_tmp" "$GOVERN_SANDBOX_ROOT/tmp" "a template'd mktemp -d lands inside the private TMPDIR"
assert_contains "$tpl_tmp" "govern-sandbox-shim-probe." "a template'd mktemp -d keeps the caller's template verbatim"
rm -rf "$tpl_tmp"
assert_eq "${GIT_CONFIG_GLOBAL:-}" "$GOVERN_SANDBOX_ROOT/home/.gitconfig" "global git config is pointed inside the sandbox"
assert_eq "${GIT_CONFIG_NOSYSTEM:-}" "1" "system git config is disabled"
child_home="$(bash -c 'printf %s "$HOME"')"
assert_eq "$child_home" "$HOME" "a spawned fixture inherits the sandbox HOME, not the host's"

# ── ambient knob sweep: source-time, pinned names keep suite defaults ────────
sweep_child="$TMP/sweep-child.sh"
cat > "$sweep_child" <<'EOF'
set -euo pipefail
source "$1/assert.sh"
printf 'knob=[%s] scout=[%s]' "${GOVERN_TEST_AMBIENT_KNOB-UNSET}" "${GOVERN_SCOUT-UNSET}"
EOF
sweep_out="$(env GOVERN_TEST_AMBIENT_KNOB=loose GOVERN_SCOUT=9 bash "$sweep_child" "$DIR" 2>&1)"
assert_contains "$sweep_out" "knob=[UNSET]" "an ambient GOVERN_* knob beyond the suite defaults is unset at source"
assert_contains "$sweep_out" "scout=[0]" "a pinned knob keeps the suite default, not the ambient value"

# ── escape detection: a write outside the sandbox fails, naming the escape ───
set +e
govern_sandbox_verify > "$TMP/verify-clean.out" 2>&1
vrc=$?
set -e
assert_eq "$vrc" "0" "verification passes on a clean sandbox"

hostsim="$TMP/host-home-sim"
mkdir -p "$hostsim"
saved_real_home="$GOVERN_SANDBOX_REAL_HOME"
GOVERN_SANDBOX_REAL_HOME="$hostsim"
printf 'x' > "$hostsim/govern-sandbox-escape-probe"
set +e
govern_sandbox_verify > "$TMP/verify-escape.out" 2>&1
vrc=$?
set -e
assert_eq "$vrc" "1" "verification fails when a fixture wrote the escape marker outside its sandbox"
assert_contains "$(cat "$TMP/verify-escape.out")" "$hostsim/govern-sandbox-escape-probe" "the failure names the escaped path"
GOVERN_SANDBOX_REAL_HOME="$saved_real_home"

# ── canary clobber: a rewritten or deleted canary fails verification ─────────
clobber_child="$TMP/clobber-child.sh"
cat > "$clobber_child" <<'EOF'
set -euo pipefail
source "$1/assert.sh"
rm -f "$HOME/.govern-sandbox-canary"
govern_sandbox_verify
EOF
set +e
clob="$(bash "$clobber_child" "$DIR" 2>&1)"
vrc=$?
set -e
assert_eq "$vrc" "1" "a deleted canary fails verification"
assert_contains "$clob" "canary missing or rewritten" "the canary failure names the canary file"

# ── opt-outs restore host behavior ───────────────────────────────────────────
mkdir -p "$TMP/fake-host-home-a" "$TMP/fake-host-home-b"
off_child="$TMP/off-child.sh"
cat > "$off_child" <<'EOF'
set -euo pipefail
source "$1/assert.sh"
govern_sandbox_off  # reason: this fixture pretends to need the host
printf '%s' "$HOME"
EOF
off_out="$(HOME="$TMP/fake-host-home-a" bash "$off_child" "$DIR")"
assert_eq "$off_out" "$TMP/fake-host-home-a" "govern_sandbox_off restores the host HOME"

preoff_child="$TMP/preoff-child.sh"
cat > "$preoff_child" <<'EOF'
set -euo pipefail
source "$1/assert.sh"
printf 'root=[%s] home=[%s]' "${GOVERN_SANDBOX_ROOT-}" "$HOME"
EOF
pre_out="$(HOME="$TMP/fake-host-home-b" GOVERN_SANDBOX=0 bash "$preoff_child" "$DIR")"
assert_contains "$pre_out" "root=[]" "GOVERN_SANDBOX=0 in the environment skips arming entirely"
assert_contains "$pre_out" "home=[$TMP/fake-host-home-b]" "a skipped sandbox leaves the host HOME untouched"

assert_done
