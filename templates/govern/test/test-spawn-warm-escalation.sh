#!/usr/bin/env bash
# §4.4b WARM ESCALATION — the dying attempt's findings must survive it.
#
# Retries are COLD: there is no `--resume`, so a retry is a fresh `-p` in the PRESERVED worktree. The
# FILES attempt 1 wrote survive; its CONTEXT does not. Escalation is therefore a full-price second
# attempt that re-derives at the ceiling tier exactly what the floor tier already paid to learn.
# `.governor-notes.md` was the existing seam, but as unstructured prose the retry had to read an essay
# to find the three facts that change what it does. The STRUCTURED HANDOFF BLOCK is those three facts:
#
#   <!-- GOVERN:HANDOFF -->
#   ### Handoff — attempt N (<status>)
#   **Ruled out:** …
#   **Stopped at:** …
#   **Would try next:** …
#   <!-- /GOVERN:HANDOFF -->
#
# Covered here:
#   1. a worker-written handoff block ROUND-TRIPS into the escalated retry's prompt
#   2. the LAST block wins, and handoff blocks are STRIPPED from the freeform notes (no double-send)
#   3. the retry prompt tells the next worker to write one, in the same shape
#   4. a FIRST attempt gets neither block (zero context cost in the common case)
#   5. a hard-killed worker that never wrote one gets a GOVERNOR-synthesized block that INVENTS
#      NOTHING — it says outright that nothing was ruled out
#   6. the end marker cannot forge a worker-prompt section fence
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket
**Severity:** Medium — test.
Observed: thing is broken.
---
EOF
printf 'DOC\n' > "$TMP/governor/preferences.md"
printf 'PROMPT-HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

# echoes $WORKTREE_BASE/<slug> exactly, so the path spawn-worker CREATES is the one it READS notes from
cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/\$1"; echo "$TMP/wt/\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# ── 1/2/3. Round-trip a worker-written handoff into the retry prompt ─────────────────────────────
mkdir -p "$TMP/wt/ticket-7"
cat > "$TMP/wt/ticket-7/.governor-notes.md" <<'EOF'
Freeform scratchpad line from attempt one.

<!-- GOVERN:HANDOFF -->
### Handoff — attempt 1 (failed)
**Ruled out:** STALE-EARLIER-BLOCK — must not be the one injected
**Stopped at:** nowhere
**Would try next:** nothing
<!-- /GOVERN:HANDOFF -->

More freeform prose between the blocks.

<!-- GOVERN:HANDOFF -->
### Handoff — attempt 2 (failed)
**Ruled out:** RULEDOUT-MARKER — the retry lock is NOT in db/pool.ts; that file has no lock at all
**Stopped at:** STOPPEDAT-MARKER — src/queue/claim.ts:88, the advisory-lock acquire
**Would try next:** NEXT-MARKER — check whether claim.ts:88 releases on the error path
<!-- /GOVERN:HANDOFF -->
EOF

cat > "$TMP/fake-claude-capture.sh" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" > "$TMP/seen-prompt.txt"
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude-capture.sh"

run_spawn() { # <logroot> <claude-bin> [extra env...]
  local logroot="$1" bin="$2"; shift 2
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$logroot" \
      GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$bin" \
      GOVERN_WORKER_TIMEOUT=60 \
      "$@" \
      "$SPAWN" 7 </dev/null
}

run_spawn "$TMP/logs1" "$TMP/fake-claude-capture.sh" >/dev/null
seen="$(cat "$TMP/seen-prompt.txt")"

assert_contains "$seen" "STRUCTURED HANDOFF" "the retry prompt carries a dedicated structured-handoff section [§4.4b]"
assert_contains "$seen" "RULEDOUT-MARKER"  "the handoff's 'ruled out' reaches the escalated attempt"
assert_contains "$seen" "STOPPEDAT-MARKER" "the handoff's 'stopped at' reaches the escalated attempt"
assert_contains "$seen" "NEXT-MARKER"      "the handoff's 'would try next' reaches the escalated attempt"
assert_not_contains "$seen" "STALE-EARLIER-BLOCK" \
  "only the LAST handoff block is injected — an earlier attempt's stale block is not"
assert_contains "$seen" "Freeform scratchpad line from attempt one." \
  "the freeform notes still reach the retry"
# No double-send: the marker appears exactly once in the whole prompt.
assert_eq "$(grep -c 'RULEDOUT-MARKER' <<<"$seen")" "1" \
  "handoff blocks are STRIPPED from the freeform notes body — nothing is sent twice"
assert_contains "$seen" "untrusted" "the handoff is framed as untrusted evidence, not instructions"
assert_contains "$seen" "<!-- GOVERN:HANDOFF -->" \
  "the retry prompt states the exact block shape the NEXT attempt must write"
assert_contains "$seen" "**Ruled out:**" "the required block shape names its three fields"

# ── 6. the end marker must not be forgeable as a worker-prompt section fence ─────────────────────
assert_not_contains "$seen" "GOVERN:END handoff" \
  "the handoff end marker is </GOVERN:HANDOFF>, never a GOVERN:END section fence prompt_apply_sections would honour"

# ── 4. FIRST attempt gets neither block ─────────────────────────────────────────────────────────
rm -rf "$TMP/wt/ticket-7"
run_spawn "$TMP/logs2" "$TMP/fake-claude-capture.sh" >/dev/null
seen2="$(cat "$TMP/seen-prompt.txt")"
assert_not_contains "$seen2" "STRUCTURED HANDOFF" "a FIRST attempt gets no handoff section (zero context cost)"
assert_not_contains "$seen2" "PREVIOUS ATTEMPT'S NOTES" "a FIRST attempt gets no notes section either"

# ── 5. a hard-killed worker gets a GOVERNOR-synthesized block that invents nothing ───────────────
# The worker emits turns (one of them a Bash command) and then hangs — killed by the wall clock,
# never writing a handoff of its own.
rm -rf "$TMP/wt/ticket-7"
cat > "$TMP/fake-claude-hang.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pnpm vitest run src/queue"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}],"usage":{"input_tokens":1,"output_tokens":1}}}\n'
sleep 60
EOF
chmod +x "$TMP/fake-claude-hang.sh"

out="$(run_spawn "$TMP/logs3" "$TMP/fake-claude-hang.sh" GOVERN_WORKER_TIMEOUT=3)"
assert_eq "$(printf '%s' "$out" | jq -r '.status')" "timeout" "the hung worker is killed before it can write a handoff"
nf="$TMP/wt/ticket-7/.governor-notes.md"
[[ -f "$nf" ]] && wrote=yes || wrote=no
assert_eq "$wrote" "yes" "the GOVERNOR writes a handoff when the killed worker could not [§4.4b]"
notes="$(cat "$nf" 2>/dev/null || true)"
assert_contains "$notes" "<!-- GOVERN:HANDOFF -->" "the synthesized block uses the same fenced format"
assert_contains "$notes" "written by the GOVERNOR" "it declares that the worker did not write it"
assert_contains "$notes" "nothing here has been ruled out" \
  "it INVENTS NOTHING — a harness-derived block states plainly that nothing was ruled out"
assert_contains "$notes" "pnpm vitest run src/queue" \
  "'Stopped at' carries the last shell command, which the governor CAN prove off the stream"

# and it must not clobber a real worker-written handoff
printf '\n<!-- GOVERN:HANDOFF -->\nREAL-WORKER-BLOCK\n<!-- /GOVERN:HANDOFF -->\n' > "$nf"
run_spawn "$TMP/logs4" "$TMP/fake-claude-hang.sh" GOVERN_WORKER_TIMEOUT=3 >/dev/null
assert_eq "$(grep -c 'written by the GOVERNOR' "$nf" || true)" "0" \
  "a real worker-written handoff is never overwritten by a harness-derived stub"

assert_done
