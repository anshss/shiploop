#!/usr/bin/env bash
# The queue integrity guard: every script that commits queue/tickets.md refuses (exit 12) when the file
# already carries uncommitted changes it did not make, and never stashes, discards or commits them.
#   1. land-resolution.sh with a foreign uncommitted `## #N` block: exit 12, no commit, file byte-identical.
#   2. file-ticket.sh in commit mode: exit 12, nothing appended; GOVERN_FILE_TICKET_NO_COMMIT=1 unaffected.
#   3. resolve-ticket.sh refuses in a pre-flight, before the merge stub is ever called.
#   3b. a land-resolution.sh refusal AFTER a merge says "PR merged; queue not booked" and exits 12.
#   3c. a clean file proceeds through merge and land.
#   4. GOVERN_QUEUE_FOREIGN_GUARD=0 restores the old behavior (the foreign block rides in the commit).
#   5. escalations-apply-answers.sh refuses before applying any disposition.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

BK="$DIR/../land-resolution.sh"
FILE_TICKET="$DIR/../file-ticket.sh"
RT="$DIR/../resolve-ticket.sh"
APPLY="$DIR/../escalations-apply-answers.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_QUEUE_DIR="$T/queue"
export GOVERN_NO_PUSH=1
mkdir -p "$T/queue" "$T/governor" "$T/bin/lib"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
TF="$T/queue/tickets.md"

mk_queue() { cat > "$TF" <<'EOF'
# Tickets

## #1 — alpha

**Severity:** High

body one

---

## #5 — gamma

**Severity:** Low

body five

---
EOF
}
commit_all() { ( cd "$T" && git add -A >/dev/null 2>&1 && git commit -qm "$1" >/dev/null 2>&1 ); }
head_sha() { git -C "$T" rev-parse HEAD; }
file_sha() { shasum -a 256 "$TF" | cut -d' ' -f1; }
foreign_dirt() { printf '\n## #99 - written by a product runtime\n\n**Severity:** Low\n\nforeign body\n\n---\n' >> "$TF"; }
reset_clean() { mk_queue; rm -f "$T/governor/.ticket-seq"; commit_all "queue baseline"; }

RPT='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"u"},"newTickets":[],"lessonPatch":null}'

# ── 1. land-resolution.sh refuses on a foreign uncommitted block ─────────────────────────────────
reset_clean
foreign_dirt
before_head="$(head_sha)"; before_file="$(file_sha)"
out="$(printf '%s' "$RPT" | bash "$BK" 1 2>&1)"; rc=$?
assert_eq "$rc" "12" "1. land-resolution refuses with exit 12 on a foreign uncommitted block"
assert_eq "$(head_sha)" "$before_head" "1. ...and makes no commit"
assert_eq "$(file_sha)" "$before_file" "1. ...and leaves tickets.md byte-identical (nothing stashed, discarded or edited)"
assert_contains "$out" "uncommitted changes this script did not make" "1. the refusal text names the problem"
assert_contains "$out" "## #99" "1. ...and lists the foreign heading"
assert_eq "$(git -C "$T" stash list | wc -l | tr -d ' ')" "0" "1. ...and never stashes"
assert_eq "$([[ ! -d "$T/governor/.bookkeep.lock" ]] && echo released || echo held)" "released" "1. the bookkeep lock is released on refusal"

# ── 2. file-ticket.sh: refuses in commit mode, unaffected under NO_COMMIT ────────────────────────
before_head="$(head_sha)"; before_file="$(file_sha)"
out="$(printf 'body\n' | bash "$FILE_TICKET" "should not land" Low 2>&1)"; rc=$?
assert_eq "$rc" "12" "2. file-ticket (commit mode) refuses with exit 12"
assert_eq "$(file_sha)" "$before_file" "2. ...and appends nothing"
assert_eq "$(head_sha)" "$before_head" "2. ...and commits nothing"
assert_contains "$out" "uncommitted changes this script did not make" "2. file-ticket prints the refusal text"
out="$(printf 'body\n' | GOVERN_FILE_TICKET_NO_COMMIT=1 bash "$FILE_TICKET" "caller owns the commit" Low 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "2. GOVERN_FILE_TICKET_NO_COMMIT=1 is unaffected (the caller owns the commit and the check)"
assert_contains "$(cat "$TF")" "caller owns the commit" "2. ...and the block was appended"

# ── 3. resolve-ticket.sh: pre-flight refusal before any merge ────────────────────────────────────
cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"
[[ -f "$DIR/../post-merge-check.sh" ]] && cp "$DIR/../post-merge-check.sh" "$T/bin/"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$CALLS_LOG"
exit "${STUB_LAND_RC:-0}"
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
printf 'merge %s %s\n' "${1:-}" "${2:-}" >> "$CALLS_LOG"
exit 0
STUB
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *headRefName*) echo "stub-branch" ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin"/*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH"
export CALLS_LOG="$T/calls.log"
rt() { ( cd "$T" && printf '%s' "$RPT" | env "$@" bash "$T/bin/resolve-ticket.sh" 1 2>&1; echo "rc=$?" ); }

reset_clean; : > "$CALLS_LOG"
foreign_dirt
out="$(rt A=1)"
assert_contains "$out" "rc=12" "3. resolve-ticket refuses with exit 12 on a foreign uncommitted block"
assert_eq "$(grep -c '^merge' "$CALLS_LOG")" "0" "3. ...and the merge stub is never called (nothing merges)"
assert_eq "$(grep -c '^landed' "$CALLS_LOG")" "0" "3. ...and nothing is landed"
assert_contains "$out" "nothing was merged" "3. ...and says so"

# ── 3b. the race the pre-flight cannot close: land-resolution refuses after the merge ────────────
reset_clean; : > "$CALLS_LOG"
out="$(rt STUB_LAND_RC=12)"
assert_eq "$(grep -c '^merge' "$CALLS_LOG")" "1" "3b. a clean file merges"
assert_contains "$out" "PR merged; queue not booked" "3b. a post-merge refusal says the PR merged and the queue is not booked"
assert_contains "$out" "rc=12" "3b. ...and exits 12"
assert_contains "$out" "resolve-ticket.sh 1 --no-merge" "3b. ...and names the supported recovery (--no-merge)"

# ── 3c. a clean file proceeds through merge and land ─────────────────────────────────────────────
reset_clean; : > "$CALLS_LOG"
out="$(rt A=1)"
assert_contains "$out" "rc=0" "3c. a clean queue file resolves normally"
assert_eq "$(grep -c '^landed' "$CALLS_LOG")" "1" "3c. ...and lands exactly once"

# ── 4. GOVERN_QUEUE_FOREIGN_GUARD=0: the old behavior ────────────────────────────────────────────
reset_clean; : > "$CALLS_LOG"
foreign_dirt
out="$(rt GOVERN_QUEUE_FOREIGN_GUARD=0)"
assert_contains "$out" "rc=0" "4. guard off: resolve-ticket does not refuse"
assert_eq "$(grep -c '^merge' "$CALLS_LOG")" "1" "4. guard off: the merge happens"
reset_clean
foreign_dirt
printf '%s' "$RPT" | GOVERN_QUEUE_FOREIGN_GUARD=0 bash "$BK" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "4. guard off: land-resolution commits"
assert_contains "$(git -C "$T" show HEAD:queue/tickets.md)" "## #99" "4. guard off: the foreign block rides in the resolve commit (the old behavior)"

# ── 5. escalations-apply-answers.sh refuses before applying any disposition ──────────────────────
reset_clean
cat > "$T/escalations.md" <<'EOF'
# Escalations

## Open

### #5 — gamma
- **Reason:** parked
- **Question:** un-park?
- **Options:** do-the-work / defer
- **Answer:** retry it
- **Disposition:** do-the-work
- **Make this a rule?:** _(operator)_

## Resolved
EOF
printf '# Parked tickets\n\n---\n' > "$T/queue/tickets-parked.md"
printf '# Governor preferences\n' > "$T/preferences.md"
commit_all "escalation fixtures"
foreign_dirt
before_file="$(file_sha)"; before_head="$(head_sha)"
out="$(env GOVERN_TICKETS_FILE="$TF" GOVERN_TICKETS_PARKED_FILE="$T/queue/tickets-parked.md" \
  GOVERN_ESCALATIONS_FILE="$T/escalations.md" GOVERN_PREFERENCES_FILE="$T/preferences.md" \
  GOVERN_PENDING_FILE="$T/pending.json" bash "$APPLY" 2>&1)"; rc=$?
assert_eq "$rc" "12" "5. apply-answers refuses with exit 12 on a foreign uncommitted block"
assert_eq "$(file_sha)" "$before_file" "5. ...and leaves tickets.md byte-identical"
assert_eq "$(head_sha)" "$before_head" "5. ...and commits nothing"

assert_done
