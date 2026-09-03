#!/usr/bin/env bash
# #94 — NAMED DISPATCH is the only front door. Proves the four properties the purge is supposed to buy,
# END-TO-END through run-loop.sh with stubbed claude/gh/worktree in dry mode (no PR, no merge, no git
# mutation).
#
#   A. A bare invocation names nothing, so it does nothing: usage on stderr, exit 2. Not exit 0 with
#      an empty run, which in a script or a cron line reads as success.
#   B. NAMED-SET LOCALITY GROUPING (#55). `run-loop.sh 1 2 3` used to spawn one ungrouped driver per
#      ticket even at GOVERN_BATCH_MAX=3, putting concurrent workers on the same file. The set is now
#      partitioned by MEASURED file overlap first, and the fleet is sized in GROUPS.
#   C. SINGLE-TICKET CARVE-OUT. Naming exactly one ticket means "just this one": sequential, no
#      orchestrator, and no batching even when GOVERN_BATCH_MAX would allow it.
#   D. NAMED-SET DEPENDENCY ENFORCEMENT (#119). The `Depends on:` gate used to be SILENTLY IGNORED
#      whenever a ticket was named. Naming #N does not land #K, so it is enforced now: #N is deferred
#      with the blocker named, and no worker is burned.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_fixture() { # <T>
  local T="$1"
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
  cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s\n---\n' "\$prompt" >> "$T/prompts.txt"
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"tickets":[],"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
}
mk_fixture "$T"

write_tickets() { cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — primary
**Severity:** High. x.

**Files:** scripts/govern/run-loop.sh scripts/govern/lib/common.sh
---
## #2 — shares a file with #1
**Severity:** High. y.

**Files:** scripts/govern/lib/common.sh scripts/govern/govern-bookkeep.sh
---
## #4 — different area entirely
**Severity:** Medium. w.

**Files:** templates/seed/CLAUDE.md
---
EOF
}
write_tickets

run_driver() { # <env-assignments…> -- <run-loop args…>
  rm -f "$T/prompts.txt"; rm -rf "$T/logs"; mkdir -p "$T/logs"
  local -a envs=() args=(); local seen=0 a
  for a in "$@"; do
    if [[ "$seen" -eq 0 && "$a" == "--" ]]; then seen=1; continue; fi
    if [[ "$seen" -eq 0 ]]; then envs+=("$a"); else args+=("$a"); fi
  done
  env GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_WORKTREE_CMD="$T/wt.sh" GOVERN_CLAUDE_BIN="$T/bin/claude" \
    GOVERN_SETTING_SOURCES=user GOVERN_WORKER_TIMEOUT=60 \
    PATH="$T/bin:$PATH" ${envs[@]+"${envs[@]}"} \
    bash "$RL" --dry-run ${args[@]+"${args[@]}"} 2>&1 || true
}

# ── A — a bare invocation prints usage and exits 2 ─────────────────────────────────────────────
rcA=0; outA="$(env GOVERN_WS_ROOT="$T" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_LOG_ROOT="$T/logs" \
  PATH="$T/bin:$PATH" bash "$RL" 2>&1)" || rcA=$?
assert_eq "$rcA" "2" "A1: a bare run-loop.sh exits 2 (usage error), never 0"
assert_contains "$outA" "usage: run-loop.sh" "A2: …and prints usage"
assert_contains "$outA" "There is no backlog sweep" "A3: …that says so in as many words"
if printf '%s' "$outA" | grep -q '=== ticket #'; then f=1; else f=0; fi
assert_eq "$f" "0" "A4: …and dispatches nothing"

# ── B — named-set locality grouping ───────────────────────────────────────────────────────────
# #1 and #2 share scripts/govern/lib/common.sh; #4 shares nothing. Naming all three must yield TWO
# groups (#1+#2, #4), not three ungrouped drivers.
logB="$(run_driver GOVERN_BATCH_MAX=3 -- --serial 1 2 4)"
assert_contains "$logB" "dispatching 2 locality group(s) from 3 named ticket(s)" \
  "B1: the named set is partitioned into groups, and the count is logged"
assert_contains "$logB" "locality group: #1 #2" "B2: the two file-sharing tickets form ONE group"
assert_contains "$logB" "batch: #1 + #2" "B3: …handed to ONE worker, one PR"
if printf '%s' "$logB" | grep -qF 'locality group: #1 #2 #4'; then f=1; else f=0; fi
assert_eq "$f" "0" "B4: the file-disjoint ticket is never pulled into the group"
spawnsB="$(grep -c 'worker prompt' "$T/prompts.txt" 2>/dev/null || echo 0)"
assert_eq "$spawnsB" "2" "B5: two groups, two workers (not three)"

# The same set under --parallel spawns one child driver PER GROUP, and the cap is clamped to the
# group count rather than the ticket count.
logBP="$(run_driver GOVERN_BATCH_MAX=3 -- --parallel 1 2 4)"
assert_contains "$logBP" "parallel mode: 2 locality group(s)" "B6: --parallel fans out over GROUPS"
assert_contains "$logBP" "parallel: spawned #1 #2" "B7: …one child per group, handed the group's tickets"
if printf '%s' "$logBP" | grep -qF 'parallel: spawned #1 (pid'; then f=1; else f=0; fi
assert_eq "$f" "0" "B8: …never one ungrouped child per named ticket (the #55 defect)"

# ── C — single-ticket carve-out ───────────────────────────────────────────────────────────────
logC="$(run_driver GOVERN_BATCH_MAX=3 GOVERN_PARALLEL_DEFAULT=4 -- 1)"
assert_contains "$logC" "concurrency: serial" "C1: one named ticket stays sequential even with a parallel default"
assert_contains "$logC" "(single ticket #1)" "C2: …and is described as such"
if printf '%s' "$logC" | grep -q '^\[govern .*\] batch: '; then f=1; else f=0; fi
assert_eq "$f" "0" "C3: …and is never batched, whatever GOVERN_BATCH_MAX says"
if printf '%s' "$logC" | grep -qF 'parallel: spawned'; then f=1; else f=0; fi
assert_eq "$f" "0" "C4: …and no orchestrator process is put in the way"
promptsC="$(cat "$T/prompts.txt" 2>/dev/null || true)"
if printf '%s' "$promptsC" | grep -qF '## #2 — shares a file'; then f=1; else f=0; fi
assert_eq "$f" "0" "C5: only the named ticket's block reaches the worker"

# ── D — named-set dependency enforcement (#119) ───────────────────────────────────────────────
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — blocker, still unlanded
**Severity:** High. x.
---
## #2 — depends on the blocker
**Severity:** High. y.

**Depends on:** #1
---
EOF
logD="$(run_driver -- --serial 2)"
assert_contains "$logD" "#2 depends on unresolved #1" "D1: the Depends-on gate fires on a NAMED ticket"
assert_contains "$logD" "no worker burned (#119)" "D2: …before a worker is spawned"
if [[ -s "$T/prompts.txt" ]]; then f=1; else f=0; fi
assert_eq "$f" "0" "D3: …so no worker ran at all"
# The blocker itself is dispatchable: the gate defers the dependent, it does not freeze the set.
logD2="$(run_driver -- --serial 1 2)"
assert_contains "$logD2" "=== ticket #1" "D4: the blocker in the same named set still dispatches"

assert_done
