#!/usr/bin/env bash
# #29 — govern::ticket_deps must not harvest #N from PROSE that merely mentions "depends on" or
# other tickets by number. Proves:
#   (A) a ticket whose body contains a real `**Depends on:** #K` line PLUS a separate prose
#       sentence beginning "Depends on ..." that also mentions unrelated `#N` tickets returns
#       ONLY #K — the prose sentence must not contribute false dependencies (the exact #22
#       regression: "16 13 10" resolved against a single declared #16).
#   (B) a `**Depends on:**` line with multiple comma-separated numbers still parses all of them.
#   (C) the `**Blocks:**` implicit-blocker path (part B of the function) is unaffected.
# Sandboxed: temp tickets.md, hermetic workspace stub; no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT/ws"
source "$DIR/../lib/common.sh"

# ── (A)+(B) the #22 regression, reproduced verbatim ──
cat > "$ROOT/tickets.md" <<'EOF'
# Tickets
---
## #22 — evidence-based retry escalation
**Severity:** Medium

**Depends on:** #16

Depends on the `budget-exceeded` outcome introduced by the token-budget ticket, which is what distinguishes "ran out of room while exploring" from other failures. Coordinate with ticket #13 (CI-log injection on retry) and ticket #10 (GOVERN_FIX_CI is set by run-loop.sh:275 but never read by spawn-worker.sh).
---
## #16 — the real dependency
body
---
## #13 — merely mentioned in #22's prose, NOT a real dependency
body
---
## #10 — merely mentioned in #22's prose, NOT a real dependency
body
---
## #30 — multiple comma-separated deps still parse
**Severity:** Low

**Depends on:** #16, #13
body
EOF

deps22="$(govern::ticket_deps 22 "$ROOT/tickets.md" | tr '\n' ',')"
assert_eq "$deps22" "16," "A: #22 resolves ONLY the declared #16, not the prose-mentioned #13/#10 (#29)"

deps30="$(govern::ticket_deps 30 "$ROOT/tickets.md" | tr '\n' ',')"
assert_eq "$deps30" "16,13," "B: a **Depends on:** line with multiple comma-separated numbers still parses all of them"

# ── (C) the **Blocks:** implicit-blocker path is unaffected ──
cat > "$ROOT/blocks.md" <<'EOF'
# Tickets
---
## #40 — dependent, no marker of its own
body
---
## #41 — the blocker, declares the edge
**Blocks:** #40
body
EOF
assert_eq "$(govern::ticket_deps 40 "$ROOT/blocks.md" | tr '\n' ',')" "41," "C: **Blocks:** implicit-blocker path still works unaffected"

assert_done
