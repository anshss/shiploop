#!/usr/bin/env bash
# resolve-ticket.sh's GROUP landing path: a report carrying a non-empty `tickets` array (a worker
# batched several tickets onto one branch/one PR) lands PER TICKET instead of once. Proves:
#   1. a group of two tickets, both reported resolved, lands BOTH queue blocks and merges ONCE.
#   2. a group where one ticket resolves and one parks lands exactly the resolved one; the parked
#      one is never landed and stays in the queue.
#   3. a ticket the `tickets` array never names (dispatched as part of the group, but simply absent
#      from the array) is never landed either — no guessing at what the worker meant.
#   4. an unparseable report lands nothing (the existing top-level JSON guard, unchanged).
#   5. a single-ticket report with no `tickets` array lands exactly as it always has.
#   6. `newTickets`/`lessonPatch` (group-wide findings the worker states once) ride only the
#      PRIMARY ticket's landing call; every other group member's call has them stripped, so one
#      worker run never double-files a newTicket or double-promotes a lesson.
# A named set containing a dependency pair is never grouped in the first place — proven by
# test-locality-batch.sh's (E) section (govern::locality_groups), not re-proven here.
# Sandboxed exactly like test-resolve-ticket.sh: stubbed land-resolution.sh/merge-pr.sh/await-ci.sh/
# gh, no network, no real push.
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

LANDED="$T/landed.log"
MERGED="$T/merged.log"
cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"

# Logs "landed <N>" and the exact stdin body it received to land-body-<N>.json, so a case can
# inspect what resolve-ticket.sh actually sent this group member (newTickets/lessonPatch stripped
# or not).
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
body="$(cat)"
printf '%s' "$body" > "$LAND_BODY_DIR/land-body-${1:-0}.json"
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
printf '%s %s\n' "$1" "$2" >> "$MERGED_LOG"
exit "${STUB_MERGE_RC:-0}"
STUB
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *headRefName*) echo "stub-branch" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin"/*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH"
export LANDED_LOG="$LANDED"
export MERGED_LOG="$MERGED"
export LAND_BODY_DIR="$T"

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #40 — locality group primary

**Severity:** High

Done when: both group members land.

---

## #41 — locality group secondary

**Severity:** Medium

Done when: it lands alongside #40.
TIX
( cd "$T" && git add -A && git commit -qm init )

run_rt() { # <ticket> <report-json>
  ( cd "$T" && printf '%s' "$2" | bash "$T/bin/resolve-ticket.sh" "$1" >/dev/null 2>&1; echo "$?" )
}
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }
merged_count() { [[ -f "$MERGED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$MERGED" | wc -c | tr -d ' '; }
landed() { grep -qxF "landed $1" "$LANDED" 2>/dev/null && echo yes || echo no; }

# ── 1. both group members resolved: both land, ONE merge ────────────────────────────────────────
: > "$LANDED"; : > "$MERGED"
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"prs":[],
  "tickets":[{"ticket":40,"status":"resolved","note":"landed"},{"ticket":41,"status":"resolved","note":"landed"}]}'
rc="$(run_rt 40 "$report")"
assert_eq "$(landed 40)" "yes" "1a. group primary #40 lands"
assert_eq "$(landed 41)" "yes" "1b. group secondary #41 lands too"
assert_eq "$(landed_count)" "2" "1c. exactly two land calls for a two-member group"
assert_eq "$(merged_count)" "1" "1d. the shared PR is merged exactly once"

# ── 2. one resolved, one parked: only the resolved member lands ─────────────────────────────────
: > "$LANDED"; : > "$MERGED"
report='{"status":"resolved","pr":{"repo":"alpha","number":10,"url":"u"},"prs":[],
  "tickets":[{"ticket":40,"status":"resolved","note":"landed"},{"ticket":41,"status":"parked","note":"needs an operator call"}]}'
rc="$(run_rt 40 "$report")"
assert_eq "$(landed 40)" "yes" "2a. the resolved member lands"
assert_eq "$(landed 41)" "no"  "2b. the parked member is never landed"
assert_eq "$(landed_count)" "1" "2c. exactly one land call"

# ── 3. the array never names #41 at all: #41 is never landed ────────────────────────────────────
: > "$LANDED"; : > "$MERGED"
report='{"status":"resolved","pr":{"repo":"alpha","number":11,"url":"u"},"prs":[],
  "tickets":[{"ticket":40,"status":"resolved","note":"landed"}]}'
rc="$(run_rt 40 "$report")"
assert_eq "$(landed 40)" "yes" "3a. the named member lands"
assert_eq "$(landed 41)" "no"  "3b. a ticket the array never mentions is never landed"

# ── 4. an unparseable report lands nothing ───────────────────────────────────────────────────────
: > "$LANDED"; : > "$MERGED"
rc="$(run_rt 40 "not json at all")"
assert_eq "$(landed_count)" "0" "4a. unparseable stdin lands nothing"
assert_not_contains "$rc" "0" "4b. and exits non-zero"

# ── 5. a single-ticket report (no tickets array) lands exactly as before ────────────────────────
: > "$LANDED"; : > "$MERGED"
report='{"status":"resolved","pr":{"repo":"alpha","number":12,"url":"u"},"prs":[]}'
rc="$(run_rt 40 "$report")"
assert_eq "$(landed 40)" "yes" "5a. the single ticket lands"
assert_eq "$(landed_count)" "1" "5b. exactly one land call, unchanged from the legacy path"

# ── 6. newTickets/lessonPatch ride the PRIMARY ticket's call only ──────────────────────────────
: > "$LANDED"; : > "$MERGED"
report='{"status":"resolved","pr":{"repo":"alpha","number":13,"url":"u"},"prs":[],
  "newTickets":[{"title":"group-wide finding","severity":"Low","body":"found while working the group"}],
  "lessonPatch":{"file":"CLAUDE.md","anchor":"## Misc","text":"a group-wide lesson"},
  "tickets":[{"ticket":40,"status":"resolved","note":"landed"},{"ticket":41,"status":"resolved","note":"landed"}]}'
rc="$(run_rt 40 "$report")"
assert_contains "$(cat "$T/land-body-40.json" 2>/dev/null)" "group-wide finding" \
  "6a. the primary ticket's (#40) land call carries newTickets"
assert_not_contains "$(cat "$T/land-body-41.json" 2>/dev/null)" "group-wide finding" \
  "6b. the secondary ticket's (#41) land call has newTickets stripped"
assert_not_contains "$(cat "$T/land-body-41.json" 2>/dev/null)" "a group-wide lesson" \
  "6c. …and lessonPatch stripped too"

assert_done
