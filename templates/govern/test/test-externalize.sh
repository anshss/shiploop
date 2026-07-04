#!/usr/bin/env bash
# Externalization lane: eligibility (Low + OSS sub-repo), the substring-sibling trap, the severity
# gate, dry-run no-op, the happy path (file → remove block → ledger), idempotency heal, leak-guard,
# label-permission rejection surfacing, and the OFF-when-unconfigured skip. gh is stubbed via a fake
# on PATH so no network call is ever made.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"
SCRIPT="$DIR/../externalize-low-tickets.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake gh: canned label set on `label list`, and on `issue create` counts the call, records argv, and
# prints the canned issue URL. When GH_LABEL_REJECT=1 it also emits the composite-op label rejection
# on stderr while still exiting 0 with the URL (mimicking a pull-only account).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "label" && "$2" == "list" ]]; then
  printf '%s\n' "good first issue" "help wanted" "bug" "enhancement" "documentation"
  exit 0
fi
printf 'CALL\n' >> "$GH_COUNT"
printf '%s\n' "$*" >> "$GH_CALLS"
echo "https://github.com/acme/foo/issues/999"
if [[ "${GH_LABEL_REJECT:-0}" == "1" && "$1" == "issue" && "$2" == "create" ]]; then
  echo 'failed to update https://github.com/acme/foo/issues/999: GraphQL: user does not have the correct permissions to execute `AddLabelsToLabelable` (addLabelsToLabelable)' >&2
fi
EOF
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/gh-calls.log"
export GH_COUNT="$TMP/gh-count.log"
: > "$GH_CALLS"; : > "$GH_COUNT"

# Custom workspace stub: REPOS = (foo foo-website web) so we can exercise the substring-sibling
# trap where a Where line references `foo-website` — the eligibility check must NOT count that as
# targeting `foo`. Plain mk_ws_stub only supports (alpha web), which can't express the trap.
mk_ext_ws_stub() {
  local root="$1"
  export GOVERN_WS_ROOT="$root"
  mkdir -p "$root/scripts/lib" "$root/queue"
  cat > "$root/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$root}"
GITHUB_ORG="acme"
REPOS=(foo foo-website web)
GOVERN_MERGE_REPOS=""
GOVERN_LOCAL_FIRST_REPOS=""
WORKTREE_BASE="$root/wt"
wsp_is_merge_repo() { return 1; }
wsp_is_local_first_repo() { return 1; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
}

mk_ext_ws_stub "$TMP"

# Shared env for every invocation: temp tickets + ledger, the OSS slug/name, no push (temp dir isn't
# a git repo anyway), fake gh first on PATH.
export GOVERN_TICKETS_FILE="$TMP/tickets.md"
export GOVERN_EXTERNALIZED_FILE="$TMP/externalized.md"
export GOVERN_EXTERNALIZE_REPO="acme/foo"
export GOVERN_EXTERNALIZE_SUBREPO="foo"
export GOVERN_EXTERNALIZE_LANE="1"
export GOVERN_NO_PUSH="1"
export PATH="$TMP/bin:$PATH"

write_fixture() {
  cat > "$TMP/tickets.md" <<'EOF'
## #1 — low foo thing

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/core/x.py`
**Observed:** something small.
**Done when:** fixed.

---

## #2 — low website thing

**Severity:** Low — minor.
**Where:** `foo-website` sub-repo — hero copy tweak.
**Observed:** a typo.

---

## #3 — medium foo thing

**Severity:** Medium — meh.
**Where:** `foo` sub-repo — `foo/api.py`

---

## #4 — low, no where field

**Severity:** Low — minor.
**Observed:** has no Where line at all.

---
EOF
  rm -f "$TMP/externalized.md"
}

# ── 1. Eligibility helper: ONLY #1 (Low + foo). #2 is the sibling trap, #3 Medium, #4 no Where.
write_fixture
cands="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" bash -c 'source "'"$COMMON"'"; govern::externalize_candidates "'"$TMP/tickets.md"'"')"
assert_eq "$cands" "1" "candidates = Low+foo only (excludes sibling trap, Medium, no-Where)"

# ── 2. Dry-run: no gh call, tickets.md unchanged, no ledger written.
write_fixture
before="$(cat "$TMP/tickets.md")"
"$SCRIPT" --dry >/dev/null 2>&1
assert_eq "$(cat "$TMP/tickets.md")" "$before" "dry-run leaves tickets.md byte-identical"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "dry-run makes no gh call"
assert_eq "$([[ -f "$TMP/externalized.md" ]] && echo yes || echo no)" "no" "dry-run writes no ledger"

# ── 3. Live happy path: #1 filed, its block removed, ledger records it; #2/#3/#4 untouched.
write_fixture
: > "$GH_CALLS"; : > "$GH_COUNT"
"$SCRIPT" >/dev/null 2>&1
after="$(cat "$TMP/tickets.md")"
assert_eq "$(printf '%s\n' "$after" | grep -cE '^## #1 ')" "0" "ticket #1 block removed from tickets.md"
assert_contains "$after" "## #2 " "#2 (sibling) left in place"
assert_contains "$after" "## #3 " "#3 (medium) left in place"
assert_contains "$after" "## #4 " "#4 (no-where) left in place"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "1" "exactly one gh issue create call"
assert_contains "$(cat "$GH_CALLS")" "issue create --repo acme/foo" "gh targeted the OSS repo"
assert_contains "$(cat "$GH_CALLS")" "low foo thing" "issue title came from the ticket heading"
assert_contains "$(cat "$TMP/externalized.md")" "#1 — low foo thing" "ledger records externalized #1"
assert_contains "$(cat "$TMP/externalized.md")" "issues/999" "ledger records the issue URL"

# Auto-labels: contributor signals + a content category, ALL intersected with the repo's real labels.
gh_call="$(cat "$GH_CALLS")"
assert_contains "$gh_call" "label good first issue" "auto-applies 'good first issue' (exists in repo)"
assert_contains "$gh_call" "label help wanted" "auto-applies 'help wanted' (exists in repo)"
assert_contains "$gh_call" "label enhancement" "auto-applies the 'enhancement' content category"
assert_eq "$(printf '%s' "$gh_call" | grep -c -- '--label documentation')" "0" "does NOT apply unrelated 'documentation'"

# The public issue body must NOT leak the internal ticket number, and must carry the real fields.
body_arg="$(cat "$GH_CALLS")"
assert_contains "$body_arg" "**Where:**" "issue body carries the Where field"
assert_eq "$(printf '%s' "$body_arg" | grep -c '## #1')" "0" "issue body omits the internal ## #1 heading"

# ── 4. Idempotency heal: a ticket still in tickets.md but already in the ledger is NOT re-filed —
# its lingering block is removed and gh is never called again (simulates a prior partial failure).
write_fixture
printf -- '- #1 — low foo thing — https://x/issues/1 (2026-06-27)\n' >> "$TMP/externalized.md"
: > "$GH_CALLS"; : > "$GH_COUNT"
"$SCRIPT" >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "already-ledgered #1 is not re-filed (no gh call)"
assert_eq "$(grep -cE '^## #1 ' "$TMP/tickets.md")" "0" "heal removes the lingering #1 block"

# ── 5. Leak guard: a Low+foo ticket whose body/title references another ticket (#N) or a commit hash
# is NOT published (it would leak private harness context) — it stays in tickets.md.
cat > "$TMP/tickets.md" <<'EOF'
## #7 — low foo, but a follow-up to internal #11

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/z.py`
**Observed:** continues the #11 work; needs prior internal context.
**Ref:** Found resolving #11 (commit `27073ce`).

---
EOF
rm -f "$TMP/externalized.md"; : > "$GH_CALLS"; : > "$GH_COUNT"
c7="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" bash -c 'source "'"$COMMON"'"; govern::externalize_candidates "'"$TMP/tickets.md"'"')"
assert_eq "$c7" "7" "candidates still lists Low+foo #7 (guard is applied by the script, not eligibility)"
"$SCRIPT" >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "internally-cross-referenced #7 is NOT filed (leak guard)"
assert_eq "$(grep -cE '^## #7 ' "$TMP/tickets.md")" "1" "skipped #7 stays in tickets.md for manual sanitizing"

# ── 6. Ref line is dropped from a clean issue body (provenance is internal-only).
write_fixture
sed -i.bak 's#^\*\*Observed:\*\* something small.#**Observed:** something small.\n**Ref:** Found while testing.#' "$TMP/tickets.md" && rm -f "$TMP/tickets.md.bak"
: > "$GH_CALLS"; : > "$GH_COUNT"
"$SCRIPT" >/dev/null 2>&1
assert_contains "$(cat "$GH_CALLS")" "something small" "clean #1 still filed"
assert_eq "$(printf '%s' "$(cat "$GH_CALLS")" | grep -c 'Found while testing')" "0" "the **Ref:** line is stripped from the public body"

# ── 7. Label-apply permission rejection (#26): gh creates the issue but the label step is rejected
# on stderr. The lane must NOT report a silent `filed` success — it captures stderr, emits a distinct
# "LABELS REJECTED" WARN, yet still treats the issue as filed (block removed + ledger).
write_fixture
: > "$GH_CALLS"; : > "$GH_COUNT"
warn_out="$(GH_LABEL_REJECT=1 "$SCRIPT" 2>&1 >/dev/null)"
assert_contains "$warn_out" "LABELS REJECTED" "label-permission rejection surfaces a distinct WARN (not a silent filed success)"
assert_contains "$warn_out" "Triage" "the WARN names the actionable fix (grant Triage on the repo)"
assert_eq "$(printf '%s\n' "$warn_out" | grep -c 'filed but LABELS REJECTED')" "1" "exactly one per-ticket label-rejection WARN for #1"
assert_eq "$(grep -cE '^## #1 ' "$TMP/tickets.md")" "0" "label-rejected #1 block still removed (issue exists)"
assert_contains "$(cat "$TMP/externalized.md")" "#1 — low foo thing" "label-rejected #1 still recorded in the ledger"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "1" "still exactly one gh issue create call"
assert_contains "$warn_out" "labels-rejected=1" "run summary counts the label rejection distinctly from a clean filing"

# ── 8. Detection helper precision.
assert_eq "$(bash -c 'source "'"$COMMON"'"; govern::label_apply_rejected "GraphQL: ... (addLabelsToLabelable)" && echo yes || echo no')" "yes" "helper flags an addLabelsToLabelable rejection"
assert_eq "$(bash -c 'source "'"$COMMON"'"; govern::label_apply_rejected "Warning: 1 uncommitted change" && echo yes || echo no')" "no" "helper ignores benign non-label stderr"
assert_eq "$(bash -c 'source "'"$COMMON"'"; govern::label_apply_rejected "" && echo yes || echo no')" "no" "helper is safe on empty stderr"

# ── 9. Unset GOVERN_EXTERNALIZE_REPO: the lane must skip cleanly (this is the opt-in gate). No crash
# under set -u, no gh call, tickets.md byte-identical.
write_fixture
before_u="$(cat "$TMP/tickets.md")"
: > "$GH_CALLS"; : > "$GH_COUNT"
out_u="$(env -u GOVERN_EXTERNALIZE_REPO GOVERN_EXTERNALIZE_LANE=1 GOVERN_WS_ROOT="$TMP" "$SCRIPT" 2>&1)" && rc_u=0 || rc_u=$?
assert_eq "$rc_u" "0" "unset GOVERN_EXTERNALIZE_REPO exits 0 (opt-in gate — no unbound-variable crash under set -u)"
assert_contains "$out_u" "no GOVERN_EXTERNALIZE_REPO configured" "logs a clear skip reason"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "makes no gh call when no repo is configured"
assert_eq "$(cat "$TMP/tickets.md")" "$before_u" "leaves tickets.md byte-identical when skipping"

# ── #75: eligibility EXCLUDES harness-scope + validation/decision tickets (not just Low+foo) ──
cat > "$TMP/tickets.md" <<'EOF'
## #50 — genuine foo product bug

**Severity:** Low
**Where:** `foo` sub-repo — `foo/cli/cmd_x.py`

---

## #51 — governor supervisor mis-orders two tied Lows

**Severity:** Low
**Where:** meta-repo harness — `scripts/govern/select-ticket.sh`; surfaced on a `foo` sub-repo ticket.

---

## #52 — VALIDATION spike: does the new trim policy cut cost, live A/B

**Severity:** Low
**Where:** `foo` sub-repo — `foo/core/output_cap.py`

---

## #53 — dead feature on main — decide remove vs keep-documented

**Severity:** Low
**Where:** `foo` sub-repo — `foo/core/output_cap.py`

---

## #54 — spike-typed foo ticket

**Severity:** Low
**Where:** `foo` sub-repo — `foo/core/y.py`
**Type:** Validation spike — needs a live run.

---
EOF
cands75="$(GOVERN_TICKETS_FILE="$TMP/tickets.md" bash -c 'source "'"$COMMON"'"; govern::externalize_candidates "'"$TMP/tickets.md"'"')"
assert_eq "$cands75" "50" "#75: only the genuine product bug #50 is eligible; harness(#51)/validation(#52,#54)/decide(#53) all excluded"

assert_done
