#!/usr/bin/env bash
# Regression for #57: a stubbed/fake claude_bin must not be able to write worker logs under the
# REAL, unconfigured log root ($WS_ROOT/logs/govern). That combination — a hand-wired fake `claude`
# plus no GOVERN_WS_ROOT/GOVERN_LOG_ROOT override — is exactly how ~500 fixture-shaped
# worker.jsonl files ended up under the live workspace's logs/govern/.
#
# Every OTHER test in this suite redirects via mk_ws_stub (GOVERN_WS_ROOT) and/or an inline
# GOVERN_LOG_ROOT, so govern::guard_real_log_write never fires for them — this file is the one that
# deliberately does NOT set either, to exercise the fallback path the bug lived in. To do that
# safely (without ever touching this repo's own logs/govern/), it copies the govern scripts into a
# throwaway tree laid out at the SAME relative offset (scripts/govern/lib/common.sh → 3 levels up
# to the workspace root) common.sh expects, so its WS_ROOT fallback resolves to the throwaway tree,
# never the real one.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
GOVERN_SRC="$(cd "$DIR/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

# #127: be hermetic — a governor session (or a worker worktree) exports GOVERN_RUN_DIR / GOVERN_WS_ROOT
# / GOVERN_LOG_ROOT into the environment, any one of which would make the fallback path this test
# targets unreachable (the very thing under test).
while IFS='=' read -r v _; do [[ -n "$v" ]] && unset "$v"; done < <(env | sed -n 's/^\(GOVERN_[A-Za-z0-9_]*\)=.*/\1/p')

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/govern" "$TMP/wt"
cp -r "$GOVERN_SRC/lib" "$TMP/scripts/govern/lib"
cp "$GOVERN_SRC/spawn-worker.sh" "$TMP/scripts/govern/spawn-worker.sh"
cp "$GOVERN_SRC/run-loop.sh" "$TMP/scripts/govern/run-loop.sh"
SPAWN="$TMP/scripts/govern/spawn-worker.sh"
RL="$TMP/scripts/govern/run-loop.sh"

# mk_ws_stub writes scripts/lib/workspace.sh AND exports GOVERN_WS_ROOT — undo the export right
# after so the fallback in common.sh (GOVERN_LIB_DIR/../../..) is what actually resolves WS_ROOT,
# same as an unconfigured ad-hoc repro would see. The workspace.sh FILE staying in place is exactly
# what a real workspace looks like: present, just not pointed at via the env override.
mk_ws_stub "$TMP"
unset GOVERN_WS_ROOT GOVERN_EXTERNALIZE_LANE _GOVERN_ASSUME_MERGE_ALLOWED

cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
mkdir -p "$TMP/governor"
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# A fixture-shaped stub: answers -p with a canned report, but its --help gives no hint it's the
# real CLI — exactly the kind of ad-hoc script a manual repro wires onto GOVERN_CLAUDE_BIN/PATH.
cat > "$TMP/fake-claude-stub.sh" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2; continue;;
    --help) printf 'usage: fake-claude-stub [args]\n'; exit 0;;
    *) shift;;
  esac
done
report='{"status":"resolved","pr":{"repo":"alpha","number":57,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-stub.sh"

# A fake that DOES look like the real CLI: its --help banner echoes the real CLI's own self-naming
# line ("Claude Code - starts an interactive session..."), which govern::claude_bin_is_real keys on.
cat > "$TMP/fake-claude-real.sh" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2; continue;;
    --help)
      printf 'Usage: claude [options] [command] [prompt]\n\nClaude Code - starts an interactive session by default, use -p/--print for non-interactive output\n'
      exit 0;;
    *) shift;;
  esac
done
report='{"status":"resolved","pr":{"repo":"alpha","number":58,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-real.sh"

run_spawn() { # extra-env...
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
    GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
    GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
    "$@" bash "$SPAWN" 7
}

exists() { [[ -e "$1" ]] && echo yes || echo no; }

# ── 1. stub claude_bin, no override, no opt-in → refused; nothing lands in the real tree ─────────
out1="$(run_spawn GOVERN_CLAUDE_BIN="$TMP/fake-claude-stub.sh" 2>&1)" && rc1=0 || rc1=$?
assert_eq "$rc1" "1" "stub claude_bin + no override + no opt-in: spawn-worker refuses (nonzero exit)"
assert_contains "$out1" "GOVERN_ALLOW_REAL_LOG_WRITE" "refusal names the opt-in escape hatch"
assert_eq "$(exists "$TMP/logs/govern/ticket-7/worker.jsonl")" no "refused: no worker.jsonl written under the real tree"
rm -f "$TMP/governor/.claude-real-bin"

# ── 2. same stub, WITH the opt-in → proceeds normally ─────────────────────────────────────────────
out2="$(run_spawn GOVERN_CLAUDE_BIN="$TMP/fake-claude-stub.sh" GOVERN_ALLOW_REAL_LOG_WRITE=1 2>/dev/null)"
assert_contains "$out2" '"status":"resolved"' "stub claude_bin + GOVERN_ALLOW_REAL_LOG_WRITE=1: opt-in proceeds"
assert_eq "$(exists "$TMP/logs/govern/ticket-7/worker.jsonl")" yes "opt-in: worker.jsonl written this time"
rm -rf "$TMP/logs" "$TMP/governor/.claude-real-bin"

# ── 3. a REAL-looking claude_bin, no override, NO opt-in → never blocked (must not misfire) ──────
out3="$(run_spawn GOVERN_CLAUDE_BIN="$TMP/fake-claude-real.sh" 2>/dev/null)"
assert_contains "$out3" '"status":"resolved"' "real-looking claude_bin: never blocked even with no override/opt-in"
assert_eq "$(exists "$TMP/logs/govern/ticket-7/worker.jsonl")" yes "real-looking claude_bin: worker.jsonl written under the real tree, as production does"
rm -rf "$TMP/logs" "$TMP/governor/.claude-real-bin"

# ── 4. run-loop.sh carries the SAME guard, before it ever creates a run directory ─────────────────
out4="$(env GOVERN_CLAUDE_BIN="$TMP/fake-claude-stub.sh" bash "$RL" --serial 7 2>&1)" && rc4=0 || rc4=$?
assert_eq "$rc4" "1" "run-loop.sh: stub claude_bin + no override refuses before dispatch"
assert_contains "$out4" "GOVERN_ALLOW_REAL_LOG_WRITE" "run-loop.sh refusal names the same opt-in"
assert_eq "$(exists "$TMP/logs/govern")" no "run-loop.sh: no run-* directory created under the real tree"

assert_done
