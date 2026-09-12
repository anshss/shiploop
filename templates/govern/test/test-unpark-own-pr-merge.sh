#!/usr/bin/env bash
# An un-parked ticket whose OWN open PR is in an auto-merge repo must be DRIVEN TO MERGE by the
# governor, never routed into the "waiting on PR" cross-run defer (which is for PRs a human / a
# different lane lands). Reproduces the observed failure: two un-parked, structurally-identical tickets
# (#1, #2) each with a green+MERGEABLE open alpha PR, where a prior run mis-routed #2 into a pending
# wait on its OWN PR. Hermetic + generic (alpha auto-merge, web frontend; org acme). Proves:
#   (A) helper: waits_refresh DROPS the wait for a ticket that owns an open PR in a GOVERN_MERGE_REPOS
#       repo (governor resumes+merges it), but KEEPS a wait whose PR the ticket does NOT own (frontend).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

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
assert_eq "$(printf '%s' "$out" | grep -c '^2	' || true)" "0" "#2's wait DROPPED — it owns alpha PR #201"
assert_contains "$out" "3	waiting on web PR #777" "#3's wait KEPT — frontend PR it does not own"
assert_eq "$(jq '.waits | length' "$HT/governor/pending-waits.json")" "1" "only the non-owned wait persists in the file"
assert_eq "$(jq -r '.waits[0].ticket' "$HT/governor/pending-waits.json")" "3" "the persisted wait is #3 (web), not #2 (alpha)"

unset GOVERN_WS_ROOT GOVERN_TICKETS_FILE GOVERN_PENDING_WAITS_FILE

assert_done
