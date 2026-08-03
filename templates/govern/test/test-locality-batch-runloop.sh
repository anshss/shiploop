#!/usr/bin/env bash
# #23 — locality batching, END-TO-END through run-loop.sh (the partitioning helpers themselves are
# unit-tested in test-locality-batch.sh). Stubbed claude/gh/worktree; dry mode, so no PR, no merge,
# no git mutation. Proves the wiring the ticket's "Done when" actually asks for.
#
# The batching KEY is now MEASURED file overlap (govern::ticket_paths / govern::paths_overlap), not
# leaf-directory prose parsing — govern::ticket_locality is gone. A candidate joins a group only if it
# shares a real file with the group's SEED ticket, sourced from an explicit `**Files:**` list (or the
# scout's verified targetPaths — not exercised here). No measurement means no batch: prose `Where:`
# lines are deliberately NOT a source any more. GOVERN_BATCH_MAX's default also changed from 1 to 2.
#   A. GOVERN_BATCH_MAX=1 (explicit) → NO batching. One worker, one ticket, byte-for-byte the
#      pre-#23 behavior — this is the override an operator reaches for to turn batching off.
#   B. GOVERN_BATCH_MAX unset (the new default, 2) → batching is ON by default, capped at two: #1
#      picks up exactly ONE same-file peer (#2), #3 (which only overlaps via a DIFFERENT shared file)
#      is left out once the cap is hit, and #4 (no overlap at all) is never a candidate.
#   C. GOVERN_BATCH_MAX=3 → all three file-sharing tickets go to ONE worker, whose prompt carries
#      all three ticket blocks; the different-file ticket is NOT pulled in.
#   D. Per-ticket outcomes are honored, not collapsed: the batched ticket the worker reported
#      `resolved` is bookkept; the one it reported `failed` is NOT, and stays in tickets.md.
#   E. A batched ticket ABSENT from the report's `tickets` array is likewise never bookkept
#      (fail-closed — the #23 constraint (c) hazard: bookkeeping deletes what it marks resolved).
#   F. A batched `resolved` claim with NO group PR is not honored (fail-closed).
#   G. Every batched ticket is CLAIM-LOCKED for the run and released afterwards, and a ticket a peer
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

# #1/#2/#3 are MEASURED (via **Files:**) to share real paths with #1: #2 shares
# scripts/govern/lib/common.sh with #1, #3 shares scripts/govern/run-loop.sh with #1. #2 and #3 do
# NOT share a file with each other — batching keys off the SEED (#1), never off the group's running
# union — so both still join #1's group once the cap allows it. #4 shares nothing with anyone and
# must never join.
write_tickets() {
  cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — primary
**Severity:** High — x.

**Files:** scripts/govern/run-loop.sh scripts/govern/lib/common.sh
---
## #2 — same area, worker resolves it
**Severity:** High — y.

**Files:** scripts/govern/lib/common.sh scripts/govern/govern-bookkeep.sh
---
## #3 — same area, worker does NOT finish it
**Severity:** Medium — z.

**Files:** scripts/govern/run-loop.sh scripts/govern/select-ticket.sh
---
## #4 — different area entirely
**Severity:** Medium — w.

**Files:** templates/seed/CLAUDE.md
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
# MIXES outcomes — #2 resolved, #3 failed, and (in the E scenario) #3 omitted entirely.
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

# ── A — GOVERN_BATCH_MAX=1 (explicit): no batching at all ──────────────────
logA="$(run_driver env GOVERN_BATCH_MAX=1)"
assert_contains "$logA" "=== ticket #1" "A1: the driver works #1"
if printf '%s' "$logA" | grep -q '^\[govern .*\] batch: '; then f=1; else f=0; fi
assert_eq "$f" "0" "A2: GOVERN_BATCH_MAX=1 forms no batch (pre-#23 behavior, reached via explicit override)"
promptsA="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsA" | grep -qF '## #2 — same area'; then f=1; else f=0; fi
assert_eq "$f" "0" "A3: the worker prompt carries ONLY #1's block"

# ── B — GOVERN_BATCH_MAX unset: the new default (2) batches, capped at two ─
logB="$(run_driver env)"
assert_contains "$logB" "batch: #1 + #2" "B1: #2 (shares lib/common.sh with the seed #1) is batched by default"
assert_contains "$logB" "(GOVERN_BATCH_MAX=2)" "B2: the default resolves to 2, not the old 1"
if printf '%s' "$logB" | grep -qF 'batch: #1 + #2 #3'; then f=1; else f=0; fi
assert_eq "$f" "0" "B3: #3 is NOT pulled in — the default cap (2) is already full with #1+#2"
promptsB0="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsB0" | grep -qF '## #3 — same area'; then f=1; else f=0; fi
assert_eq "$f" "0" "B4: …and #3's block never reaches the worker prompt at the default cap"

# ── C — GOVERN_BATCH_MAX=3: one worker gets the whole file-sharing group ───
logC="$(run_driver env GOVERN_BATCH_MAX=3)"
assert_contains "$logC" "batch: #1 + #2 #3" "C1: #2 and #3 are batched with #1 (both share a file with the seed)"
promptsC="$(cat "$T/prompts.txt" 2>/dev/null || true)"
assert_contains "$promptsC" "## #1 — primary"     "C2: prompt carries the primary's block"
assert_contains "$promptsC" "## #2 — same area"   "C3: prompt carries batched #2's block"
assert_contains "$promptsC" "## #3 — same area"   "C4: prompt carries batched #3's block"
assert_contains "$promptsC" "LOCALITY BATCH"      "C5: the batch instructions reach the worker"
if printf '%s' "$promptsC" | grep -qF '## #4 — different area'; then f=1; else f=0; fi
assert_eq "$f" "0" "C6: the file-disjoint ticket #4 is NOT pulled into the group"
# One worker for the whole group — not one per ticket. The prompt template starts with the literal
# "worker prompt", and the stub appends one copy per invocation, so counting it counts workers.
spawns="$(grep -o 'worker prompt' "$T/prompts.txt" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$spawns" "1" "C7: exactly ONE worker spawned for the three-ticket group"

# ── D — per-ticket outcomes are honored, not collapsed ─────────────────────
assert_contains "$logC" "[dry] would bookkeep batched #2" "D1: the batched ticket reported resolved IS bookkept"
assert_contains "$logC" "#3 NOT resolved in batch with #1" "D2: the batched ticket reported failed is NOT"
if printf '%s' "$logC" | grep -qF 'would bookkeep batched #3'; then f=1; else f=0; fi
assert_eq "$f" "0" "D3: a non-resolved batched ticket is NEVER handed to bookkeep (it would be DELETED)"
assert_contains "$logC" "left in tickets.md" "D4: …and is explicitly left in the queue for a later run"

# ── E — a ticket MISSING from the report's tickets array is fail-closed ────
logE="$(run_driver env GOVERN_BATCH_MAX=3 GOVERN_TEST_OMIT_3=1)"
assert_contains "$logE" "[dry] would bookkeep batched #2"  "E1: the reported ticket is still bookkept"
if printf '%s' "$logE" | grep -qF 'would bookkeep batched #3'; then f=1; else f=0; fi
assert_eq "$f" "0" "E2: a ticket ABSENT from the tickets array is never bookkept (fail-closed)"
assert_contains "$logE" "#3 NOT resolved in batch with #1" "E3: …it is recorded as not-resolved and kept"

# ── F — a `resolved` claim with NO group PR is not honored ─────────────────
# Doctrine defines resolved as "PR opened", and a batched ticket rides the primary's single group PR.
# With no PR there is nothing for the claim to point at, so the ticket must stay in the queue.
logNP="$(run_driver env GOVERN_BATCH_MAX=3 GOVERN_TEST_NO_PR=1)"
assert_contains "$logNP" "the group produced no PR" "F1: a PR-less group is detected"
if printf '%s' "$logNP" | grep -qF 'would bookkeep batched #2'; then f=1; else f=0; fi
assert_eq "$f" "0" "F2: a batched 'resolved' with no group PR is NOT bookkept"

# ── G — claim locking covers every batched ticket ───────────────────────────
# A peer driver holding #2 must leave #2 out of the group (never double-worked)…
mkdir -p "$T/governor/.locks/ticket-2"
logG="$(run_driver env GOVERN_BATCH_MAX=3)"
rmdir "$T/governor/.locks/ticket-2" 2>/dev/null || true
assert_contains "$logG" "batch: #2 already claimed by another driver" "G1: a peer-held ticket is excluded from the group"
assert_contains "$logG" "batch: #1 + #3"  "G2: …and the group forms from what remained claimable"
promptsG="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsG" | grep -qF '## #2 — same area'; then f=1; else f=0; fi
assert_eq "$f" "0" "G3: the peer-held ticket's block never reaches this driver's worker"
# …and after a clean run every batched claim is released. Glob loop rather than `ls`: an unmatched
# glob makes `ls` exit non-zero, which under `pipefail` turns the whole probe into a failure.
leftover=0
for _l in "$T/governor/.locks/ticket-"*; do if [[ -d "$_l" ]]; then leftover=$((leftover+1)); fi; done
assert_eq "$leftover" "0" "G4: every claim lock (primary AND batched) is released at the end of the run"

assert_done
