#!/usr/bin/env bash
# Locks in `--exclude-dynamic-system-prompt-sections` on the worker spawn (moves per-machine
# system-prompt sections — cwd, env info, memory paths, git status — into the first user message,
# improving cross-worker prompt-cache reuse since this spawn never passes --system-prompt /
# --append-system-prompt) AND its capability gate: this file ships to every fleet as a hub template
# via /shiploop:update, and the flag is NEW (present in 2.1.220+, absent on older CLI builds) — an
# unconditional flag would make `claude -p` fail at argument parsing on any fleet still on an older
# CLI, killing every worker before its first turn. So the flag is only ever added after a `--help`
# probe (govern::claude_supports_exclude_dynamic_prompt) confirms the running CLI supports it:
#   1. Probe succeeds (fake CLI whose --help lists the flag) + env unset → flag present.
#   2. Probe FAILS (fake CLI whose --help lacks the flag) → flag ABSENT, and the spawn still
#      constructs + runs correctly (a live, non-dry-run spawn with the SAME fake CLI proves the
#      omitted flag never reaches the real argv either).
#   3. Probe fails + GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 (explicit "on") → still absent, PLUS a warning
#      line logged explaining the CLI is too old for this optimization.
#   4. GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag absent unconditionally (no probe even attempted).
#   5. `--forward-subagent-text` (forwards subagent text+thinking into the parent — the OPPOSITE of
#      the token-efficiency goal) must never appear in spawn-worker.sh, regression-locked by source
#      scan.
#
# Cases 1/3/4 use GOVERN_SPAWN_DRY_RUN=1 to short-circuit BEFORE worktree creation / worker launch —
# pure observation of the assembled invocation params (the probe itself still shells out to the fake
# CLI's --help, which is free — no auth, no cost). Case 2's second half runs the REAL (non-dry-run)
# spawn path with a fully-stubbed worktree + claude binary, exactly like test-spawn-worker.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #301 — sample ticket
**Severity:** Medium
Observed: bare ticket, exercises the default spawn flags.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Fake CLI #1: --help ADVERTISES the flag (simulates a modern claude-code build). Also doubles as a
# normal worker stub (like test-spawn-worker.sh's fake-claude.sh) and dumps its full argv so a LIVE
# invocation can be inspected too.
cat > "$TMP/fake-claude-new.sh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--help" ]]; then
  printf 'Usage: claude [options]\n  --strict-mcp-config\n  --disable-slash-commands\n  --exclude-dynamic-system-prompt-sections  Move dynamic sections into the first user message\n'
  exit 0
fi
printf '%s\n' "\$@" > "$TMP/argv-new.txt"
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
report='{"status":"resolved","pr":{"repo":"alpha","number":1},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-new.sh"

# Fake CLI #2: --help does NOT mention the flag (simulates an older claude-code build pre-dating it).
cat > "$TMP/fake-claude-old.sh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--help" ]]; then
  printf 'Usage: claude [options]\n  --strict-mcp-config\n  --disable-slash-commands\n'
  exit 0
fi
printf '%s\n' "\$@" > "$TMP/argv-old.txt"
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
report='{"status":"resolved","pr":{"repo":"alpha","number":2},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-old.sh"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# run <ticket> <claude_bin> <edp_cache_tag> [GOVERN_EXCLUDE_DYNAMIC_PROMPT]
# Each call gets its OWN GOVERN_EDP_PROBE_CACHE — the probe result is cached RUN-scoped (by design,
# see common.sh), so reusing one cache path across scenarios that swap fake CLIs would read a stale
# verdict from an earlier scenario instead of re-probing.
run() {
  local n="$1" bin="$2" tag="$3" edp="${4:-}"
  local base=(
    GOVERN_TICKETS_FILE="$TMP/tickets.md"
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md"
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md"
    GOVERN_LOG_ROOT="$TMP/logs-$tag"
    GOVERN_WORKER_MODEL="opus"
    GOVERN_CLAUDE_BIN="$bin"
    GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-$tag"
    GOVERN_SPAWN_DRY_RUN=1
  )
  if [[ -n "$edp" ]]; then
    env "${base[@]}" GOVERN_EXCLUDE_DYNAMIC_PROMPT="$edp" "$SPAWN" "$n"
  else
    env "${base[@]}" "$SPAWN" "$n"
  fi
}

# 1. Probe succeeds (modern fake CLI) + env unset → flag present.
out1="$(run 301 "$TMP/fake-claude-new.sh" "probe-ok")"
assert_eq "$(printf '%s' "$out1" | jq -r '.exclude_dynamic_prompt')" \
  "--exclude-dynamic-system-prompt-sections" \
  "probe succeeds, env unset → --exclude-dynamic-system-prompt-sections present"

# 2. Probe FAILS (older fake CLI, no advertised flag) + env unset → flag absent, no fatal.
out2="$(run 301 "$TMP/fake-claude-old.sh" "probe-fail")"
assert_eq "$(printf '%s' "$out2" | jq -r '.exclude_dynamic_prompt')" "" \
  "probe fails, env unset → flag absent"
assert_eq "$(printf '%s' "$out2" | jq -r '.ticket')" "301" \
  "probe fails → the rest of the dry-run observation still resolves correctly (spawn not broken)"

# 2b. Same old-CLI stub, but the REAL (non-dry-run, non-GOVERN_SPAWN_DRY_RUN) spawn path — proves
# the omitted flag never reaches the actual claude argv, and the worker still runs to a normal
# resolved report end-to-end.
out2b="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-live-old" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-old.sh" \
  GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-live-old" \
  "$SPAWN" 301)"
assert_eq "$(printf '%s' "$out2b" | jq -r '.status')" "resolved" \
  "live spawn with an old (flag-unsupporting) CLI still completes normally"
[[ -f "$TMP/argv-old.txt" ]] || { printf 'FAIL - %s\n' "old-CLI argv capture file missing"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
if grep -qF -- '--exclude-dynamic-system-prompt-sections' "$TMP/argv-old.txt" 2>/dev/null; then
  printf 'FAIL - %s\n' "old-CLI real invocation MUST NOT carry the unsupported flag"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "old-CLI real invocation omits the unsupported flag"
fi

# 3. Probe fails + GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 (explicit "on") → still absent, AND a warning is
# logged (govern::log writes to stderr; the dry-run JSON stays clean on stdout).
err3="$TMP/err3.txt"
out3="$(run 301 "$TMP/fake-claude-old.sh" "probe-fail-explicit-on" "1" 2>"$err3")"
assert_eq "$(printf '%s' "$out3" | jq -r '.exclude_dynamic_prompt')" "" \
  "probe fails + GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 → still absent"
if grep -qi "does not support --exclude-dynamic-system-prompt-sections" "$err3"; then
  printf 'ok   - %s\n' "warning logged when the flag is skipped for an unsupported CLI"
else
  printf 'FAIL - %s\n       expected a warning line in stderr, got: %s\n' \
    "warning logged when the flag is skipped for an unsupported CLI" "$(cat "$err3")"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 4. GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag absent unconditionally, regardless of CLI support (and
# no probe/warning — the modern fake CLI proves this isn't just "probe happened to fail").
err4="$TMP/err4.txt"
out4="$(run 301 "$TMP/fake-claude-new.sh" "env-off" "0" 2>"$err4")"
assert_eq "$(printf '%s' "$out4" | jq -r '.exclude_dynamic_prompt')" "" \
  "GOVERN_EXCLUDE_DYNAMIC_PROMPT=0 → flag absent (kill switch wins over a supporting CLI)"
# Scoped to THIS flag's message. A bare "does not support" also matches the sibling `--tools`
# probe's warning, which the fake modern CLI here does advertise but other fixtures may not —
# an unscoped grep makes this assertion fail for a reason that has nothing to do with EDP.
if grep -qi "does not support --exclude-dynamic-system-prompt-sections" "$err4"; then
  printf 'FAIL - %s\n' "no warning expected when explicitly disabled via env=0"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "no spurious warning when explicitly disabled via env=0"
fi

# 5. GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 (explicit "on") + a CAPABLE CLI → same as default.
out5="$(run 301 "$TMP/fake-claude-new.sh" "env-on" "1")"
assert_eq "$(printf '%s' "$out5" | jq -r '.exclude_dynamic_prompt')" \
  "--exclude-dynamic-system-prompt-sections" \
  "GOVERN_EXCLUDE_DYNAMIC_PROMPT=1 + capable CLI → flag present"

# 6. Regression lock: --forward-subagent-text (forwards subagent text+thinking into the parent —
# the opposite of the token-efficiency goal) must never be introduced into the spawn script.
if grep -qF -- '--forward-subagent-text' "$SPAWN"; then
  printf 'FAIL - %s\n' "--forward-subagent-text must never appear in spawn-worker.sh"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "--forward-subagent-text absent from spawn-worker.sh"
fi

# 7. A `claude` wrapper/shim that HANGS on --help must NOT hang the spawn. Before this fix the probe
# ran `"$bin" --help` unbounded and synchronously, BEFORE the real worker's $cpid is assigned and its
# own kill traps armed — spawn-worker's teardown could never reach a hung probe. Use a short
# GOVERN_EDP_PROBE_TIMEOUT_S so the test stays fast; assert the dry-run still completes well under
# the fake CLI's hang duration, treats the timeout as "unsupported" (never risk passing an
# unrecognized flag when we couldn't confirm support), and logs a DISTINCT "TIMED OUT" warning
# (not the normal "does not support" negative-result message).
cat > "$TMP/fake-claude-hang.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--help" ]]; then
  exec sleep 300   # never returns within any sane probe bound
fi
printf 'Usage: claude [options]\n'
EOF
chmod +x "$TMP/fake-claude-hang.sh"

err7="$TMP/err7.txt"
start7=$(date +%s)
out7="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-hang" \
  GOVERN_WORKER_MODEL="opus" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-hang.sh" \
  GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-hang" \
  GOVERN_EDP_PROBE_TIMEOUT_S=2 \
  GOVERN_SPAWN_DRY_RUN=1 \
  "$SPAWN" 301 2>"$err7")"
end7=$(date +%s)
elapsed7=$((end7-start7))
# Best-effort reap of the killed probe's `sleep 300` (timeout/gtimeout should already have killed
# it; this is a belt-and-suspenders sweep scoped to this test's unique TMP path).
pkill -f "$TMP/fake-claude-hang.sh" 2>/dev/null || true

if [[ "$elapsed7" -lt 15 ]]; then
  printf 'ok   - hanging --help probe does NOT hang the spawn (bounded, %ss elapsed)\n' "$elapsed7"
else
  printf 'FAIL - %s\n       spawn took %ss — hanging --help probe was not bounded\n' \
    "hanging --help probe does NOT hang the spawn" "$elapsed7"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
assert_eq "$(printf '%s' "$out7" | jq -r '.exclude_dynamic_prompt')" "" \
  "hanging probe → treated as unsupported (never risk an unrecognized flag)"
if grep -qi "TIMED OUT" "$err7"; then
  printf 'ok   - %s\n' "a distinct TIMED OUT warning is logged (not the normal unsupported message)"
else
  printf 'FAIL - %s\n       expected a TIMED OUT warning in stderr, got: %s\n' \
    "a distinct TIMED OUT warning is logged" "$(cat "$err7" 2>/dev/null)"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 8. Unit test of the manual-timeout fallback itself (govern::_run_with_manual_timeout), exercised
# directly regardless of whether `timeout`/`gtimeout` happen to be on THIS machine's PATH — stock
# macOS ships neither, and the fallback must be independently correct, not just "never hit in CI".
T8="$(mktemp -d)"; mk_ws_stub "$T8"; source "$DIR/../lib/common.sh"
start8=$(date +%s)
out8="$(govern::_run_with_manual_timeout 1 sleep 30 2>&1)" && rc8=0 || rc8=$?
end8=$(date +%s)
elapsed8=$((end8-start8))
assert_eq "$rc8" "124" "manual-timeout fallback: expired command reports rc=124 (mirrors GNU timeout)"
if [[ "$elapsed8" -lt 10 ]]; then
  printf 'ok   - %s\n' "manual-timeout fallback: expiry is bounded (~1s bound, ${elapsed8}s elapsed), not left hanging"
else
  printf 'FAIL - %s\n       took %ss\n' "manual-timeout fallback: expiry is bounded" "$elapsed8"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
out8b="$(govern::_run_with_manual_timeout 5 printf 'hello-world')"
assert_eq "$out8b" "hello-world" "manual-timeout fallback: a command that finishes in time returns its real output"
rm -rf "$T8"

assert_done
