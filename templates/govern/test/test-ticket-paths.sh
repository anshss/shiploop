#!/usr/bin/env bash
# govern::ticket_paths: the measured file scope a ticket carries. Proves:
#   (A) it returns MEASURED file paths only (an explicit `**Files:**` field), ignores shell-variable
#       interpolations and globs, and returns "" for a ticket whose only scope signal is `Where:`
#       PROSE — prose is not a measurement, and keying on it forced a leaf-directory approximation
#       that collapsed the backlog into a couple of buckets.
# This is the same measured signal the deterministic-apply.sh path allowlist and the dispatch-time
# overlap nudge both key off.
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
## #3 — spawn-worker retry
**Severity:** Medium

**Files:** templates/govern/resolve-ticket.sh templates/govern/spawn-worker.sh $WORKTREE_BASE/ticket-N
---
## #5 — no paths at all
**Severity:** Medium

Where: the operator's judgment about how aggressive the default should be
---
## #6 — prose is not a measurement
**Severity:** Low

Where: templates/govern/spawn-worker.sh and templates/govern/lib/common.sh
---
EOF

# ── (A) measured-path derivation ────────────────────────────
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

assert_done
