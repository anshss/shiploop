#!/usr/bin/env bash
# Externalization REVIEW GATE (staged): the governor never auto-publishes. This exercises the three
# modes of externalize-low-tickets.sh directly, with gh stubbed on PATH (no network):
#   eligibility (Low + OSS sub-repo) incl. the substring-sibling trap, the severity gate, harness/
#   validation exclusion, and the NEW `Externalize: never` opt-out; STAGE (move to review queue + file
#   ONE Kind-tagged questionnaire, deduped); dry-run no-op; --approve (file → ledger → de-block, incl.
#   leak-guard, idempotency heal, label-permission rejection); --move-back (restore + never-flag);
#   and the OFF-when-unconfigured skip.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"
SCRIPT="$DIR/../externalize-low-tickets.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake gh: canned label set on `label list`, and on `issue create` counts the call, records argv, and
# prints the canned issue URL. GH_LABEL_REJECT=1 emits the composite-op label rejection on stderr while
# still exiting 0 with the URL (mimicking a pull-only account).
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

# Custom workspace stub: REPOS = (foo foo-website web) so we can exercise the substring-sibling trap.
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

export GOVERN_TICKETS_FILE="$TMP/tickets.md"
export GOVERN_EXTERNALIZED_FILE="$TMP/externalized.md"
export GOVERN_EXTERNALIZE_REVIEW_FILE="$TMP/review.md"
export GOVERN_ESCALATIONS_FILE="$TMP/escalations.md"
export GOVERN_EXTERNALIZE_REPO="acme/foo"
export GOVERN_EXTERNALIZE_SUBREPO="foo"
export GOVERN_EXTERNALIZE_LANE="1"
export GOVERN_NO_PUSH="1"
export PATH="$TMP/bin:$PATH"

seed_escalations() { printf '# Escalations\n\n## Open\n\n## Resolved\n' > "$TMP/escalations.md"; }

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
  rm -f "$TMP/externalized.md" "$TMP/review.md"
  seed_escalations
  : > "$GH_CALLS"; : > "$GH_COUNT"
}

cands_of() { GOVERN_TICKETS_FILE="$1" bash -c 'source "'"$COMMON"'"; govern::externalize_candidates "'"$1"'"'; }

# ── 1. Eligibility: ONLY #1 (Low + foo). #2 sibling trap, #3 Medium, #4 no Where.
write_fixture
assert_eq "$(cands_of "$TMP/tickets.md")" "1" "candidates = Low+foo only (excludes sibling trap, Medium, no-Where)"

# ── 1b. NEW: `Externalize: never` opt-out excludes an otherwise-eligible ticket.
cat > "$TMP/tickets.md" <<'EOF'
## #1 — low foo thing
**Externalize:** never  <!-- operator move-back -->

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/core/x.py`

---
EOF
assert_eq "$(cands_of "$TMP/tickets.md")" "" "a ticket flagged 'Externalize: never' is NOT a candidate (permanent opt-out)"

# ── 2. Dry STAGE: no move, no questionnaire, no gh, tickets.md byte-identical.
write_fixture
before="$(cat "$TMP/tickets.md")"
"$SCRIPT" --dry >/dev/null 2>&1
assert_eq "$(cat "$TMP/tickets.md")" "$before" "dry stage leaves tickets.md byte-identical"
assert_eq "$([[ -f "$TMP/review.md" ]] && echo yes || echo no)" "no" "dry stage creates no review queue"
assert_eq "$(grep -cF '**Kind:** externalize-review' "$TMP/escalations.md")" "0" "dry stage files no questionnaire"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "dry stage makes no gh call"

# ── 3. STAGE: #1 MOVED out of tickets.md into the review queue; ONE Kind-tagged questionnaire; no gh.
write_fixture
"$SCRIPT" >/dev/null 2>&1
assert_eq "$(grep -cE '^## #1 ' "$TMP/tickets.md")" "0" "stage removes #1 from tickets.md"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "1" "stage moves #1 into the review queue"
assert_contains "$(cat "$TMP/review.md")" "**Where:**" "the moved block keeps its body"
assert_eq "$(grep -cF '**Kind:** externalize-review' "$TMP/escalations.md")" "1" "stage files ONE questionnaire carrying the Kind tag (dedupe + dispatch key)"
assert_contains "$(cat "$TMP/escalations.md")" "approve-all | decide-later | move-back" "questionnaire Disposition hint lists the review-gate options"
assert_contains "$(cat "$TMP/escalations.md")" "#1 — low foo thing" "questionnaire lists the staged ticket"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "stage files NO public issue (never auto-publishes)"

# ── 4. DEDUPE: a second stage with the questionnaire still open does NOT file a duplicate.
"$SCRIPT" >/dev/null 2>&1
assert_eq "$(grep -cF '**Kind:** externalize-review' "$TMP/escalations.md")" "1" "second stage does NOT file a duplicate questionnaire (deduped by Kind)"

# ── 5. APPROVE: file every staged ticket via gh, remove it from the review queue, ledger it.
#    (#1 is staged from case 3.)
"$SCRIPT" --approve >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "1" "approve makes exactly one gh issue create call"
assert_contains "$(cat "$GH_CALLS")" "issue create --repo acme/foo" "approve targeted the OSS repo"
assert_contains "$(cat "$GH_CALLS")" "low foo thing" "issue title came from the ticket heading"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "0" "approve removes the filed ticket from the review queue"
assert_contains "$(cat "$TMP/externalized.md")" "#1 — low foo thing" "approve records the ledger entry"
assert_contains "$(cat "$GH_CALLS")" "label good first issue" "approve auto-applies 'good first issue'"
assert_eq "$(printf '%s' "$(cat "$GH_CALLS")" | grep -c '## #1')" "0" "issue body omits the internal ## #1 heading"

# ── 6. APPROVE idempotency heal: a staged ticket already in the ledger is NOT re-filed — its block is
#    removed from the review queue and gh is never called.
write_fixture
"$SCRIPT" >/dev/null 2>&1                                   # stage #1
printf -- '- #1 — low foo thing — https://x/issues/1 (2026-06-27)\n' >> "$TMP/externalized.md"
: > "$GH_CALLS"; : > "$GH_COUNT"
"$SCRIPT" --approve >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "already-ledgered #1 is not re-filed (heal, no gh)"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "0" "heal removes the lingering staged block"

# ── 7. APPROVE leak guard: a staged Low+foo ticket referencing another ticket / commit is NOT filed.
cat > "$TMP/tickets.md" <<'EOF'
## #7 — low foo, follow-up to internal #11

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/z.py`
**Observed:** continues the #11 work.
**Ref:** Found resolving #11 (commit `27073ce`).

---
EOF
rm -f "$TMP/review.md" "$TMP/externalized.md"; seed_escalations; : > "$GH_CALLS"; : > "$GH_COUNT"
"$SCRIPT" >/dev/null 2>&1                                   # stage #7
"$SCRIPT" --approve >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "internally-cross-referenced #7 is NOT filed (leak guard)"
assert_eq "$(grep -cE '^## #7 ' "$TMP/review.md")" "1" "leak-guarded #7 stays STAGED for manual sanitizing"

# ── 8. APPROVE label-permission rejection: gh files the issue but the label step is rejected.
write_fixture
"$SCRIPT" >/dev/null 2>&1                                   # stage #1
: > "$GH_CALLS"; : > "$GH_COUNT"
warn_out="$(GH_LABEL_REJECT=1 "$SCRIPT" --approve 2>&1 >/dev/null)"
assert_contains "$warn_out" "LABELS REJECTED" "label rejection surfaces a distinct WARN (not silent filed)"
assert_contains "$warn_out" "Triage" "the WARN names the actionable fix"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "0" "label-rejected #1 still de-staged (issue exists)"
assert_contains "$(cat "$TMP/externalized.md")" "#1 — low foo thing" "label-rejected #1 still ledgered"

# ── 9. MOVE-BACK: return a staged ticket to tickets.md flagged `Externalize: never`; de-stage it.
write_fixture
"$SCRIPT" >/dev/null 2>&1                                   # stage #1
"$SCRIPT" --move-back "1" >/dev/null 2>&1
assert_eq "$(grep -cE '^## #1 ' "$TMP/tickets.md")" "1" "move-back returns #1 to tickets.md"
assert_contains "$(cat "$TMP/tickets.md")" "**Externalize:** never" "move-back stamps the never-externalize flag"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "0" "move-back removes #1 from the review queue"
# ...and the flag STICKS: a re-stage must NOT re-stage #1.
"$SCRIPT" >/dev/null 2>&1
assert_eq "$(grep -cE '^## #1 ' "$TMP/tickets.md")" "1" "moved-back #1 is NOT re-staged (Externalize: never honored)"
assert_eq "$(grep -cE '^## #1 ' "$TMP/review.md")" "0" "moved-back #1 stays out of the review queue on re-stage"

# ── 10. Unset GOVERN_EXTERNALIZE_REPO: the lane skips cleanly (opt-in gate). No crash under set -u.
write_fixture
before_u="$(cat "$TMP/tickets.md")"
out_u="$(env -u GOVERN_EXTERNALIZE_REPO GOVERN_EXTERNALIZE_LANE=1 GOVERN_WS_ROOT="$TMP" "$SCRIPT" 2>&1)" && rc_u=0 || rc_u=$?
assert_eq "$rc_u" "0" "unset GOVERN_EXTERNALIZE_REPO exits 0 (opt-in gate — no set -u crash)"
assert_contains "$out_u" "no GOVERN_EXTERNALIZE_REPO configured" "logs a clear skip reason"
assert_eq "$(cat "$TMP/tickets.md")" "$before_u" "leaves tickets.md byte-identical when skipping"

# ── 11. Eligibility EXCLUDES harness-scope + validation/decision tickets (#75, unchanged).
cat > "$TMP/tickets.md" <<'EOF'
## #50 — genuine foo product bug
**Severity:** Low
**Where:** `foo` sub-repo — `foo/cli/cmd_x.py`
---
## #51 — governor supervisor mis-orders two tied Lows
**Severity:** Low
**Where:** meta-repo harness — `scripts/govern/select-ticket.sh`; on a `foo` ticket.
---
## #52 — VALIDATION spike: does the new trim policy cut cost, live A/B
**Severity:** Low
**Where:** `foo` sub-repo — `foo/core/output_cap.py`
---
## #53 — dead feature on main — decide remove vs keep-documented
**Severity:** Low
**Where:** `foo` sub-repo — `foo/core/output_cap.py`
---
EOF
assert_eq "$(cands_of "$TMP/tickets.md")" "50" "#75: only genuine product bug #50 eligible; harness/validation/decide excluded"

# ── 12. Label-apply-rejected helper precision (kept from the original coverage).
assert_eq "$(bash -c 'source "'"$COMMON"'"; govern::label_apply_rejected "GraphQL: ... (addLabelsToLabelable)" && echo yes || echo no')" "yes" "helper flags an addLabelsToLabelable rejection"
assert_eq "$(bash -c 'source "'"$COMMON"'"; govern::label_apply_rejected "" && echo yes || echo no')" "no" "helper is safe on empty stderr"

assert_done
