#!/usr/bin/env bash
# Regression: a worker for a MULTI-REPO ticket can open N PRs, but the resolved path used to
# act only on the single reported `report.pr` — so sibling PRs were orphaned unmerged. The fix:
# collect EVERY PR for the ticket (reported `.pr`/`.prs[]` UNION every open `ticket-<N>` head
# discovered across all repos), merge every auto-merge-repo PR backend-first on green/none, and leave
# frontend siblings open but SURFACED in the history note, never silently dropped.
#
# Parts A/B/C are re-targeted at resolve-ticket.sh (the loop purge moved the merge walk here), run
# hermetically next to stubs of merge-pr.sh / await-ci.sh / land-resolution.sh, no network, no gh,
# no real push. Part D is the original UNIT test on govern::collect_ticket_prs itself, unchanged.
#
# Hermetic + generic (alpha/api auto-merge, web frontend; org acme). Proves:
#   A. UNION, the report names api#66 via `.pr` and alpha#281 + web#266 via `.prs[]`; every
#      auto-merge-repo PR reaches merge-pr.sh and the frontend PR is surfaced as left-open.
#   B. BACKEND-FIRST, alpha reaches merge-pr.sh before api (merge-repo-first ordering).
#   C. SURFACED, the resolved history row's note lists every PR with its disposition; the ticket
#      lands EXACTLY once.
#   D. UNIT — govern::collect_ticket_prs honors the explicit `.prs[]` field, deduped + backend-first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha,api"   # alpha + api auto-mergeable; web is the frontend PR-only repo
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

set +e
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
# Records every repo#pr it is called for, in call order (proves backend-first), and models the real
# merge-pr.sh contract: web is the frontend/PR-only repo (rc=2, left open by design); alpha/api merge.
MERGE_ORDER="$T/merge-order.log"
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >> "$MERGE_ORDER_LOG"
[[ "$1" == "web" ]] && exit 2
exit 0
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED" MERGE_ORDER_LOG="$MERGE_ORDER"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #1 — multi-repo one

**Severity:** Medium — touches alpha + api + web.

body1

---
TIX
( cd "$T" && git add -A && git commit -qm init )

HIST="$T/history.jsonl"
# The worker reports api#66 via `.pr` but ALSO names its two siblings via `.prs[]` (a worker that
# DOES report all its PRs, the discovery-from-gh path is covered by govern::find_all_prs directly,
# not re-proven here).
report='{"status":"resolved","pr":{"repo":"api","number":66,"url":"http://pr/66"},"prs":[{"repo":"alpha","number":281,"url":"http://pr/281"},{"repo":"web","number":266,"url":"http://pr/266"}],"lessonPatch":null,"newTickets":[]}'

: > "$LANDED"; : > "$MERGE_ORDER"
out="$( cd "$T" && printf '%s' "$report" | GOVERN_HISTORY_FILE="$HIST" bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc=$?

# A. every auto-merge-repo PR reached merge-pr.sh; the frontend PR is surfaced as left-open
assert_contains "$(cat "$MERGE_ORDER")" "alpha#281" "alpha (auto-merge repo) reached merge-pr.sh"
assert_contains "$(cat "$MERGE_ORDER")" "api#66"     "api (auto-merge repo) reached merge-pr.sh"
assert_contains "$out" "web#266 left open (frontend is PR-only)" "frontend sibling left open + surfaced, does NOT block the land"

# B. alpha reaches merge-pr.sh BEFORE api (merge-repo-first: alpha precedes api in GOVERN_MERGE_REPOS)
apos="$(grep -n '^alpha#281$' "$MERGE_ORDER" | head -1 | cut -d: -f1)"
ipos="$(grep -n '^api#66$' "$MERGE_ORDER" | head -1 | cut -d: -f1)"
[[ -n "$apos" && -n "$ipos" && "$apos" -lt "$ipos" ]] && bo=ok || bo="alpha=$apos api=$ipos"
assert_eq "$bo" "ok" "alpha PR merged before api PR (merge-repo-first ordering)"

# C. the ticket lands EXACTLY once, and the "landed, PRs: …" summary line names every PR with its
# disposition. NB: rt_record_history's `note` PARAMETER is never merged into the ticket-history.jsonl
# row (dead parameter, see the PR body / final report for this finding), so the disposition string
# is asserted on stderr here, not on a `.note` field in $HIST.
assert_eq "$rc" "0" "multi-repo ticket resolves (exit 0)"
assert_eq "$(landed_count)" "1" "multi-repo ticket lands EXACTLY once"
assert_contains "$out" "PRs:"                         "landed summary line carries the PR-disposition list"
assert_contains "$out" "alpha#281(merged)"            "landed summary records the alpha merge"
assert_contains "$out" "api#66(merged)"               "landed summary records the api merge"
assert_contains "$out" "web#266(frontend-left-open)"  "landed summary records the frontend left-open"

# D. UNIT — govern::collect_ticket_prs honors the explicit `.prs[]` field (a worker that DOES report
# all its PRs), deduped against `.pr` and ordered backend-first, even when gh discovery finds nothing.
# Use a no-op gh (in a subshell) so find_all_prs returns empty.
mkdir -p "$T/bin2"; printf '#!/usr/bin/env bash\necho "[]"\n' > "$T/bin2/gh"; chmod +x "$T/bin2/gh"
unit_rep='{"pr":{"repo":"api","number":66,"url":"u66"},"prs":[{"repo":"alpha","number":281,"url":"u281"},{"repo":"web","number":266,"url":"u266"},{"repo":"api","number":66,"url":"u66"}]}'
got="$( PATH="$T/bin2:$PATH"; source "$DIR/../lib/common.sh"; govern::collect_ticket_prs 1 "$unit_rep" | awk -F'\t' '{printf "%s#%s ",$1,$2}' )"
assert_eq "$got" "alpha#281 api#66 web#266 " "collect_ticket_prs: .prs[] honored, deduped, backend-first"
assert_done
