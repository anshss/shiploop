#!/usr/bin/env bash
# resolve-ticket.sh's validation-evidence gate (step 2) now decides from STRUCTURED FIELDS only
# (the heading VALIDATION|SPIKE marker, or a `**Type:**` line) -- never the broader prose tells
# (govern::is_validation_ticket's "Live-verif" / "actually work" / "PASS/FAIL" matches anywhere in
# the block). Those prose tells stay live for the advisory-only nudge
# (govern::tickets_missing_validation_doc); a script should never REFUSE to land a PR off a phrase
# the advisor happened to write in Observed/Done-when text.
#
# Also covers the new GOVERN_VALIDATION_GATE kill switch at this call site (previously only the
# Stop-hook block, ticket-sweep-reminder.sh, answered to it).
#
# Hermetic, resolve-ticket.sh sandboxed next to stubs of merge-pr.sh / await-ci.sh /
# land-resolution.sh, no network, no gh, no real push -- same harness shape as
# test-validation-gate-heading-variants.sh.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"

LANDED="$T/landed.log"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

# #1: heading VALIDATION marker (structured) -- must still gate.
# #2: prose-ONLY tell ("actually works" in the heading, no VALIDATION/SPIKE word, no **Type:**) --
#     must NOT gate anymore: this is the advisor's own wording, not a fact the gate can check.
# #3: an explicit **Type:** line (structured) -- must still gate.
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets
---
## #1 — VALIDATION: structured heading marker
**Severity:** High
body1
---
## #2 — Confirm the payment webhook actually works
**Severity:** High — prose only, no VALIDATION/SPIKE word and no **Type:** line
body2
---
## #3 — check the sandbox path
**Type:** Validation spike
**Severity:** High
body3
---
TIX
( cd "$T" && git add -A && git commit -qm init )

rpt() { printf '{"status":"resolved","pr":{"repo":"alpha","number":%s01,"url":"u"},"prs":[],"validation":null}' "$1"; }

: > "$LANDED"
out1="$( cd "$T" && printf '%s' "$(rpt 1)" | bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"; rc1=$?
out2="$( cd "$T" && printf '%s' "$(rpt 2)" | bash "$T/bin/resolve-ticket.sh" 2 2>&1 )"; rc2=$?
out3="$( cd "$T" && printf '%s' "$(rpt 3)" | bash "$T/bin/resolve-ticket.sh" 3 2>&1 )"; rc3=$?

assert_eq "$rc1" "3" "1. a structured VALIDATION heading still trips the gate (exit 3, no evidence)"
assert_contains "$out1" "no live-test evidence" "1b. #1 refuses on the no-evidence wording"
assert_eq "$rc2" "0" "2. a PROSE-ONLY tell ('actually works', no structured marker) no longer trips the gate"
assert_eq "$rc3" "3" "3. an explicit **Type:** Validation line still trips the gate (exit 3, no evidence)"
assert_contains "$out3" "no live-test evidence" "3b. #3 refuses on the no-evidence wording"

# #2 must actually have LANDED (the whole point: a prose-only tell no longer blocks resolution).
assert_eq "$(landed_count)" "1" "4. exactly the prose-only ticket (#2) landed; the two structured ones stayed parked"

# ── 5. GOVERN_VALIDATION_GATE=0 bypasses even a structured VALIDATION heading ────────────────
: > "$LANDED"
out5="$( cd "$T" && printf '%s' "$(rpt 1)" | GOVERN_VALIDATION_GATE=0 bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"; rc5=$?
assert_eq "$rc5" "0" "5. GOVERN_VALIDATION_GATE=0 bypasses the gate even on a structured VALIDATION heading"
assert_eq "$(landed_count)" "1" "5b. and the ticket actually lands"

assert_done
