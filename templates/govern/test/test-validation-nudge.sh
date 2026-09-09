#!/usr/bin/env bash
# Guard test for the validation-record nudge advisory (work item 5): the Stop hook
# (ticket-sweep-reminder.sh) folds a SOFT, never-blocking note into its reconcile reason for any
# OPEN, validation-shaped ticket (govern::is_validation_ticket) that has no matching
# .claude/shiploop/validation/ticket-<N>-*.md evidence file yet. Verifies the wiring end-to-end
# against common.sh's govern::tickets_missing_validation_doc: a validation ticket with no doc is
# flagged, one that already has a doc is not, and an ordinary (non-validation) ticket is never
# flagged. Also proves the kill switch. Deterministic: no real Claude, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# The hook lives at templates/hooks (template) | <root>/scripts (workspace); GOVERN_HOOKS_DIR
# (from assert.sh) resolves whichever layout we're in (#255).
SWEEP="$GOVERN_HOOKS_DIR/ticket-sweep-reminder.sh"

# Build a sandbox "main checkout": a git repo owning queue/tickets.md, plus a hermetic
# scripts/lib/workspace.sh (via mk_ws_stub). Echoes $T.
mk_main() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/main/queue"
  ( cd "$T/main" && git init -q && git config user.email t@t && git config user.name t \
      && printf '## #1 — seed\n' > queue/tickets.md && git add -A && git commit -q -m init )
  mk_ws_stub "$T/main"   # writes $T/main/scripts/lib/workspace.sh, REPOS=(alpha web)
  echo "$T"
}

# Run the Stop hook against sandbox <T> with a fresh session id. No SessionStart baseline exists,
# so did_code_work falls back to the absolute check: an UNcommitted queue/tickets.md (which every
# case below writes) counts as this-session work, so the hook fires and we can inspect the
# reconcile reason. Private TMPDIR per call so the once-per-session marker never collides across
# cases. GOVERN_WS_ROOT points at the sandbox for the same reason test-ticket-sweep.sh and
# test-queue-isolation-advisory.sh do (#255-class layout gotcha with the earlier lint subshells).
sweep() { # <T> <session_id> [extra env assignment...]
  local T="$1" sid="$2" td; shift 2
  td="$(mktemp -d)"
  printf '{"session_id":"%s","cwd":"%s/main","stop_hook_active":false}' "$sid" "$T" \
    | META_ROOT="$T/main" GOVERN_WS_ROOT="$T/main" TMPDIR="$td" "$@" bash "$SWEEP"
}

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] UNEXPECTEDLY found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# ── 1. A validation-shaped ticket with no evidence doc → flagged; an ordinary ticket → not ────────
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #30 — VALIDATION: does the widget actually work

**Severity:** Medium

body

---

## #31 — ordinary bug fix

**Severity:** Low

body

---
EOF
out="$(sweep "$T" nudge1)"
assert_contains     "$out" '"decision":"block"'   "hook fires (dirty tickets.md → this-session work)"
assert_contains     "$out" 'VALIDATION RECORD'    "a validation-shaped ticket with no doc surfaces the nudge"
assert_contains     "$out" '#30'                  "the validation ticket #30 is named in the nudge"
assert_not_contains "$out" '#31'                  "the ordinary ticket #31 is NOT flagged"
assert_contains     "$out" '/validated'           "the nudge tells the operator which command to run"

# ── 2. The same ticket, but its evidence doc already exists → no nudge ────────────────────────────
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #40 — SPIKE: does caching help

**Severity:** Low

body

---
EOF
mkdir -p "$T/main/.claude/shiploop/validation"
printf 'already recorded\n' > "$T/main/.claude/shiploop/validation/ticket-40-spike-does-caching-help.md"
out="$(sweep "$T" nudge2)"
assert_contains     "$out" '"decision":"block"' "hook still fires"
assert_not_contains "$out" 'VALIDATION RECORD'  "no nudge once the evidence doc already exists"

# ── 3. Only ordinary tickets → no nudge at all ─────────────────────────────────────────────────────
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #50 — refactor the config loader

**Severity:** Low

body

---
EOF
out="$(sweep "$T" nudge3)"
assert_contains     "$out" '"decision":"block"' "hook fires with only ordinary tickets"
assert_not_contains "$out" 'VALIDATION RECORD'  "no nudge when nothing is validation-shaped"

# ── 4. Kill switch: GOVERN_VALIDATION_NUDGE=0 suppresses the nudge even though it would fire ──────
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #60 — VALIDATION: does the export round-trip

**Severity:** Medium

body

---
EOF
out="$(sweep "$T" nudge4 env GOVERN_VALIDATION_NUDGE=0)"
assert_contains     "$out" '"decision":"block"' "hook still fires under the kill switch"
assert_not_contains "$out" 'VALIDATION RECORD'  "GOVERN_VALIDATION_NUDGE=0 suppresses the advisory"

assert_done
