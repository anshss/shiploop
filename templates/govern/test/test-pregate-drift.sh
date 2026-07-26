#!/usr/bin/env bash
# Deterministic pre-dispatch UPSTREAM-DRIFT gate (lib/pregate.sh).
#
# The gate's whole value rests on its DIRECTION test — a bare "live != template" would fire on
# every unported local improvement and stall real tickets. These cases pin both directions plus
# every fail-open path, because a false positive (wrongly parking a workable ticket) is strictly
# worse than a false negative (paying for one avoidable session).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/ws"
TPLROOT="$SANDBOX/hub/templates"
TPL="$TPLROOT/govern"
mkdir -p "$REPO/scripts/govern" "$REPO/queue" "$TPL"

# The live harness copy of sync-templates.sh IS the real one under test — the gate calls it.
cp "$DIR/../sync-templates.sh" "$REPO/scripts/govern/sync-templates.sh"
chmod +x "$REPO/scripts/govern/sync-templates.sh"
cp "$DIR/../sync-templates.sh" "$TPL/sync-templates.sh"

printf 'v1 shared\n' > "$REPO/scripts/govern/merge-pr.sh"
printf 'v1 shared\n' > "$TPL/merge-pr.sh"
printf 'v1 shared\n' > "$REPO/scripts/govern/await-ci.sh"
printf 'v1 shared\n' > "$TPL/await-ci.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
MARK="$(git -C "$REPO" rev-parse HEAD)"
{ echo "# marker"; echo "$MARK"; } > "$REPO/scripts/govern/.templates-synced-at"

TICKETS="$REPO/queue/tickets.md"
cat > "$TICKETS" <<'EOF'
## Open

## #1 — hub is ahead on this one

**Severity:** Medium

Where: `scripts/govern/merge-pr.sh`

Observed: something.

---

## #2 — workspace has unported local work here

**Severity:** Medium

Where: `scripts/govern/await-ci.sh`

Observed: something.

---

## #3 — nothing to do with the harness

**Severity:** Medium

Where: `src/app/page.tsx`

Observed: something.

---
EOF

export GOVERN_TICKETS_FILE="$TICKETS"
export GOVERN_PREGATE_LIVE_ROOT="$REPO"
export GOVERN_PREGATE_SYNC_TOOL="$REPO/scripts/govern/sync-templates.sh"
export GOVERN_TEMPLATE_DIR="$TPL"
export GOVERN_DIR="$REPO/scripts/govern"

# govern::ticket_block comes from common.sh, but common.sh sources workspace.sh and asserts a
# whole workspace layout. Source just the two helpers the gate depends on, hermetically.
TICKETS_FILE="$TICKETS"
eval "$(sed -n '/^govern::ticket_block() {/,/^}/p' "$DIR/../lib/common.sh")"
source "$DIR/../lib/pregate.sh"

# ── 1. HUB AHEAD: workspace untouched since the marker, template diverged ────────────────────
printf 'v2 fixed upstream\n' > "$TPL/merge-pr.sh"
out="$(govern::pregate_hub_ahead 1 "$TICKETS" || true)"
assert_contains "$out" "scripts/govern/merge-pr.sh" "hub-ahead file is surfaced"
assert_contains "$out" "$TPL/merge-pr.sh" "the template counterpart path is reported for the diff"
assert_eq "$(printf '%s' "$out" | grep -c .)" "1" "exactly one pair surfaced"

# ── 2. WORKSPACE AHEAD: unported LOCAL change — must NOT fire (this is normal drift) ─────────
printf 'v2 local improvement\n' > "$REPO/scripts/govern/await-ci.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "local improvement to await-ci"
out="$(govern::pregate_hub_ahead 2 "$TICKETS" || true)"
assert_eq "$out" "" "unported LOCAL drift never trips the gate"

# ── 3. IN SYNC: identical files → nothing to surface ─────────────────────────────────────────
cp "$TPL/merge-pr.sh" "$REPO/scripts/govern/merge-pr.sh"
out="$(govern::pregate_hub_ahead 1 "$TICKETS" || true)"
assert_eq "$out" "" "identical live/template pair does not fire"
printf 'v2 fixed upstream\n' > "$TPL/merge-pr.sh"      # re-diverge for the remaining cases
printf 'v1 shared\n' > "$REPO/scripts/govern/merge-pr.sh"

# ── 4. OUT OF SCOPE: a Where: outside the mirrored harness areas is ignored outright ─────────
out="$(govern::pregate_hub_ahead 3 "$TICKETS" || true)"
assert_eq "$out" "" "a product-repo Where: is never considered"

# ── 5. KILL SWITCH ───────────────────────────────────────────────────────────────────────────
out="$(GOVERN_PREGATE_DRIFT=0 govern::pregate_hub_ahead 1 "$TICKETS" || true)"
assert_eq "$out" "" "GOVERN_PREGATE_DRIFT=0 makes the gate inert"

# ── 6. FAIL-OPEN: no sync marker → direction is unknowable → emit nothing, spawn as usual ────
mv "$REPO/scripts/govern/.templates-synced-at" "$SANDBOX/marker.bak"
out="$(govern::pregate_hub_ahead 1 "$TICKETS" || true)"
assert_eq "$out" "" "missing sync marker fails OPEN (no false park)"
mv "$SANDBOX/marker.bak" "$REPO/scripts/govern/.templates-synced-at"

# ── 7. FAIL-OPEN: sync-templates.sh unavailable ──────────────────────────────────────────────
out="$(GOVERN_PREGATE_SYNC_TOOL="$SANDBOX/nope.sh" govern::pregate_hub_ahead 1 "$TICKETS" || true)"
assert_eq "$out" "" "missing sync-templates.sh fails OPEN"

# ── 8. FAIL-OPEN: unmirrored harness path (no template counterpart) ──────────────────────────
printf 'workspace-only\n' > "$REPO/scripts/govern/deploy-check.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "workspace-only script"
cat >> "$TICKETS" <<'EOF'

## #4 — workspace-only script

**Severity:** Medium

Where: `scripts/govern/deploy-check.sh`

---
EOF
out="$(govern::pregate_hub_ahead 4 "$TICKETS" || true)"
assert_eq "$out" "" "a live file with no template counterpart never fires"

# ── 9. Path extraction rejects globs, traversal and shell interpolations ─────────────────────
cat >> "$TICKETS" <<'EOF'

## #5 — fuzzy where

**Severity:** Medium

Where: `scripts/govern/*.sh`, `$WORKTREE_BASE/ticket-N`, `scripts/../scripts/govern/merge-pr.sh`

---
EOF
out="$(govern::pregate_where_paths 5 "$TICKETS" || true)"
assert_eq "$out" "" "globs, \$VAR interpolations and ../ traversal are all dropped"

# ── 10. sync-templates.sh --counterpart / --paths contracts ──────────────────────────────────
out="$(bash "$REPO/scripts/govern/sync-templates.sh" --counterpart scripts/govern/merge-pr.sh || true)"
assert_eq "$out" "$TPL/merge-pr.sh" "--counterpart maps a live path to its template"
rc=0
bash "$REPO/scripts/govern/sync-templates.sh" --counterpart scripts/govern/deploy-check.sh >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "--counterpart exits 1 on an unmirrored path"
rc=0
out="$(bash "$REPO/scripts/govern/sync-templates.sh" --paths)" || rc=$?
assert_contains "$out" "scripts/govern/await-ci.sh" "--paths lists unported local drift as a bare path"
assert_eq "$rc" "0" "--paths exits 0 when it CAN answer — the gate reads rc!=0 as 'unknowable' and disarms"

# The rc contract again, on the shape that used to leak a stray 1: a commit whose LAST changed
# file is unmirrored. Answerable ("no unported drift on mirrored files"), so rc must stay 0 —
# otherwise every such workspace would silently fail the gate open forever.
printf 'local-only\n' > "$REPO/scripts/govern/zz-unmirrored.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "unmirrored tail"
rc=0
bash "$REPO/scripts/govern/sync-templates.sh" --paths >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "--paths exits 0 even when the last changed file has no template counterpart"
rm -f "$REPO/scripts/govern/zz-unmirrored.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "revert unmirrored tail"

assert_done
