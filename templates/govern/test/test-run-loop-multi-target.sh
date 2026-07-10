#!/usr/bin/env bash
# Ticket-SET fix + native --parallel mode. Locks two invariants:
#  1. `run-loop.sh <N> <N> <N> ...` works EVERY listed ticket (severity-ordered, deduped) — not just
#     the LAST arg. Before the fix, each numeric arg OVERWROTE a single $TARGET, so
#     `run-loop.sh 104 101 101 103 102` silently worked only #102 while reporting a normal DONE line.
#  2. `--parallel` fans a ticket set out across concurrent single-ticket child drivers and aggregates
#     one combined tally, and refuses an empty backlog pull loudly instead of silently doing nothing.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

# stub claude: resolves whatever ticket GOVERN_REPORT_PATH names, no migrations — kept deliberately
# simple (unlike test-run-loop.sh's fixture) so failures here point at ticket-SET/--parallel logic,
# not migration handling already covered elsewhere.
mk_claude_stub() { # <bindir>
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$1/claude"
}
mk_gh_stub() { # <bindir>
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$1/gh"
}

# ── 1. Ticket SET fix (sequential): every listed target resolves, severity order, dedup ──────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T"
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #101 — high one
**Severity:** High — a.
---
## #102 — high two
**Severity:** High — b.
---
## #103 — medium one
**Severity:** Medium — c.
---
## #104 — low one
**Severity:** Low — d.
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"
mk_gh_stub "$T/bin"; mk_claude_stub "$T/bin"

# Args deliberately out of severity order AND with a duplicate (101 twice) — proves both severity
# ordering within the set and dedup, on top of the core "every arg is kept" fix.
out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 104 101 101 103 102 2>&1)"

assert_contains "$out" "targets: #104 #101 #103 #102 (4)" "run-start log names the full parsed set — duplicate folded, arg order preserved"
assert_contains "$out" "resolved=4 parked=0 failed=0" "all FOUR distinct targets resolved — none silently dropped (the original bug kept only the last)"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "0" "all four ticket blocks removed from tickets.md"
commits="$(cd "$T" && git log --oneline | grep -c 'resolve #' || true)"
assert_eq "$commits" "4" "4 distinct resolve commits — #101 #102 #103 #104, not just #102 (the old last-arg-wins bug)"

# ── 2. --parallel refuses an empty eligible backlog LOUDLY instead of silently doing nothing ─────
T2="$(mktemp -d)"; trap 'rm -rf "$T" "$T2"' EXIT
mkdir -p "$T2/governor" "$T2/logs"
( cd "$T2" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T2"
printf '# Tickets\n' > "$T2/tickets.md"   # no tickets at all
printf '## Open\n\n## Resolved\n' > "$T2/governor/escalations.md"
out2="$(GOVERN_TICKETS_FILE="$T2/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T2/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T2/logs" \
  GOVERN_LOCK="$T2/lock" \
  bash "$RL" --dry-run --parallel=2 2>&1)"; rc2=$?
assert_contains "$out2" "parallel: nothing eligible" "empty backlog under --parallel is called out explicitly, never silent"
assert_eq "$rc2" "0" "an empty --parallel backlog pull is a clean no-op, not an error"

# ── 3. --parallel actually runs a target set concurrently and aggregates one combined tally ──────
T3="$(mktemp -d)"; trap 'rm -rf "$T" "$T2" "$T3"' EXIT
mkdir -p "$T3/bin" "$T3/governor" "$T3/logs" "$T3/wt"
( cd "$T3" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T3"
cat > "$T3/tickets.md" <<'EOF'
# Tickets
---
## #201 — high one
**Severity:** High — a.
---
## #202 — medium one
**Severity:** Medium — b.
---
EOF
printf '## Open\n\n## Resolved\n' > "$T3/governor/escalations.md"
cat > "$T3/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T3/wt/\$1"; echo "$T3/wt/\$1"
EOF
chmod +x "$T3/wt.sh"
mk_gh_stub "$T3/bin"; mk_claude_stub "$T3/bin"

out3="$(PATH="$T3/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T3/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T3/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T3/logs" \
  GOVERN_TICKET_SEQ_FILE="$T3/.ticket-seq" \
  GOVERN_LOCK="$T3/lock" \
  GOVERN_WORKTREE_CMD="$T3/wt.sh" \
  GOVERN_CLAUDE_BIN="$T3/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" --parallel=2 201 202 2>&1)"; rc3=$?

assert_contains "$out3" "parallel mode: 2 ticket(s)" "orchestrator announces the plan before spawning"
assert_contains "$out3" "parallel run done: processed 2/2 → resolved 2 · parked 0 · failed 0" "aggregate tally covers BOTH children in one line"
assert_eq "$rc3" "0" "a fully-resolved parallel run exits 0"
remaining3="$(grep -c '^## #' "$T3/tickets.md" || true)"
assert_eq "$remaining3" "0" "both concurrently-processed tickets removed from tickets.md — no lost update"
commits3="$(cd "$T3" && git log --oneline | grep -c 'resolve #' || true)"
assert_eq "$commits3" "2" "2 distinct resolve commits from 2 concurrent children — bookkeep lock kept it exactly-once"

assert_done
