#!/usr/bin/env bash
# Locks in the `--tools` allow-list on the worker spawn — the tool-schema trim.
#
# Why it exists: measured against a REAL worker spawn (opus, CLI 2.1.220, `measure-prefix.sh`), the
# `tools` JSON block was 85,260 of 164,795 turn-1 request bytes — 51.7%, the largest single
# component, ahead of `messages` (43.7%) and the system prompt (4.3%). Restricting the set to what a
# headless one-ticket worker actually exercises took the request to 107,985 bytes (-34.5%) with the
# worker still completing normally. The cut is cache-SAFE because the tool block is static and
# deterministic: it moves the cache key exactly once, then every later worker shares the smaller
# prefix. (Rewriting anything already in the conversation would do the opposite — invalidate from
# that point and convert ~0.1x cache reads into ~1.25x writes.)
#
# The trim is OPT-IN (this repo's additive-union rule): a template bump must not silently change
# what tools an existing fleet's workers get, because losing a needed tool costs a failed ticket.
#
# Cases:
#   1. Env UNSET + a capable CLI → flag ABSENT (opt-in default off) and no warning.
#   2. GOVERN_WORKER_TOOLS=default + capable CLI → the recommended allow-list is passed.
#   3. Probe FAILS (older fake CLI) + =default → flag ABSENT, and a live spawn with that same CLI
#      still runs and its real argv carries no `--tools` (an unknown flag would kill every worker at
#      argument parsing — the fleet's CLI version is not ours).
#   4. GOVERN_WORKER_TOOLS=off → absent, no probe warning.
#   5. GOVERN_WORKER_TOOLS=<custom> → that list verbatim.
#   6. Content lock on the recommended list: the tools a worker cannot work without are present, and
#      the measured-largest unusable ones stay cut.
#   7. Live spawn with a capable CLI → `--tools <list>` really does reach the claude argv.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #401 — sample ticket
**Severity:** Medium
Observed: bare ticket, exercises the default spawn flags.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# Fake CLI whose --help advertises --tools (a modern build). Doubles as a worker stub and dumps its
# full argv so a LIVE invocation can be inspected.
mk_fake_claude() { # <path> <argv-dump> <advertise-tools:0|1>
  local path="$1" dump="$2" adv="$3"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--help" ]]; then
  printf 'Usage: claude [options]\n  --strict-mcp-config\n  --disable-slash-commands\n  --exclude-dynamic-system-prompt-sections  Move dynamic sections\n'
  [[ "$adv" == "1" ]] && printf '  --tools <tools...>                    Specify the list of available tools\n'
  exit 0
fi
printf '%s\n' "\$@" > "$dump"
report='{"status":"resolved","pr":{"repo":"alpha","number":1},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$path"
}
mk_fake_claude "$TMP/fake-claude-new.sh" "$TMP/argv-new.txt" 1
mk_fake_claude "$TMP/fake-claude-old.sh" "$TMP/argv-old.txt" 0

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Each call gets its OWN probe caches — the probe result is RUN-scoped by design, so reusing one
# path across scenarios that swap fake CLIs would read a stale verdict instead of re-probing.
run() { # <ticket> <claude_bin> <cache_tag> [GOVERN_WORKER_TOOLS]
  local n="$1" bin="$2" tag="$3"
  local base=(
    GOVERN_TICKETS_FILE="$TMP/tickets.md"
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md"
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md"
    GOVERN_LOG_ROOT="$TMP/logs-$tag"
    GOVERN_WORKER_MODEL="opus"
    GOVERN_CLAUDE_BIN="$bin"
    GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-$tag"
    GOVERN_TOOLS_PROBE_CACHE="$TMP/tools-cache-$tag"
    GOVERN_SPAWN_DRY_RUN=1
  )
  if [[ $# -ge 4 ]]; then
    env "${base[@]}" GOVERN_WORKER_TOOLS="$4" "$SPAWN" "$n"
  else
    env "${base[@]}" "$SPAWN" "$n"
  fi
}

# 1. Env UNSET on a capable CLI → absent, and no probe warning (opt-in, additive-union rule).
err1="$TMP/err1.txt"
out1u="$(run 401 "$TMP/fake-claude-new.sh" "unset-capable" 2>"$err1")"
assert_eq "$(printf '%s' "$out1u" | jq -r '.tools')" "" \
  "env unset + capable CLI → --tools absent (the trim is opt-in)"
if grep -qi "does not support" "$err1"; then
  printf 'FAIL - %s\n' "no warning expected when the trim is simply not opted into"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "no spurious warning when the trim is not opted into"
fi

# 2. GOVERN_WORKER_TOOLS=default + capable CLI → the recommended allow-list is passed.
out1="$(run 401 "$TMP/fake-claude-new.sh" "probe-ok" "default")"
tools1="$(printf '%s' "$out1" | jq -r '.tools')"
case "$tools1" in
  "--tools "*) printf 'ok   - %s\n' "=default + capable CLI → --tools <recommended list> present" ;;
  *) printf 'FAIL - %s\n       got: %s\n' "=default + capable CLI → --tools present" "$tools1"
     ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
esac

# 3. Probe FAILS (older CLI) + =default → flag absent, spawn otherwise intact.
err2="$TMP/err2.txt"
out2="$(run 401 "$TMP/fake-claude-old.sh" "probe-fail" "default" 2>"$err2")"
assert_eq "$(printf '%s' "$out2" | jq -r '.tools')" "" "probe fails → --tools absent"
assert_eq "$(printf '%s' "$out2" | jq -r '.ticket')" "401" \
  "probe fails → the rest of the dry-run observation still resolves (spawn not broken)"
if grep -qi "does not support --tools" "$err2"; then
  printf 'ok   - %s\n' "warning logged when --tools is skipped for an unsupported CLI"
else
  printf 'FAIL - %s\n       expected a warning in stderr, got: %s\n' \
    "warning logged when --tools is skipped for an unsupported CLI" "$(cat "$err2")"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 3b. Live (non-dry-run) spawn on that same old CLI — the unsupported flag must never reach argv.
out2b="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-live-old" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-old.sh" \
  GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-live-old" \
  GOVERN_TOOLS_PROBE_CACHE="$TMP/tools-cache-live-old" \
  GOVERN_WORKER_TOOLS="default" \
  "$SPAWN" 401)"
assert_eq "$(printf '%s' "$out2b" | jq -r '.status')" "resolved" \
  "live spawn with a CLI lacking --tools still completes normally"
if grep -qxF -- '--tools' "$TMP/argv-old.txt" 2>/dev/null; then
  printf 'FAIL - %s\n' "old-CLI real invocation MUST NOT carry --tools"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "old-CLI real invocation omits --tools"
fi

# 4. Kill switch: GOVERN_WORKER_TOOLS=off → absent even on a capable CLI, and no warning.
err3="$TMP/err3.txt"
out3="$(run 401 "$TMP/fake-claude-new.sh" "env-off" "off" 2>"$err3")"
assert_eq "$(printf '%s' "$out3" | jq -r '.tools')" "" \
  "GOVERN_WORKER_TOOLS=off → --tools absent (kill switch wins over a supporting CLI)"
if grep -qi "does not support" "$err3"; then
  printf 'FAIL - %s\n' "no warning expected when explicitly disabled via off"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  printf 'ok   - %s\n' "no spurious warning when explicitly disabled via off"
fi

# 5. Custom list passes through verbatim.
out4="$(run 401 "$TMP/fake-claude-new.sh" "env-custom" "Bash,Read")"
assert_eq "$(printf '%s' "$out4" | jq -r '.tools')" "--tools Bash,Read" \
  "GOVERN_WORKER_TOOLS=<custom> → that list verbatim"

# 6. Content lock on the recommended list. A worker that loses one of these fails its ticket, which
# costs far more than the prefix saved — so the keeps are asserted, not assumed. The cuts are the
# measured-largest tools a headless `-p` worker structurally cannot use.
for t in Bash Read Edit Write Glob Grep Agent WebFetch WebSearch; do
  case ",${tools1#--tools }," in
    *",$t,"*) printf 'ok   - %s\n' "recommended allow-list keeps $t" ;;
    *) printf 'FAIL - %s\n' "recommended allow-list MUST keep $t"; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  esac
done
for t in Workflow ScheduleWakeup EnterWorktree ExitWorktree CronCreate DesignSync Monitor; do
  case ",${tools1#--tools }," in
    *",$t,"*) printf 'FAIL - %s\n' "recommended allow-list MUST NOT include $t (measured dead weight)"
              ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
    *) printf 'ok   - %s\n' "recommended allow-list cuts $t" ;;
  esac
done

# 7. Live spawn on a capable CLI → --tools and its list really reach the claude argv, adjacently.
out6="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-live-new" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude-new.sh" \
  GOVERN_EDP_PROBE_CACHE="$TMP/edp-cache-live-new" \
  GOVERN_TOOLS_PROBE_CACHE="$TMP/tools-cache-live-new" \
  GOVERN_WORKER_TOOLS="Bash,Read,Agent" \
  "$SPAWN" 401)"
assert_eq "$(printf '%s' "$out6" | jq -r '.status')" "resolved" \
  "live spawn with a capable CLI completes normally with --tools set"
if awk '/^--tools$/{getline nxt; if (nxt == "Bash,Read,Agent") found=1} END{exit !found}' "$TMP/argv-new.txt"; then
  printf 'ok   - %s\n' "capable-CLI real invocation carries --tools followed by the list"
else
  printf 'FAIL - %s\n       argv: %s\n' "capable-CLI real invocation carries --tools <list>" \
    "$(tr '\n' ' ' < "$TMP/argv-new.txt")"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

assert_done
