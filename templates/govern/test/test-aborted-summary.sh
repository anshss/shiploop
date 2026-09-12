#!/usr/bin/env bash
# Regression, re-targeted at resolve-ticket.sh (the loop purge moved this whole step here):
# a post-merge prod deploy/verify failure must be CLASSIFIED and must PARK the ticket, never silently
# land it and never be confused with a set -e abort at the unguarded migrate-command capture. The
# migrate-command capture is guarded with `|| true` precisely so `set -e` cannot abort the script at
# that line: exit 7 proves the classify-and-refuse path was REACHED, whereas exit 1 would be the old
# bug (a bare abort that leaves a merged-but-unbookkept ticket looking like nothing happened).
#
# Reproduces the observed shape: #1's auto-merge-repo PR merges, then the additive-migration
# deploy/verify step FAILS. resolve-ticket.sh must:
#   1. exit 7 (NOT 1, which is what a raw `set -e` abort at the capture line would give);
#   2. NOT land, land-resolution.sh (stubbed) must never be reached;
#   3. classify the failure in stderr (the exact wording resolve-ticket.sh prints);
#   4. append a `parked` row to ticket-history.jsonl so #1 is surfaced, not silently dropped.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# Sandbox the script next to STUBS of the collaborators it shells out to, so we exercise
# resolve-ticket's own migration-classification decision without a network, a gh, or a real push.
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
exit "${STUB_MERGE_RC:-0}"
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #1, additive-migration ticket whose post-merge deploy fails

**Severity:** Medium

Done when: the migration is live.

---
TIX
( cd "$T" && git add -A && git commit -qm init )

HIST="$T/history.jsonl"
report='{"status":"resolved","pr":{"repo":"alpha","number":901,"url":"http://pr/1"},"prs":[],"lessonPatch":null,"newTickets":[],"migration":{"needed":true,"destructive":false,"name":"20260623_add_index","note":"CREATE INDEX"}}'

# GOVERN_MIGRATE_CMD succeeds, GOVERN_VERIFY_CMD FAILS → the post-merge verify step fails. Pre-fix
# this aborted the whole script at the unguarded `mout=$(...)` assignment; post-fix
# the `|| true` lets control reach the verify → classify → PARK logic.
: > "$LANDED"
out="$( cd "$T" && printf '%s' "$report" \
  | GOVERN_HISTORY_FILE="$HIST" GOVERN_MIGRATE_CMD="true" GOVERN_VERIFY_CMD="false" \
    bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc=$?

assert_eq "$rc" "7" "post-merge migrate/verify failure exits 7 (classify-and-refuse path reached, NOT a set -e abort at the guarded capture)"
assert_eq "$(landed_count)" "0" "nothing landed, land-resolution.sh was never reached"
assert_contains "$out" "prod migration/verify FAILED" "the post-merge migrate/verify failure was CLASSIFIED in stderr (not a silent abort)"
assert_eq "$(jq -r 'select(.ticket==1) | .status' "$HIST" | tail -1)" "parked" "a parked row was appended to ticket-history.jsonl (#1 surfaced, not dropped)"

assert_done
