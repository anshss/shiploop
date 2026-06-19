#!/usr/bin/env bash
# #120 — a ticket auto-skipped as NOT-govern-automatable for K consecutive runs must surface a
# ONE-TIME escalation recommending the operator escalate+defer it permanently (→ tickets-parked.md),
# instead of churning a skip note every run forever. Proves:
#   (1) below the threshold (runs 1..K-1) → NO escalation filed, just the per-run skip note;
#   (2) at the K-th consecutive auto-skip → exactly ONE escalation filed under "## Open" carrying a
#       Disposition field (so escalations-apply-answers can act) and recommending 'defer';
#   (3) it is ONE-TIME — a subsequent run does NOT re-file while the prior recommendation is open;
#   (4) the streak RESETS when the ticket is no longer NA (un-marked), so no stale nudge later.
# Sandboxed: only the lone NA ticket is in the queue, so no worker/supervisor is ever spawned.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

# A single NOT-automatable ticket → the only ticket in the queue → no eligible work, the loop just
# does the run-start NA scan and stops. (#92 selector excludes it; we exercise the #120 nudge.)
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #45 — container image build
**Severity:** Low — build the container image.
**NOT govern-automatable:** needs a real builder host. Handle interactively.
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
( cd "$T" && git add -A && git commit -qm init )

# stub gh: never an open PR; any other query → harmless empty.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]';; *) echo '[]';; esac
EOF
chmod +x "$T/bin/gh"

run_loop() {
  PATH="$T/bin:$PATH" \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
    GOVERN_PENDING_FILE="$T/governor/pending-escalations.json" \
    GOVERN_TICKETS_PARKED_FILE="$T/tickets-parked.md" \
    GOVERN_PREFERENCES_FILE="$REPO/governor/preferences.md" \
    GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
    GOVERN_NA_SKIP_FILE="$T/governor/na-skip-counts.json" \
    GOVERN_LOCK="$T/lock" \
    GOVERN_NA_NUDGE_AFTER=3 \
    GOVERN_NO_PUSH=1 GOVERN_IMPROVE=0 \
    bash "$RL" 2>&1
}

open_count() { # how many open ### #45 escalations
  grep -cE '^### +#45([^0-9]|$)' "$T/governor/escalations.md" 2>/dev/null || true
}

# Runs 1 and 2 — below the K=3 threshold → skip note but NO escalation yet.
out1="$(run_loop)"; assert_contains "$out1" "auto-skipping #45" "run 1: #45 auto-skipped + logged (#92)"
assert_eq "$(open_count)" "0" "run 1: below threshold → no permanent-park escalation yet"
run_loop >/dev/null 2>&1
assert_eq "$(open_count)" "0" "run 2: still below threshold → no escalation"
cnt="$(jq -r '.counts["45"] // 0' "$T/governor/na-skip-counts.json" 2>/dev/null)"
assert_eq "$cnt" "2" "consecutive-skip count persisted across runs (2 after run 2)"

# Run 3 — the K-th consecutive auto-skip → fire the one-time nudge.
out3="$(run_loop)"
assert_contains "$out3" "filing a one-time escalation to PERMANENTLY remove it" "run 3: K-th skip fires the nudge (#120)"
assert_eq "$(open_count)" "1" "run 3: exactly one permanent-park escalation filed"
block="$(awk '/^### +#45/{g=1} g{print} g&&/^### +#[0-9]+/&&!f{f=1;next} g&&/^- \*\*Make this a rule/{exit}' "$T/governor/escalations.md")"
assert_contains "$block" "**Disposition:**" "escalation carries a Disposition field (apply-answers can act)"
assert_contains "$block" "defer" "escalation recommends 'defer' (permanent removal)"

# Run 4 — ONE-TIME: the recommendation is still open + unanswered → do NOT re-file.
out4="$(run_loop)"
assert_eq "$(open_count)" "1" "run 4: still exactly one escalation (one-time; not re-noted)"

# Un-mark the ticket (no longer NA) → the streak must reset, so it never fires a stale nudge later.
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #45 — container image build
**Severity:** Low — now resolvable.
body
EOF
run_loop >/dev/null 2>&1
reset="$(jq -r 'has("counts") and (.counts | has("45"))' "$T/governor/na-skip-counts.json" 2>/dev/null)"
assert_eq "$reset" "false" "streak reset once #45 is no longer NA (no stale count left)"

assert_done
