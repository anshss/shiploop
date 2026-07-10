#!/usr/bin/env bash
# Regression for #129: a worker for a MULTI-REPO ticket can open N PRs, but the resolved path used to
# act only on the single reported `report.pr` — so sibling PRs were orphaned unmerged. The fix:
# collect EVERY PR for the ticket (reported `.pr`/`.prs[]` UNION every open `ticket-<N>` head
# discovered across all repos), merge every auto-merge-repo PR backend-first on green/none, and leave
# frontend siblings open but SURFACED in the summary — never silently dropped.
#
# Hermetic + generic (alpha/api auto-merge, web frontend; org acme). Proves:
#   A. DISCOVERY — the worker reports only ONE PR (alpha#66) but ALSO opened api#281 + web#266; the
#      harness discovers + merges both auto-merge-repo PRs and leaves the frontend (web) open.
#   B. BACKEND-FIRST — alpha merges before api (merge-repo-first ordering), and both before web.
#   C. SURFACED — the resolved state note lists every PR with its disposition.
#   D. UNIT — govern::collect_ticket_prs honors the explicit `.prs[]` field, deduped + backend-first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha,api"   # alpha + api auto-mergeable; web is the frontend PR-only repo
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — multi-repo one
**Severity:** Medium — touches alpha + api + web.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'DOCTRINE\n' > "$T/governor/preferences.md"
printf 'WORKER {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

# stub gh: `pr list` per-repo returns open ticket-1 heads on alpha + api + web (the three repos the
# multi-repo worker touched); every other repo → none. `pr checks` → all pass. The merge runs through
# merge-pr.sh in GOVERN_ECHO mode, so `pr merge` is never actually invoked.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"pr list"* ]]; then
  case "$args" in
    *acme/alpha*) echo '[{"number":281,"url":"http://pr/281","headRefName":"ticket-1"}]';;
    *acme/api*)   echo '[{"number":66,"url":"http://pr/66","headRefName":"ticket-1"}]';;
    *acme/web*)   echo '[{"number":266,"url":"http://pr/266","headRefName":"ticket-1"}]';;
    *)            echo '[]';;
  esac
  exit 0
fi
# pr checks (await-ci) → all green
echo '[{"bucket":"pass"}]'
EOF
chmod +x "$T/bin/gh"

# stub claude: supervisor verdict on the marker; else a worker that reports ONLY api#66 (it
# under-reports its sibling PRs). The harness must discover the rest itself.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
report='{"status":"resolved","pr":{"repo":"api","number":66,"url":"http://pr/66"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":null,"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_HISTORY_FILE="$T/history.jsonl" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" 1 2>&1)"

# A. discovery + merge of BOTH auto-merge siblings (one of which the worker never reported)
assert_contains "$out" "merged alpha#281" "discovered + merged alpha sibling (#129)"
assert_contains "$out" "merged api#66"    "merged the reported api PR (#129)"
# B. frontend sibling (web) left open, SURFACED (not silently dropped)
assert_contains "$out" "web#266 left open (frontend is PR-only)" "frontend sibling left open + surfaced (#129)"
# C. alpha merges BEFORE api (merge-repo-first: alpha precedes api in REPOS)
apos="$(printf '%s' "$out" | grep -n 'merged alpha#281' | head -1 | cut -d: -f1)"
ipos="$(printf '%s' "$out" | grep -n 'merged api#66' | head -1 | cut -d: -f1)"
[[ -n "$apos" && -n "$ipos" && "$apos" -lt "$ipos" ]] && bo=ok || bo="alpha=$apos api=$ipos"
assert_eq "$bo" "ok" "alpha PR merged before api PR (merge-repo-first ordering)"
# ticket resolved + block deleted (the whole multi-repo change shipped)
assert_contains "$out" "resolved=1" "multi-repo ticket counted resolved"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "0" "ticket #1 block deleted on full resolve"
# the resolved state note lists EVERY PR + disposition
note="$(jq -r 'select(.ticket==1).note' "$T"/logs/run-*/state.jsonl 2>/dev/null || true)"
assert_contains "$note" "alpha#281(merged)"        "state note records alpha merge"
assert_contains "$note" "api#66(merged)"           "state note records api merge"
assert_contains "$note" "web#266(frontend-left-open)" "state note records frontend left-open"

# D. UNIT — govern::collect_ticket_prs honors the explicit `.prs[]` field (a worker that DOES report
# all its PRs), deduped against `.pr` and ordered backend-first, even when gh discovery finds nothing.
# Use a no-op gh (in a subshell) so find_all_prs returns empty.
mkdir -p "$T/bin2"; printf '#!/usr/bin/env bash\necho "[]"\n' > "$T/bin2/gh"; chmod +x "$T/bin2/gh"
unit_rep='{"pr":{"repo":"api","number":66,"url":"u66"},"prs":[{"repo":"alpha","number":281,"url":"u281"},{"repo":"web","number":266,"url":"u266"},{"repo":"api","number":66,"url":"u66"}]}'
got="$( PATH="$T/bin2:$PATH"; source "$DIR/../lib/common.sh"; govern::collect_ticket_prs 1 "$unit_rep" | awk -F'\t' '{printf "%s#%s ",$1,$2}' )"
assert_eq "$got" "alpha#281 api#66 web#266 " "collect_ticket_prs: .prs[] honored, deduped, backend-first"
assert_done
