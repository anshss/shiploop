#!/usr/bin/env bash
# Unit proof for the PR-hygiene helpers ported from the fleet instance:
#   govern::_strip_ticket_ref     — strips leaked internal ticket-ids from PR titles/bodies
#   govern::out_of_scope_tickets  — advisory: tickets targeting neither the workspace nor the harness
# Both are pure (no network / no PR mutation) so they're covered here as unit assertions.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# Source common.sh in this shell so we can call the helpers directly.
export GOVERN_TICKETS_FILE=/dev/null
source "$COMMON"

# ── _strip_ticket_ref: covers the leaked shapes worker prompts sometimes emit.
assert_eq "$(govern::_strip_ticket_ref 'Fix(#42): silence noisy log' 42)" \
  "silence noisy log" "strip 'Fix(#N):' prefix"
assert_eq "$(govern::_strip_ticket_ref 'fix #42: tidy imports' 42)" \
  "tidy imports" "strip 'fix #N:' prefix"
assert_eq "$(govern::_strip_ticket_ref 'ship the widget (#42)' 42)" \
  "ship the widget" "strip trailing '(#N)'"
assert_eq "$(govern::_strip_ticket_ref 'closes #42 in the runbook' 42)" \
  "closes in the runbook" "strip bare '#N' anywhere"

# Boundary: #6 must NOT touch #60 (the classic ticket-N-vs-ticket-N0 trap).
assert_eq "$(govern::_strip_ticket_ref 'refs #6 near #60' 6)" \
  "refs near #60" "boundary: stripping #6 leaves #60 untouched"

# Idempotent: nothing to strip → identical.
assert_eq "$(govern::_strip_ticket_ref 'clean title with no ref' 42)" \
  "clean title with no ref" "no-op when no ref present"

# Non-numeric N is a no-op (guard).
assert_eq "$(govern::_strip_ticket_ref '#42 in title' 'abc')" \
  "#42 in title" "no-op when N is not numeric"

# ── out_of_scope_tickets: allowlist-based, flags only tickets whose Where names NOTHING in-scope.
cat > "$T/tickets.md" <<'EOF'
# Tickets

## Open
---
## #1 — legit sub-repo ticket
**Where:** `alpha/src/foo.ts`
body
---
## #2 — legit harness ticket
**Where:** `scripts/govern/run-loop.sh`
body
---
## #3 — external tool ticket that leaked in
**Where:** `founder-os gtm:setup command`
body
---
## #4 — sub-repo ticket that also mentions an external tool (allowlist wins)
**Where:** `web/pages/index.tsx` — cross-refs founder-os
body
---
## #5 — no Where line at all
body only
---
EOF

out="$(govern::out_of_scope_tickets "$T/tickets.md")"
# Only #3 should be flagged: #1 names a sub-repo, #2 names scripts/, #4 names a sub-repo, #5 has no Where.
assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '{print $1}' | sort -n | tr '\n' ' ')" \
  "3 " "out_of_scope_tickets flags ONLY the truly external ticket (#3)"
assert_contains "$out" "founder-os gtm:setup" "flagged row carries the offending Where text for the operator"

assert_done
