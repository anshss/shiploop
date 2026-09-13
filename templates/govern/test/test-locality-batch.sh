#!/usr/bin/env bash
# Locality batching. Exploration is the dominant cost of a resolved ticket (~98% cacheRead), so
# tickets touching the same area are grouped into ONE worker that explores once. Proves:
#   (A) govern::ticket_paths returns MEASURED file paths only (`Files:`, or the scout's verified
#       targetPaths), ignores shell-variable interpolations and globs, and returns "" for a ticket
#       whose only scope signal is `Where:` PROSE — prose is not a measurement, and keying on it
#       forced a leaf-directory approximation that collapsed the backlog into a couple of buckets.
#       govern::paths_overlap then batches on EXACT shared paths.
#   (B) GOVERN_BATCH_MAX=1 partitions into SINGLETONS — the pre-re-key behavior.
#   (C) max>1 partitions into DISJOINT, order-preserving, size-capped groups sharing real files.
#   (D) an UNMEASURED ticket is never batched on a guess — no measurement means no batch.
#   (E) dependency-related tickets are NEVER co-batched — in EITHER direction, including the implicit
#       `**Blocks:**` edge — so a group can never be worked out of dependency order.
#   (F) per-ticket outcome mapping is FAIL-CLOSED: only an explicit `resolved` entry in the report's
#       `tickets` array maps to resolved; a different status, a missing entry, an empty array and an
#       unparseable report all map to "" (⇒ the caller leaves the ticket in tickets.md).
# These functions folded co-batched tickets into one dispatch, amortizing exploration cost across
# them; the dispatch side that called them (accepting multiple ticket numbers on one spawn, folding
# their blocks into the prompt) lived in the headless dispatch launcher, retired along with it. The
# interactive lane dispatches ONE ticket per worker (`.claude/agents/worker.md`), so batching has no
# current caller: these functions and their tests stay in case a future dispatcher wants them.
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
## #1, spawn-worker knob
**Severity:** High

**Files:** templates/govern/spawn-worker.sh templates/govern/lib/common.sh

Body prose mentioning some/other/path.ts that must not enter the measured set.
---
## #2 — bookkeep field
**Severity:** High

**Files:** templates/govern/lib/common.sh templates/govern/land-resolution.sh
---
## #3 — spawn-worker retry
**Severity:** Medium

**Files:** templates/govern/resolve-ticket.sh templates/govern/spawn-worker.sh $WORKTREE_BASE/ticket-N
---
## #4 — test flake
**Severity:** Medium

**Files:** templates/govern/test/test-wrap-in-place.sh
---
## #5 — no paths at all
**Severity:** Medium

Where: the operator's judgment about how aggressive the default should be
---
## #6 — prose is not a measurement
**Severity:** Low

Where: templates/govern/spawn-worker.sh and templates/govern/lib/common.sh
---
## #7 — depends on #1
**Severity:** Low

**Depends on:** #1

**Files:** templates/govern/spawn-worker.sh
---
## #8 — blocks #2 from the other side
**Severity:** Low

**Blocks:** #2

**Files:** templates/govern/land-resolution.sh
---
EOF

# ── (A) measured-path derivation + exact overlap ────────────────────────────
assert_eq "$(govern::ticket_paths 1 "$TF" | tr '\n' ' ')" \
  "templates/govern/spawn-worker.sh templates/govern/lib/common.sh " \
  "A1: **Files:** yields the measured path list, in order"
assert_eq "$(govern::ticket_paths 3 "$TF" | tr '\n' ' ')" \
  "templates/govern/resolve-ticket.sh templates/govern/spawn-worker.sh " \
  "A2: \$VAR interpolation is dropped, not treated as a measured path"
assert_eq "$(govern::ticket_paths 5 "$TF")" "" "A3: a ticket declaring no path is unmeasured"
assert_eq "$(govern::ticket_paths 6 "$TF")" "" \
  "A4: prose Where: is NOT a measurement — no key, so no batch"
# Body prose must never leak into the measured set.
assert_absent "$(govern::ticket_paths 1 "$TF")" "some/other/path.ts" \
  "A5: body prose paths are not measured scope"
assert_eq "$(govern::paths_overlap "$(govern::ticket_paths 1 "$TF")" "$(govern::ticket_paths 2 "$TF")" && echo yes || echo no)" \
  "yes" "A6: #1 and #2 share lib/common.sh ⇒ overlap"
assert_eq "$(govern::paths_overlap "$(govern::ticket_paths 1 "$TF")" "$(govern::ticket_paths 4 "$TF")" && echo yes || echo no)" \
  "no"  "A7: disjoint file sets do not overlap"
assert_eq "$(govern::paths_overlap "$(govern::ticket_paths 1 "$TF")" "" && echo yes || echo no)" \
  "no"  "A8: an unmeasured ticket never overlaps anything"

# ── (B) GOVERN_BATCH_MAX=1 preserves today's behavior exactly ───────────────
assert_eq "$(govern::locality_groups 1 "1,2,3,4,5,6" "$TF" | tr '\n' ' ')" \
  "1 2 3 4 5 6 " "B: max=1 → one ticket per group (today's behavior)"
assert_eq "$(govern::locality_groups 0 "1,2,3" "$TF" | tr '\n' ' ')" \
  "1 2 3 " "B2: a bogus max (0) clamps to singletons, never to an unbounded group"

# ── (C) disjoint, order-preserving, size-capped groups ─────────────────────
groups="$(govern::locality_groups 2 "1,2,3,4" "$TF")"
assert_eq "$(printf '%s' "$groups" | tr '\n' ' ')" "1,2 3 4" "C1: max=2 caps the shared-file group at two, in candidate order"
groups3="$(govern::locality_groups 3 "1,2,3,4" "$TF")"
assert_eq "$(printf '%s' "$groups3" | tr '\n' ' ')" "1,2,3 4" "C2: max=3 batches all three file-sharing tickets; the test-only ticket stays separate"
# Disjointness: every input ticket appears exactly once across all groups.
flat="$(printf '%s' "$groups3" | tr ',\n' '  ' | tr -s ' ' '\n' | grep -c . || true)"
uniq_n="$(printf '%s' "$groups3" | tr ',\n' '  ' | tr -s ' ' '\n' | grep . | sort -u | wc -l | tr -d ' ')"
assert_eq "$flat" "4" "C3: every candidate is emitted"
assert_eq "$uniq_n" "4" "C3b: …exactly once — the groups are disjoint"

# ── (D) an UNMEASURED ticket is never batched ──────────────────────────────
assert_eq "$(govern::locality_groups 4 "5,1,2" "$TF" | tr '\n' ' ')" "5 1,2 " "D: unmeasured #5 stays a singleton"

# ── (E) dependency-related tickets are never co-batched ────────────────────
# #7 declares **Depends on:** #1 and shares #1's locality — the batcher must still split them.
assert_eq "$(govern::locality_groups 3 "1,7" "$TF" | tr '\n' ' ')" "1 7 " "E1: declared **Depends on:** blocks co-batching"
# Reverse direction: #1 leads, #7 declares the edge — proven above. Now the IMPLICIT edge: #8 declares
# **Blocks:** #2, so #2 depends on #8; both are 'govern'. Must not co-batch either.
assert_eq "$(govern::locality_groups 3 "2,8" "$TF" | tr '\n' ' ')" "2 8 " "E2: implicit **Blocks:** edge blocks co-batching"
# Sanity: with the dependency removed from the candidate set, the same tickets DO batch — proving E1/E2
# split on the dependency, not on some unrelated locality mismatch.
assert_eq "$(govern::locality_groups 3 "1,3" "$TF" | tr '\n' ' ')" "1,3 " "E3: shared file with NO dep edge does batch"

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

assert_done
