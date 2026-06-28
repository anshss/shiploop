#!/usr/bin/env bash
# #191 — an un-parked ticket whose OWN open PR is in an auto-merge repo must be DRIVEN TO MERGE by the
# governor, never routed into the #119 "waiting on PR" cross-run defer (which is for PRs a human / a
# different lane lands). Reproduces the observed failure: two un-parked, structurally-identical tickets
# (#1, #2) each with a green+MERGEABLE open alpha PR, where a prior run mis-routed #2 into a pending
# wait on its OWN PR. Hermetic + generic (alpha auto-merge, web frontend; org acme). Proves:
#   (A) helper: waits_refresh DROPS the wait for a ticket that owns an open PR in a GOVERN_MERGE_REPOS
#       repo (governor resumes+merges it), but KEEPS a wait whose PR the ticket does NOT own (frontend).
#   (B) end-to-end: across ONE pass the governor merges BOTH — resuming #1, then resolving the
#       interdependent #2 by re-dispatching a conflict-resolution worker (the 2nd PR conflicts once the
#       1st lands) and re-merging. No ticket left in a permanent "waiting on PR" defer; no manual merge.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ── (A) helper-layer: waits_refresh own-PR-in-merge-repo discriminator ────────
HT="$(mktemp -d)"; trap 'rm -rf "$HT"' EXIT
mk_ws_stub "$HT"   # alpha auto-mergeable, web frontend PR-only
mkdir -p "$HT/governor" "$HT/bin"
cat > "$HT/tickets.md" <<'EOF'
# Tickets
---
## #1 — owns an alpha PR
**Severity:** High — x.
body
---
## #2 — owns an alpha PR (mis-routed into a wait)
**Severity:** High — y.
body
---
## #3 — waits on a web PR it does NOT own
**Severity:** Medium — frontend, human merges.
body
EOF

# gh stub: alpha `pr list` advertises ticket-1→101 + ticket-2→201 (both own PRs in an auto-merge repo);
# web `pr list` advertises a PR on a DIFFERENT head (ticket-3 owns nothing); all else empty.
# `pr view N` → OPEN (state checks for waits the ticket doesn't own).
cat > "$HT/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*alpha*) echo '[{"number":101,"url":"http://o/101","headRefName":"ticket-1"},{"number":201,"url":"http://o/201","headRefName":"ticket-2"}]';;
  *"pr list"*web*)   echo '[{"number":777,"url":"http://c/777","headRefName":"some-other-branch"}]';;
  *"pr list"*)       echo '[]';;
  *"pr view"*)       echo OPEN;;
  *)                 echo '[]';;
esac
EOF
chmod +x "$HT/bin/gh"

export GOVERN_WS_ROOT="$HT" GOVERN_TICKETS_FILE="$HT/tickets.md" \
       GOVERN_PENDING_WAITS_FILE="$HT/governor/pending-waits.json"
PATH="$HT/bin:$PATH"
source "$DIR/../lib/common.sh"

# #2 mis-routed into a wait on its OWN alpha PR #201; #3 waits on web PR #777 it does NOT own.
printf '{"waits":[{"ticket":2,"pr":201,"repo":"alpha"},{"ticket":3,"pr":777,"repo":"web"}]}\n' \
  > "$HT/governor/pending-waits.json"
out="$(govern::waits_refresh)"
assert_eq "$(printf '%s' "$out" | grep -c '^2	' || true)" "0" "#2's wait DROPPED — it owns alpha PR #201 (#191)"
assert_contains "$out" "3	waiting on web PR #777" "#3's wait KEPT — frontend PR it does not own"
assert_eq "$(jq '.waits | length' "$HT/governor/pending-waits.json")" "1" "only the non-owned wait persists in the file"
assert_eq "$(jq -r '.waits[0].ticket' "$HT/governor/pending-waits.json")" "3" "the persisted wait is #3 (web), not #2 (alpha)"

unset GOVERN_WS_ROOT GOVERN_TICKETS_FILE GOVERN_PENDING_WAITS_FILE

# ── (B) end-to-end: both un-parked tickets merged across one pass ─────────────
TB="$(mktemp -d)"; trap 'rm -rf "$HT" "$TB"' EXIT
mk_ws_stub "$TB"
mkdir -p "$TB/bin" "$TB/governor" "$TB/logs" "$TB/wt"
( cd "$TB" && git init -q && git config user.email t@t && git config user.name t )
printf '## Open\n\n## Resolved\n' > "$TB/governor/escalations.md"
printf 'DOC\n' > "$TB/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TB/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$TB/governor/supervisor-prompt.md"
cat > "$TB/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TB/wt/\$1"; echo "$TB/wt/\$1"
EOF
chmod +x "$TB/wt.sh"

cat > "$TB/tickets.md" <<'EOF'
# Tickets
---
## #1 — un-parked, owns alpha PR 101
**Severity:** High — x.
body1
---
## #2 — un-parked, owns alpha PR 201 (mis-routed into a wait; conflicts after #1 lands)
**Severity:** High — y.
body2
EOF
# A prior run mis-routed #2 into a wait on its OWN alpha PR.
printf '{"waits":[{"ticket":2,"pr":201,"repo":"alpha"}]}\n' > "$TB/governor/pending-waits.json"

# gh stub. PR 101 merges cleanly. PR 201 CONFLICTS (merge fails) until the conflict-resolution worker
# flips $TB/resolved201; update-branch "succeeds" (stale-base retry) but the merge still fails — only a
# real resolve clears it. `pr checks` → green. `pr view` → headRefName/state for merge bookkeep.
cat > "$TB/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr list"*alpha*) echo '[{"number":101,"url":"http://o/101","headRefName":"ticket-1"},{"number":201,"url":"http://o/201","headRefName":"ticket-2"}]';;
  *"pr list"*)      echo '[]';;
  *"pr merge 101"*) echo 'merged 101';  exit 0;;
  *"pr merge 201"*) if [[ -f "$TB/resolved201" ]]; then echo 'merged 201'; exit 0; else echo 'X not mergeable: merge conflict' >&2; exit 1; fi;;
  *"pr update-branch"*) exit 0;;
  *"pr checks"*)    echo '[{"bucket":"pass"}]';;
  *"pr view 101"*headRefName*) echo 'ticket-1';;
  *"pr view 201"*headRefName*) echo 'ticket-2';;
  *"pr view"*)      echo OPEN;;
  *)                echo '[]';;
esac
EOF
chmod +x "$TB/bin/gh"

# claude stub: supervisor → ok; conflict-resolver (GOVERN_RESOLVE_CONFLICT set) → flip the state file +
# report resolved with the existing PR; plain worker → resolve normally (unused — resume covers both).
cat > "$TB/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
if printf '%s' "\$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "\$(printf '{"verdict":"ok","concerns":[],"skipThisRun":[],"waitForMerge":[],"attemptNext":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="\$(printf '%s' "\${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
if [[ -n "\${GOVERN_RESOLVE_CONFLICT:-}" ]]; then
  touch "$TB/resolved201"   # the worker merged origin/main + resolved the conflict + pushed
  report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":201,\"url\":\"http://o/201\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
else
  report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":\${n}01,\"url\":\"http://o/\${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
fi
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
chmod +x "$TB/bin/claude"

out="$(PATH="$TB/bin:$PATH" \
  GOVERN_TICKETS_FILE="$TB/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$TB/governor/escalations.md" \
  GOVERN_PENDING_FILE="$TB/governor/pending-escalations.json" \
  GOVERN_PENDING_WAITS_FILE="$TB/governor/pending-waits.json" \
  GOVERN_WORKER_PROMPT_FILE="$TB/governor/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$TB/governor/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$TB/governor/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$TB/logs" \
  GOVERN_TICKET_SEQ_FILE="$TB/.ticket-seq" \
  GOVERN_LOCK="$TB/lock" \
  GOVERN_WORKTREE_CMD="$TB/wt.sh" \
  GOVERN_CLAUDE_BIN="$TB/bin/claude" \
  GOVERN_NO_PUSH=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
  bash "$RL" </dev/null 2>&1)"

# #2's wait is cleared at run-start (it owns an auto-merge-repo PR), so it is NOT deferred.
assert_contains "$out" "ticket owns open alpha PR #201 in an auto-merge repo" "#2 NOT deferred — governor owns its PR (#191)"
assert_contains "$out" "found existing PR alpha#101 for #1 — resuming" "#1 resumed from its existing PR"
assert_contains "$out" "found existing PR alpha#201 for #2 — resuming" "#2 resumed from its existing PR (not deferred)"
# #1 merges cleanly; #2 conflicts after #1 lands → conflict-resolution re-dispatch → merges.
assert_contains "$out" "merged alpha#101 (#1)" "#1's PR merged"
assert_contains "$out" "re-dispatching a worker to merge origin/main + resolve" "#2 conflict → rebase re-dispatch (#191)"
assert_contains "$out" "merged alpha#201 (#2)" "#2's PR merged after conflict resolution"
# Both resolved out of tickets.md; the mis-routed wait is gone; nothing left for a human.
assert_eq "$(grep -cE '^## #1 ' "$TB/tickets.md" || true)" "0" "#1 resolved out of tickets.md"
assert_eq "$(grep -cE '^## #2 ' "$TB/tickets.md" || true)" "0" "#2 resolved out of tickets.md"
assert_eq "$(jq '.waits | length' "$TB/governor/pending-waits.json" 2>/dev/null || echo 0)" "0" "no pending wait left — nothing deferred for a human"
assert_contains "$out" "resolved=2" "both un-parked tickets merged+resolved in one pass"

assert_done
