#!/usr/bin/env bash
# resolve-ticket.sh — the session-side resolve path (shiploop 1.19.3, the loop purge).
#
# The one invariant worth more than all the others: it must NEVER land a resolution it did not
# earn. Landing edits tickets.md, rewrites CLAUDE.md and pushes to origin/main, so a land on a red
# CI, on an unmerged PR, or on a validation ticket with no evidence is an irreversible wrong write.
# Every assertion below is a "did NOT land" assertion except the single happy path.
#
#   1. a report whose status is not "resolved" does not land.
#   2. merge refusal (merge-pr.sh exit 3 red / 4 unverifiable) does not land, and exits non-zero.
#   3. the no-evidence rule: a validation ticket with validation.ranLiveTest != true does not land.
#   4. the measured-negative rule: validation.gatePassed == false does not land.
#   5. the green path lands EXACTLY once.
#   6. GOVERN_RESOLVE_TICKET=0 refuses (exit 1) and does not land.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"   # TICKETS_FILE is $GOVERN_QUEUE_DIR/tickets.md
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# Sandbox the script next to STUBS of the collaborators it shells out to ("$DIR/merge-pr.sh" etc),
# so we exercise resolve-ticket's own decisions without a network, a gh, or a real push.
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
printf '%s\n' "${STUB_CI_STATE:-green}"
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_MERGE_RC:-0}"
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #40 — VALIDATION: does cross-provider restore round-trip

**Severity:** High

Done when: a real restore is proven end to end.

---

## #41 — backend: tighten the retry ladder

**Severity:** Low

Done when: the ladder stops at three.
TIX
( cd "$T" && git add -A && git commit -qm init )

rpt() { # <status> <ranLiveTest> <gatePassed-or-null>
  printf '{"status":"%s","pr":{"repo":"alpha","number":9,"url":"u"},"prs":[],"validation":{"ranLiveTest":%s,"gatePassed":%s,"evidence":"deploy 1, PASS"}}' "$1" "$2" "$3"
}
run_rt() { # <ticket> <report-json> ; env passed by caller
  ( cd "$T" && printf '%s' "$2" | bash "$T/bin/resolve-ticket.sh" "$1" >/dev/null 2>&1; echo "$?" )
}
# grep -c prints 0 AND exits 1 on no match, so a `|| echo 0` tail double-counts. Count with wc.
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

# ── 1. a non-resolved report never lands ─────────────────────────────────────────────────────────
: > "$LANDED"
rc="$(run_rt 41 "$(rpt parked true null)")"
assert_eq "$(landed_count)" "0" "1. a report whose status is not 'resolved' does not land"

# ── 2. merge refusal (CI red) never lands, and is reported as non-zero ────────────────────────────
: > "$LANDED"
rc="$(STUB_MERGE_RC=3 run_rt 41 "$(rpt resolved true null)")"
assert_eq "$(landed_count)" "0" "2. a merge refusal (CI red, merge-pr rc=3) does not land"
assert_not_contains "$rc" "0" "2. a merge refusal exits non-zero so the session can act"

# ── 2b. CI unverifiable is equally a refusal ─────────────────────────────────────────────────────
: > "$LANDED"
rc="$(STUB_MERGE_RC=4 run_rt 41 "$(rpt resolved true null)")"
assert_eq "$(landed_count)" "0" "2b. CI-unverifiable (merge-pr rc=4) does not land"

# ── 3. no live-test evidence on a VALIDATION ticket never lands ──────────────────────────────────
: > "$LANDED"
rc="$(run_rt 40 "$(rpt resolved false null)")"
assert_eq "$(landed_count)" "0" "3. a validation ticket with ranLiveTest!=true does not land"

# ── 4. a measured NEGATIVE is never auto-shipped ─────────────────────────────────────────────────
: > "$LANDED"
rc="$(run_rt 40 "$(rpt resolved true false)")"
assert_eq "$(landed_count)" "0" "4. validation.gatePassed=false does not land"

# ── 6. kill switch refuses and does not land ─────────────────────────────────────────────────────
: > "$LANDED"
rc="$(GOVERN_RESOLVE_TICKET=0 run_rt 41 "$(rpt resolved true null)")"
assert_eq "$(landed_count)" "0" "6. GOVERN_RESOLVE_TICKET=0 does not land"
assert_eq "$rc" "1" "6. GOVERN_RESOLVE_TICKET=0 exits 1 (never a silent no-op)"

# ── 5. the green path lands EXACTLY once ─────────────────────────────────────────────────────────
: > "$LANDED"
rc="$(STUB_MERGE_RC=0 run_rt 41 "$(rpt resolved true null)")"
assert_eq "$(landed_count)" "1" "5. a green, merged, evidenced resolve lands exactly once"

assert_done
