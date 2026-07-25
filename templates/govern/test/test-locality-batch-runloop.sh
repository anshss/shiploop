#!/usr/bin/env bash
# #23 — locality batching, END-TO-END through run-loop.sh (the partitioning helpers themselves are
# unit-tested in test-locality-batch.sh). Stubbed claude/gh/worktree; dry mode, so no PR, no merge,
# no git mutation. Proves the wiring the ticket's "Done when" actually asks for:
#   A. GOVERN_BATCH_MAX unset (the default 1) → NO batching. One worker, one ticket, byte-for-byte
#      today's behavior.
#   B. GOVERN_BATCH_MAX=3 → the three same-locality tickets go to ONE worker, whose prompt carries
#      all three ticket blocks; the different-locality ticket is NOT pulled in.
#   C. Per-ticket outcomes are honored, not collapsed: the batched ticket the worker reported
#      `resolved` is bookkept; the one it reported `failed` is NOT, and stays in tickets.md.
#   D. A batched ticket ABSENT from the report's `tickets` array is likewise never bookkept
#      (fail-closed — the #23 constraint (c) hazard: bookkeeping deletes what it marks resolved).
#   E. Every batched ticket is CLAIM-LOCKED for the run and released afterwards, and a ticket a peer
#      driver already holds is left out of the group instead of being double-worked.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt" "$T/scripts/lib"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
META_NAME="testws"
ROOT_PM="npm"
GITHUB_ORG="acme"
REPOS=(alpha)
REPO_CMDS=("npm run dev")
REPO_PORTS=(3000)
SLOT_PORT_STEP=10
WORKTREE_BASE="\${WORKTREE_BASE:-$T/.wt}"
GOVERN_MERGE_REPOS=(alpha)
GOVERN_WORKER_MODEL="\${GOVERN_WORKER_MODEL:-opus}"
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF

# #1/#2/#3 share the 'govern' locality; #4 is elsewhere and must never join the group.
write_tickets() {
  cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — primary
**Severity:** High — x.

Where: scripts/govern/run-loop.sh
---
## #2 — same area, worker resolves it
**Severity:** High — y.

Where: scripts/govern/govern-bookkeep.sh
---
## #3 — same area, worker does NOT finish it
**Severity:** Medium — z.

Where: scripts/govern/select-ticket.sh
---
## #4 — different area entirely
**Severity:** Medium — w.

Where: templates/seed/CLAUDE.md
---
EOF
}
write_tickets
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'worker prompt {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'doctrine\n' > "$T/governor/preferences.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# Worker stub: dump the prompt it was handed, then emit a report whose `tickets` array deliberately
# MIXES outcomes — #2 resolved, #3 failed, and (in the D scenario) #3 omitted entirely.
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
if printf '%s' "\$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "\$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
printf '%s' "\$prompt" >> "$T/prompts.txt"
tickets='[{"ticket":1,"status":"resolved","note":"primary"},{"ticket":2,"status":"resolved","note":"same PR"},{"ticket":3,"status":"failed","note":"ran out of scope"}]'
[[ "\${GOVERN_TEST_OMIT_3:-0}" == "1" ]] && tickets='[{"ticket":1,"status":"resolved","note":"primary"},{"ticket":2,"status":"resolved","note":"same PR"}]'
pr='{"repo":"alpha","number":101,"url":"http://pr/1"}'
[[ "\${GOVERN_TEST_NO_PR:-0}" == "1" ]] && pr='null'
report="{\"status\":\"resolved\",\"pr\":\$pr,\"tickets\":\$tickets,\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

run_driver() { # extra env... -> one dry, serial, single-ticket driver; stderr on stdout
  rm -f "$T/prompts.txt"
  rm -rf "$T/logs"; mkdir -p "$T/logs"
  env GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_WORKTREE_CMD="$T/wt.sh" GOVERN_CLAUDE_BIN="$T/bin/claude" \
    GOVERN_SETTING_SOURCES=user GOVERN_WORKER_TIMEOUT=60 GOVERN_SUPERVISOR_EVERY=99 \
    GOVERN_MAX_TICKETS=1 PATH="$T/bin:$PATH" "$@" bash "$RL" --dry-run --serial 2>&1 || true
}

# ── A — default (GOVERN_BATCH_MAX unset ⇒ 1): no batching at all ───────────
logA="$(run_driver env)"
assert_contains "$logA" "=== ticket #1" "A1: the driver works #1"
if printf '%s' "$logA" | grep -q '^\[govern .*\] batch: '; then f=1; else f=0; fi
assert_eq "$f" "0" "A2: no batch is formed at the default GOVERN_BATCH_MAX=1 (today's behavior)"
promptsA="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsA" | grep -qF '## #2 — same area'; then f=1; else f=0; fi
assert_eq "$f" "0" "A3: the worker prompt carries ONLY #1's block"

# ── B — GOVERN_BATCH_MAX=3: one worker gets the whole locality group ───────
logB="$(run_driver env GOVERN_BATCH_MAX=3)"
assert_contains "$logB" "batch: #1 + #2 #3" "B1: #2 and #3 are batched with #1 (same locality)"
assert_contains "$logB" "locality 'govern'"  "B2: the group's locality key is logged"
promptsB="$(cat "$T/prompts.txt" 2>/dev/null || true)"
assert_contains "$promptsB" "## #1 — primary"     "B3: prompt carries the primary's block"
assert_contains "$promptsB" "## #2 — same area"   "B4: prompt carries batched #2's block"
assert_contains "$promptsB" "## #3 — same area"   "B5: prompt carries batched #3's block"
assert_contains "$promptsB" "LOCALITY BATCH"      "B6: the batch instructions reach the worker"
if printf '%s' "$promptsB" | grep -qF '## #4 — different area'; then f=1; else f=0; fi
assert_eq "$f" "0" "B7: the different-locality ticket #4 is NOT pulled into the group"
# One worker for the whole group — not one per ticket. The prompt template starts with the literal
# "worker prompt", and the stub appends one copy per invocation, so counting it counts workers.
spawns="$(grep -o 'worker prompt' "$T/prompts.txt" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$spawns" "1" "B8: exactly ONE worker spawned for the three-ticket group"

# ── C — per-ticket outcomes are honored, not collapsed ─────────────────────
assert_contains "$logB" "[dry] would bookkeep batched #2" "C1: the batched ticket reported resolved IS bookkept"
assert_contains "$logB" "#3 NOT resolved in batch with #1" "C2: the batched ticket reported failed is NOT"
if printf '%s' "$logB" | grep -qF 'would bookkeep batched #3'; then f=1; else f=0; fi
assert_eq "$f" "0" "C3: a non-resolved batched ticket is NEVER handed to bookkeep (it would be DELETED)"
assert_contains "$logB" "left in tickets.md" "C4: …and is explicitly left in the queue for a later run"

# ── D — a ticket MISSING from the report's tickets array is fail-closed ────
logD="$(run_driver env GOVERN_BATCH_MAX=3 GOVERN_TEST_OMIT_3=1)"
assert_contains "$logD" "[dry] would bookkeep batched #2"  "D1: the reported ticket is still bookkept"
if printf '%s' "$logD" | grep -qF 'would bookkeep batched #3'; then f=1; else f=0; fi
assert_eq "$f" "0" "D2: a ticket ABSENT from the tickets array is never bookkept (fail-closed)"
assert_contains "$logD" "#3 NOT resolved in batch with #1" "D3: …it is recorded as not-resolved and kept"

# ── D2 — a `resolved` claim with NO group PR is not honored ────────────────
# Doctrine defines resolved as "PR opened", and a batched ticket rides the primary's single group PR.
# With no PR there is nothing for the claim to point at, so the ticket must stay in the queue.
logNP="$(run_driver env GOVERN_BATCH_MAX=3 GOVERN_TEST_NO_PR=1)"
assert_contains "$logNP" "the group produced no PR" "D4: a PR-less group is detected"
if printf '%s' "$logNP" | grep -qF 'would bookkeep batched #2'; then f=1; else f=0; fi
assert_eq "$f" "0" "D5: a batched 'resolved' with no group PR is NOT bookkept"

# ── E — claim locking covers every batched ticket ──────────────────────────
# A peer driver holding #2 must leave #2 out of the group (never double-worked)…
mkdir -p "$T/governor/.locks/ticket-2"
logE="$(run_driver env GOVERN_BATCH_MAX=3)"
rmdir "$T/governor/.locks/ticket-2" 2>/dev/null || true
assert_contains "$logE" "batch: #2 already claimed by another driver" "E1: a peer-held ticket is excluded from the group"
assert_contains "$logE" "batch: #1 + #3"  "E2: …and the group forms from what remained claimable"
promptsE="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsE" | grep -qF '## #2 — same area'; then f=1; else f=0; fi
assert_eq "$f" "0" "E3: the peer-held ticket's block never reaches this driver's worker"
# …and after a clean run every batched claim is released. Glob loop rather than `ls`: an unmatched
# glob makes `ls` exit non-zero, which under `pipefail` turns the whole probe into a failure.
leftover=0
for _l in "$T/governor/.locks/ticket-"*; do if [[ -d "$_l" ]]; then leftover=$((leftover+1)); fi; done
assert_eq "$leftover" "0" "E4: every claim lock (primary AND batched) is released at the end of the run"

assert_done
