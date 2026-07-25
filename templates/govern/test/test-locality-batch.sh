#!/usr/bin/env bash
# #23 — locality batching. Exploration is the dominant cost of a resolved ticket (~98% cacheRead), so
# tickets touching the same area are grouped into ONE worker that explores once. Proves:
#   (A) govern::ticket_locality derives a key from `Where:` (and prefers a measured `Files:` list),
#       ignores shell-variable interpolations, and returns "" when the ticket declares no path.
#   (B) GOVERN_BATCH_MAX=1 (the default) partitions into SINGLETONS — today's exact behavior.
#   (C) max>1 partitions into DISJOINT, order-preserving, size-capped locality groups.
#   (D) an UNLOCALIZED ticket is never batched on a guess.
#   (E) dependency-related tickets are NEVER co-batched — in EITHER direction, including the implicit
#       `**Blocks:**` edge — so a group can never be worked out of dependency order.
#   (F) per-ticket outcome mapping is FAIL-CLOSED: only an explicit `resolved` entry in the report's
#       `tickets` array maps to resolved; a different status, a missing entry, an empty array and an
#       unparseable report all map to "" (⇒ the caller leaves the ticket in tickets.md).
#   (G) spawn-worker.sh accepts co-batched ticket numbers, folds their blocks into the prompt, and
#       injects the per-ticket report contract — while a single-ticket spawn stays unbatched.
# Sandboxed: temp tickets.md, hermetic workspace stub; no network, no worker spawned.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

# Assertion: needle must NOT be present in haystack (assert.sh has no assert_absent).
assert_absent() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then printf 'FAIL - %s\n       [%s] unexpectedly present\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT/ws"
source "$DIR/../lib/common.sh"

TF="$ROOT/tickets.md"
cat > "$TF" <<'EOF'
## #1 — run-loop knob
**Severity:** High

Where: shiploop/templates/govern/run-loop.sh (+ workspace mirror) and templates/govern/lib/common.sh

Body prose mentioning some/other/path.ts that must not outvote the two govern hits.
---
## #2 — bookkeep field
**Severity:** High

Where: scripts/govern/govern-bookkeep.sh — the resolve/delete path
---
## #3 — spawn-worker retry
**Severity:** Medium

Where: shiploop/templates/govern/spawn-worker.sh (retry escalation) at $WORKTREE_BASE/ticket-N
---
## #4 — test flake
**Severity:** Medium

Where: templates/govern/test/test-wrap-in-place.sh section 5
---
## #5 — no paths at all
**Severity:** Medium

Where: the operator's judgment about how aggressive the default should be
---
## #6 — measured scope wins
**Severity:** Low

**Files:** queue/tickets.md
Where: shiploop/templates/govern/run-loop.sh
---
## #7 — depends on #1
**Severity:** Low

**Depends on:** #1

Where: shiploop/templates/govern/run-loop.sh
---
## #8 — blocks #2 from the other side
**Severity:** Low

**Blocks:** #2

Where: scripts/govern/govern-bookkeep.sh
---
EOF

# ── (A) locality key derivation ────────────────────────────────────────────
assert_eq "$(govern::ticket_locality 1 "$TF")" "govern"  "A1: dominant dir wins over a one-off prose path"
assert_eq "$(govern::ticket_locality 2 "$TF")" "govern"  "A2: hub/workspace mirror pair share one key"
assert_eq "$(govern::ticket_locality 3 "$TF")" "govern"  "A3: \$VAR interpolation is not treated as a path"
assert_eq "$(govern::ticket_locality 4 "$TF")" "test"    "A4: nested dir resolves to its leaf name"
assert_eq "$(govern::ticket_locality 5 "$TF")" ""        "A5: a ticket declaring no path is unlocalized"
assert_eq "$(govern::ticket_locality 6 "$TF")" "queue"   "A6: measured **Files:** outranks prose Where:"

# ── (B) GOVERN_BATCH_MAX=1 preserves today's behavior exactly ───────────────
assert_eq "$(govern::locality_groups 1 "1,2,3,4,5,6" "$TF" | tr '\n' ' ')" \
  "1 2 3 4 5 6 " "B: max=1 → one ticket per group (today's behavior)"
assert_eq "$(govern::locality_groups 0 "1,2,3" "$TF" | tr '\n' ' ')" \
  "1 2 3 " "B2: a bogus max (0) clamps to singletons, never to an unbounded group"

# ── (C) disjoint, order-preserving, size-capped groups ─────────────────────
groups="$(govern::locality_groups 2 "1,2,3,4" "$TF")"
assert_eq "$(printf '%s' "$groups" | tr '\n' ' ')" "1,2 3 4" "C1: max=2 caps the govern group at two, in candidate order"
groups3="$(govern::locality_groups 3 "1,2,3,4" "$TF")"
assert_eq "$(printf '%s' "$groups3" | tr '\n' ' ')" "1,2,3 4" "C2: max=3 batches all three govern tickets; 'test' stays separate"
# Disjointness: every input ticket appears exactly once across all groups.
flat="$(printf '%s' "$groups3" | tr ',\n' '  ' | tr -s ' ' '\n' | grep -c . || true)"
uniq_n="$(printf '%s' "$groups3" | tr ',\n' '  ' | tr -s ' ' '\n' | grep . | sort -u | wc -l | tr -d ' ')"
assert_eq "$flat" "4" "C3: every candidate is emitted"
assert_eq "$uniq_n" "4" "C3b: …exactly once — the groups are disjoint"

# ── (D) an unlocalized ticket is never batched ─────────────────────────────
assert_eq "$(govern::locality_groups 4 "5,1,2" "$TF" | tr '\n' ' ')" "5 1,2 " "D: unlocalized #5 stays a singleton"

# ── (E) dependency-related tickets are never co-batched ────────────────────
# #7 declares **Depends on:** #1 and shares #1's locality — the batcher must still split them.
assert_eq "$(govern::locality_groups 3 "1,7" "$TF" | tr '\n' ' ')" "1 7 " "E1: declared **Depends on:** blocks co-batching"
# Reverse direction: #1 leads, #7 declares the edge — proven above. Now the IMPLICIT edge: #8 declares
# **Blocks:** #2, so #2 depends on #8; both are 'govern'. Must not co-batch either.
assert_eq "$(govern::locality_groups 3 "2,8" "$TF" | tr '\n' ' ')" "2 8 " "E2: implicit **Blocks:** edge blocks co-batching"
# Sanity: with the dependency removed from the candidate set, the same tickets DO batch — proving E1/E2
# split on the dependency, not on some unrelated locality mismatch.
assert_eq "$(govern::locality_groups 3 "1,3" "$TF" | tr '\n' ' ')" "1,3 " "E3: same locality with NO dep edge does batch"

# ── (F) per-ticket outcome mapping is fail-closed ──────────────────────────
report='{"status":"resolved","pr":{"repo":"alpha","number":7},"tickets":[
  {"ticket":1,"status":"resolved","note":"landed in the group PR"},
  {"ticket":2,"status":"parked","note":"needs an operator call"},
  {"ticket":3,"status":"failed","note":"could not reproduce"}]}'
assert_eq "$(govern::batch_ticket_status "$report" 1)" "resolved" "F1: explicit resolved maps to resolved"
assert_eq "$(govern::batch_ticket_status "$report" 2)" "parked"   "F2: parked is NOT collapsed into the group verdict"
assert_eq "$(govern::batch_ticket_status "$report" 3)" "failed"   "F3: failed is NOT collapsed into the group verdict"
assert_eq "$(govern::batch_ticket_status "$report" 4)" ""         "F4: a ticket ABSENT from the array maps to '' (stays in queue)"
assert_eq "$(govern::batch_ticket_note   "$report" 2)" "needs an operator call" "F5: per-ticket note is carried through"
# The dangerous shapes: a group-level "resolved" must never leak onto a batched ticket.
assert_eq "$(govern::batch_ticket_status '{"status":"resolved","tickets":[]}' 9)" "" "F6: empty tickets array ⇒ '' despite a resolved GROUP status"
assert_eq "$(govern::batch_ticket_status '{"status":"resolved"}' 9)"             "" "F7: no tickets array at all ⇒ '' (legacy single-ticket report)"
assert_eq "$(govern::batch_ticket_status 'not json at all' 9)"                   "" "F8: unparseable report ⇒ '' — fail closed, never resolved"
assert_eq "$(govern::batch_ticket_status '{"tickets":[{"ticket":9}]}' 9)"        "" "F9: entry present but status missing ⇒ ''"

# ── (G) spawn-worker.sh folds a batch into the prompt ──────────────────────
# Same prompt-capture seam test-pr-footer.sh / test-spawn-worker.sh use: a fake `claude` that dumps
# the assembled prompt (the arg after -p) to a sink, plus a fake worktree cmd. No worker is launched.
if command -v jq >/dev/null 2>&1; then
  SW="$DIR/../spawn-worker.sh"
  mkdir -p "$ROOT/ws/governor" "$ROOT/wt"
  printf 'Resolve EXACTLY ONE ticket.\n\n{{TICKET_BLOCK}}\n\nreport: {{REPORT_PATH}}\n' > "$ROOT/ws/governor/worker-prompt.md"
  printf 'DOCTRINE-MARKER\n' > "$ROOT/ws/governor/preferences.md"
  cat > "$ROOT/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$ROOT/wt/\$1"; echo "$ROOT/wt/\$1"
EOF
  chmod +x "$ROOT/fake-worktree.sh"
  cat > "$ROOT/fake-claude.sh" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" > "\${PROMPT_SINK:?}"
report='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$ROOT/fake-claude.sh"

  run_spawn() { # <sink> <ticket...>  — prompt lands in <sink>
    local sink="$1"; shift
    env PROMPT_SINK="$sink" \
      GOVERN_TICKETS_FILE="$TF" \
      GOVERN_PREFERENCES_FILE="$ROOT/ws/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$ROOT/ws/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$ROOT/logs-$(basename "$sink")" \
      GOVERN_WORKTREE_CMD="$ROOT/fake-worktree.sh" \
      GOVERN_CLAUDE_BIN="$ROOT/fake-claude.sh" \
      "$SW" "$@" >/dev/null
    cat "$sink"
  }

  batched="$(run_spawn "$ROOT/p-batch" 1 2 3)"
  assert_contains "$batched" "## #1 — run-loop knob"      "G1: primary ticket block present"
  assert_contains "$batched" "## #2 — bookkeep field"     "G2: batched ticket #2 block folded in"
  assert_contains "$batched" "## #3 — spawn-worker retry" "G3: batched ticket #3 block folded in"
  assert_contains "$batched" "LOCALITY BATCH"             "G4: batch addendum overrides 'EXACTLY ONE ticket'"
  assert_contains "$batched" '"tickets": ['               "G5: per-ticket report contract injected"
  assert_contains "$batched" "#1, #2, #3"                 "G6: the group roster is stated to the worker"

  single="$(run_spawn "$ROOT/p-single" 1)"
  assert_contains "$single" "## #1 — run-loop knob"  "G7: single spawn still carries its block"
  assert_absent   "$single" "LOCALITY BATCH"         "G8: a single-ticket spawn is NOT batched"
  assert_absent   "$single" "## #2 — bookkeep field" "G9: …and carries no other ticket's block"

  # A batched number no longer in tickets.md (a concurrent driver resolved it) is DROPPED, not fatal.
  gone="$(run_spawn "$ROOT/p-gone" 1 999)"
  assert_contains "$gone" "## #1 — run-loop knob" "G10: an already-resolved batch member does not fail the spawn"
  assert_absent   "$gone" "LOCALITY BATCH"        "G11: …and the group collapses back to a plain single spawn"
else
  printf 'skip - G: jq not installed\n'
fi

assert_done
