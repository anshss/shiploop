#!/usr/bin/env bash
# Regression for ticket #122: reviewer input fidelity.
# govern-supervise.sh's ticket-bodies window is GOVERN_SUPERVISOR_BLOCKS_LINES-configurable and
# defaults to 500 (it was a hardcoded head -260 that silently truncated conflict detection past
# ~ticket 25).
# The part of this file that covered govern-improve.sh went with that script when the
# self-improvement lane was deleted in 1.19.2. govern-supervise.sh survives: it is a MANUAL audit,
# never on any dispatch path.
# The reviewer shells out to `claude` (overridable via GOVERN_CLAUDE_BIN). The mock captures the
# prompt it is handed to a file, then emits a minimal valid stream-json result event, so we can
# assert on EXACTLY what the reviewer was fed without a real model.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# A prompt-capturing fake `claude`: writes the value passed to `-p` to $CAPTURE, emits a result.
MOCK="$ROOT/claude-mock"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$prompt" > "${CAPTURE:?CAPTURE required}"
# minimal valid stream-json result the reviewers parse via: grep result | jq -r .result
printf '{"type":"result","subtype":"success","result":"- spawn-worker.sh: noted, because.\\n"}\n'
EOF
chmod +x "$MOCK"

# Isolated workspace dirs so we never touch the real governor/ or tickets.md. mk_ws_stub seeds a
# hermetic scripts/lib/workspace.sh (which common.sh sources) + exports GOVERN_WS_ROOT.
mk_ws_stub "$ROOT/ws"; mkdir -p "$GOVERN_WS_ROOT/governor"
export GOVERN_TICKETS_FILE="$ROOT/tickets.md"
export GOVERN_ESCALATIONS_FILE="$GOVERN_WS_ROOT/governor/escalations.md"
export GOVERN_CLAUDE_BIN="$MOCK"
printf '# escalations\n\n## Open\n' > "$GOVERN_ESCALATIONS_FILE"

# ── B. govern-supervise.sh: ticket-bodies window is configurable + defaults to 500 ──
# Build a backlog of 45 tickets (10 lines each ⇒ 450 lines). With the old head -260 the LAST
# tickets (#27+) are truncated; with the new default 500 the whole backlog survives.
: > "$GOVERN_TICKETS_FILE"
for n in $(seq 1 45); do
  printf '## #%s — ticket %s SENTINEL_T%s\n**Severity:** Low\n\nbody line a\nbody line b\nbody line c\n\n---\n\n' "$n" "$n" "$n" >> "$GOVERN_TICKETS_FILE"
done
cat > "$GOVERN_WS_ROOT/governor/supervisor-prompt.md" <<'EOF'
SUPERVISE. Review the backlog.
EOF
export GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_WS_ROOT/governor/supervisor-prompt.md"
RUN_S="$ROOT/run-S"; mkdir -p "$RUN_S"; printf '{"ticket":1,"status":"resolved"}\n' > "$RUN_S/state.jsonl"

# Default window (500): the last ticket #45 must be present.
CAP_S="$ROOT/cap-S"; CAPTURE="$CAP_S" bash "$DIR/../govern-supervise.sh" "$RUN_S" >/dev/null 2>&1 || true
assert_contains "$(cat "$CAP_S")" "SENTINEL_T45" "B: default window 500 covers the whole 45-ticket backlog (no silent truncation)"

# Explicit small window proves the knob is wired: #60 truncated away when capped at 30 lines.
CAP_S2="$ROOT/cap-S2"; GOVERN_SUPERVISOR_BLOCKS_LINES=30 CAPTURE="$CAP_S2" bash "$DIR/../govern-supervise.sh" "$RUN_S" >/dev/null 2>&1 || true
PROMPT_S2="$(cat "$CAP_S2")"
assert_contains "$PROMPT_S2" "SENTINEL_T1" "B: small window still includes the first ticket"
if printf '%s' "$PROMPT_S2" | grep -qF "SENTINEL_T45"; then
  printf 'FAIL - B: GOVERN_SUPERVISOR_BLOCKS_LINES=30 should truncate before #45\n'; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - B: GOVERN_SUPERVISOR_BLOCKS_LINES knob truncates as configured\n'; fi

assert_done
