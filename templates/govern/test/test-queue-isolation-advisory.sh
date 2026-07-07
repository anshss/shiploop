#!/usr/bin/env bash
# Guard test for the queue-isolation advisory wiring (#46): the Stop hook
# (ticket-sweep-reminder.sh) folds a SOFT, never-blocking note into its reconcile
# reason for any ticket whose **Where:** line targets NEITHER a sub-repo NOR the
# harness — i.e. an EXTERNAL tool/skill that merely shared this terminal. Verifies
# the wiring end-to-end against common.sh's govern::out_of_scope_tickets: an
# out-of-scope ticket is flagged, an in-scope one is not, and a Where-less ticket
# is never flagged. Deterministic — no real Claude, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
# The hook lives at templates/hooks (template) | <root>/scripts (workspace); GOVERN_HOOKS_DIR
# (from assert.sh) resolves whichever layout we're in (#255).
SWEEP="$GOVERN_HOOKS_DIR/ticket-sweep-reminder.sh"

# Build a sandbox "main checkout": a git repo owning queue/tickets.md, plus a hermetic
# scripts/lib/workspace.sh (via mk_ws_stub) so the hook's advisory subshell — which forces
# GOVERN_WS_ROOT="$MAIN" — reads a KNOWN in-scope REPOS list (alpha web). Echoes $T.
mk_main() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/main/queue"
  ( cd "$T/main" && git init -q && git config user.email t@t && git config user.name t \
      && printf '## #1 — seed\n' > queue/tickets.md && git add -A && git commit -q -m init )
  mk_ws_stub "$T/main"   # writes $T/main/scripts/lib/workspace.sh, REPOS=(alpha web)
  echo "$T"
}

# Run the Stop hook against sandbox <T> with a fresh session id. No SessionStart baseline
# exists, so did_code_work falls back to the absolute check: an UNcommitted queue/tickets.md
# (which every case below writes) counts as this-session work → the hook fires and we can
# inspect the reconcile reason. Private TMPDIR per call so the once-per-session marker never
# collides across cases. Point GOVERN_WS_ROOT at the sandbox (same reason test-ticket-sweep.sh
# does): otherwise the earlier #252 dangling-validation-ref lint's common.sh defaults WS_ROOT to
# the template repo, fails to source its (absent) scripts/lib/workspace.sh, and captures that
# source-error noise as a spurious "evidence summary MISSING" block BEFORE the reconcile+advisory
# path — masking the advisory (#255-class layout gotcha).
sweep() { # <T> <session_id>
  local td; td="$(mktemp -d)"
  printf '{"session_id":"%s","cwd":"%s/main","stop_hook_active":false}' "$2" "$1" \
    | META_ROOT="$1/main" GOVERN_WS_ROOT="$1/main" TMPDIR="$td" bash "$SWEEP"
}

assert_not_contains() { # haystack needle message
  if grep -qF "$2" <<<"$1"; then
    printf 'FAIL - %s\n       [%s] UNEXPECTEDLY found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok   - %s\n' "$3"; fi
}

# ── 1. Out-of-scope ticket flagged; in-scope + no-Where NOT flagged ──
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #10 — in-scope sub-repo work
**Severity:** MEDIUM
**Where:** `alpha/src/handler.ts`
**Observed:** targets a real sub-repo.

## #11 — external tool follow-up
**Severity:** LOW
**Where:** apollo-mcp integration (external tool, its own tracker)
**Observed:** shared this terminal but belongs elsewhere.

## #12 — no Where line
**Severity:** LOW
**Observed:** has no Where line at all.
EOF
out="$(sweep "$T" iso1)"
assert_contains     "$out" '"decision":"block"'  "hook fires (dirty tickets.md → this-session work)"
assert_contains     "$out" 'QUEUE ISOLATION'     "out-of-scope ticket surfaces the isolation advisory"
assert_contains     "$out" '#11'                 "the external-tool ticket #11 is named in the advisory"
assert_not_contains "$out" '#10'                 "the in-scope sub-repo ticket #10 is NOT flagged"
assert_not_contains "$out" '#12'                 "the Where-less ticket #12 is NOT flagged"

# ── 2. All tickets in-scope → the hook still fires but NO isolation advisory ──
T="$(mk_main)"
cat > "$T/main/queue/tickets.md" <<'EOF'
## #20 — sub-repo work
**Severity:** MEDIUM
**Where:** `web/pages/index.tsx`
**Observed:** a real sub-repo.

## #21 — harness work
**Severity:** LOW
**Where:** `scripts/govern/run-loop.sh`
**Observed:** the harness itself.

## #22 — no Where
**Observed:** nothing targetable.
EOF
out="$(sweep "$T" iso2)"
assert_contains     "$out" '"decision":"block"' "hook still fires with only in-scope tickets"
assert_not_contains "$out" 'QUEUE ISOLATION'    "no advisory when every ticket is in-scope"

assert_done
