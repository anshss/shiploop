#!/usr/bin/env bash
# Leak A regression: a ticket resolved via the RESUME-ADOPTION path ("found existing PR — resuming,
# no new worker") must still tear down its worktree. The old teardown gate was
#   [[ "$MODE" == "live" && -z "${GOVERN_WORKTREE_CMD:-}" && -z "$resumed" ]]
# so any resumed-and-resolved ticket SKIPPED the worktree teardown → its worktree (and, per Leak B,
# the dev stack booted inside it) leaked permanently. A resumed ticket is bookkept + recorded
# resolved identically to a fresh one, and worktree:rm --force is a no-op if the dir is already gone —
# so the `-z "$resumed"` clause was simply wrong. This test drives the resume path (gh reports an open
# ticket-1 PR → find_pr adopts it, no worker spawned) with GOVERN_WORKTREE_CMD UNSET (so the REAL
# teardown runs) + a stubbed worktree/rm.sh, and asserts the teardown fired for the resumed ticket.
#
# NB: the template run-loop tears down via a DIRECT `bash "$WS_ROOT/scripts/worktree/rm.sh" ...`
# (pnpm v11's pre-run gate aborts in a non-TTY shell, so it never goes through `<pm> run`). So the
# stub here is scripts/worktree/rm.sh under the stubbed workspace root, not an `npm` shim.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/marks" "$T/scripts/worktree"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — resumed one
**Severity:** High — x.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"

# stub gh: `pr list` reports an OPEN PR whose head is `ticket-1` → govern::find_pr adopts it (resume
# path, no worker spawned). Everything else (checks / view / merge) → benign pass.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[{"number":101,"url":"http://pr/1","headRefName":"ticket-1"}]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# stub the DIRECT worktree teardown: record every rm.sh invocation. The teardown does
# `( cd "$WS_ROOT" && bash "$WS_ROOT/scripts/worktree/rm.sh" "ticket-$N" --force )`, so this marker
# file is written ONLY if the resumed-resolved ticket reached the teardown (the thing the fix restores).
cat > "$T/scripts/worktree/rm.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/marks/rm.log"
exit 0
EOF
chmod +x "$T/scripts/worktree/rm.sh"

# stub claude: only the supervisor may be invoked (the worker is NOT spawned on the resume path).
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
# A worker was spawned — it should NOT be on the resume path. Emit a marker so the test can catch it.
touch "$GOVERN_LOG_ROOT/../marks/worker-spawned" 2>/dev/null || true
printf '{"type":"result","result":%s}\n' "$(printf '{"status":"failed"}' | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

# NB: GOVERN_WORKTREE_CMD is intentionally LEFT UNSET so the real teardown path (the direct
# scripts/worktree/rm.sh) runs; every other govern test sets it, which is exactly why the leak went
# unnoticed.
out="$(PATH="$T/bin:$PATH" \
  ROOT_PM=npm \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 \
  bash "$RL" 1 2>&1)"

assert_contains "$out" "found existing PR"  "resume-adoption path taken (existing ticket-1 PR found, no new worker)"
sw=no; [ -f "$T/marks/worker-spawned" ] && sw=yes
assert_eq "$sw" "no" "no worker spawned on the resume path (adopted the existing PR)"
assert_contains "$out" "resolved=1" "the resumed ticket #1 resolved"

# The load-bearing assertion: teardown fired for the RESUMED-resolved ticket (was skipped by the
# old `-z "$resumed"` gate → the Leak A worktree leak).
rmlog="$(cat "$T/marks/rm.log" 2>/dev/null || true)"
assert_contains "$rmlog" "ticket-1 --force" "resumed-resolved ticket triggers worktree:rm teardown (Leak A fixed)"

assert_done
