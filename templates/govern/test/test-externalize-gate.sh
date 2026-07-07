#!/usr/bin/env bash
# Externalization review gate — END-TO-END disposition wiring through escalations-apply-answers.sh:
# stage → operator answers the questionnaire (via record-escalation-answer.sh) → apply-answers dispatches
# the review-gate disposition. Three scenarios (approve-all / move-back / decide-later) each in a fresh
# sandbox, gh stubbed on PATH (no network). Scenario A ALSO carries a generic do-the-work escalation to
# prove the kind-gated review tokens do NOT regress the ordinary lifecycle.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
APPLY="$DIR/../escalations-apply-answers.sh"
STAGE="$DIR/../externalize-low-tickets.sh"
RECORD="$DIR/../record-escalation-answer.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# Build a hermetic sandbox: git repo + workspace stub (REPOS incl. 'foo') + gh stub. Echoes the env
# array on stdout via a global; sets GH_CALLS/GH_COUNT for the caller.
setup_sandbox() { # <root>
  local T="$1"
  mkdir -p "$T/bin" "$T/scripts/lib" "$T/queue"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
GITHUB_ORG="acme"
REPOS=(foo foo-website web)
GOVERN_MERGE_REPOS=""
GOVERN_LOCAL_FIRST_REPOS=""
WORKTREE_BASE="$T/wt"
wsp_is_merge_repo() { return 1; }
wsp_is_local_first_repo() { return 1; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "label" && "$2" == "list" ]]; then printf '%s\n' "good first issue" "help wanted" "enhancement"; exit 0; fi
printf 'CALL\n' >> "$GH_COUNT"; printf '%s\n' "$*" >> "$GH_CALLS"
echo "https://github.com/acme/foo/issues/999"
EOF
  chmod +x "$T/bin/gh"
  printf '# Escalations\n\n## Open\n\n## Resolved\n' > "$T/escalations.md"
  ENVV=(
    GOVERN_WS_ROOT="$T"
    GOVERN_TICKETS_FILE="$T/tickets.md"
    GOVERN_TICKETS_PARKED_FILE="$T/tickets-parked.md"
    GOVERN_ESCALATIONS_FILE="$T/escalations.md"
    GOVERN_PREFERENCES_FILE="$T/preferences.md"
    GOVERN_PENDING_FILE="$T/pending.json"
    GOVERN_EXTERNALIZED_FILE="$T/externalized.md"
    GOVERN_EXTERNALIZE_REVIEW_FILE="$T/review.md"
    GOVERN_EXTERNALIZE_REPO="acme/foo"
    GOVERN_EXTERNALIZE_SUBREPO="foo"
    GOVERN_EXTERNALIZE_LANE=1
    GOVERN_NO_PUSH=1
    PATH="$T/bin:$PATH"
  )
  export GH_CALLS="$T/gh-calls.log" GH_COUNT="$T/gh-count.log"
  : > "$GH_CALLS"; : > "$GH_COUNT"
}

two_foo_tickets() { # writes #10 + #11 (Low foo, eligible)
  cat > "$1/tickets.md" <<'EOF'
# Tickets
---
## #10 — low foo alpha

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/a.py`
**Observed:** small a.
---
## #11 — low foo beta

**Severity:** Low — minor.
**Where:** `foo` sub-repo — `foo/b.py`
**Observed:** small b.
---
EOF
}

# ══════════════════════════ Scenario A — approve-all (+ generic co-escalation regression) ══════════
TA="$(mktemp -d)"; trap 'rm -rf "$TA"' EXIT
setup_sandbox "$TA"; ENVA=("${ENVV[@]}")
two_foo_tickets "$TA"
# A generic (non-externalize) High ticket #20 with a do-the-work escalation — NOT eligible for staging.
cat >> "$TA/tickets.md" <<'EOF'
## #20 — generic high bug

**Severity:** High — real.
**Where:** `foo` sub-repo — `foo/c.py`
body twenty
---
EOF
# Stage the two Low foo tickets → questionnaire (anchor #10).
env "${ENVA[@]}" bash "$STAGE" >/dev/null 2>&1
assert_eq "$(grep -cE '^## #1[01] ' "$TA/review.md")" "2" "A: staging moved #10 + #11 into the review queue"
assert_eq "$(grep -cF '**Kind:** externalize-review' "$TA/escalations.md")" "1" "A: one externalize-review questionnaire filed (anchor #10)"
# File the GENERIC do-the-work escalation for #20 (separate from the review gate).
env "${ENVA[@]}" bash -c 'source "'"$DIR"'/../lib/common.sh"; govern::file_open_escalation 20 "generic high bug" "needs retry" "retry?" "do-the-work|defer"' >/dev/null 2>&1
# Operator answers BOTH: #10 approve-all, #20 do-the-work.
env "${ENVA[@]}" bash "$RECORD" 10 --answer "approve-all" --disposition "approve-all" >/dev/null 2>&1
env "${ENVA[@]}" bash "$RECORD" 20 --answer "yes retry it" --disposition "do-the-work" >/dev/null 2>&1
# Apply.
outA="$(env "${ENVA[@]}" bash "$APPLY" 2>&1)"
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "2" "A: approve-all filed BOTH staged tickets as public issues (2 gh calls)"
assert_contains "$(cat "$TA/externalized.md")" "#10 — low foo alpha" "A: ledger records #10"
assert_contains "$(cat "$TA/externalized.md")" "#11 — low foo beta" "A: ledger records #11"
assert_eq "$(grep -cE '^## #1[01] ' "$TA/review.md")" "0" "A: both tickets removed from the review queue after filing"
assert_contains "$outA" "externalized 1" "A: apply summary counts the externalize disposition"
# REGRESSION: the generic do-the-work escalation is STILL processed alongside the review gate.
assert_contains "$outA" "un-parked 1" "A (REGRESSION): the generic do-the-work lifecycle still runs (un-parked 1) — kind-gate did not break it"
assert_contains "$(cat "$TA/tickets.md")" "## #20 " "A (REGRESSION): un-parked #20 remains in tickets.md"
assert_eq "$(grep -c '### #10' "$TA/escalations.md")" "1" "A: the #10 questionnaire block still present (moved to Resolved)"
assert_contains "$(awk '/^## Resolved/{f=1} f' "$TA/escalations.md")" "### #10" "A: #10 questionnaire moved under ## Resolved"

# ══════════════════════════ Scenario B — move-back:<id> (restore + never-flag; remainder re-nudged) ═
TB="$(mktemp -d)"; trap 'rm -rf "$TA" "$TB"' EXIT
setup_sandbox "$TB"; ENVB=("${ENVV[@]}")
two_foo_tickets "$TB"
env "${ENVB[@]}" bash "$STAGE" >/dev/null 2>&1
env "${ENVB[@]}" bash "$RECORD" 10 --answer "move these back: 10" --disposition "move-back:10" >/dev/null 2>&1
env "${ENVB[@]}" bash "$APPLY" >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "B: move-back files NO public issue"
assert_eq "$(grep -cE '^## #10 ' "$TB/tickets.md")" "1" "B: #10 returned to tickets.md"
assert_contains "$(cat "$TB/tickets.md")" "**Externalize:** never" "B: #10 stamped Externalize: never"
assert_eq "$(grep -cE '^## #10 ' "$TB/review.md")" "0" "B: #10 removed from the review queue"
assert_eq "$(grep -cE '^## #11 ' "$TB/review.md")" "1" "B: #11 (not listed) STAYS staged"
# Re-stage: #10 is never-flagged (not re-staged); #11 still staged with no open questionnaire → re-nudge.
env "${ENVB[@]}" bash "$STAGE" >/dev/null 2>&1
assert_eq "$(grep -cE '^## #10 ' "$TB/review.md")" "0" "B: never-flagged #10 is NOT re-staged"
assert_eq "$(awk '/^## Open/{f=1} /^## Resolved/{f=0} f' "$TB/escalations.md" | grep -cF '**Kind:** externalize-review')" "1" "B: exactly ONE OPEN questionnaire re-nudges the remaining #11 (no duplicate)"

# ══════════════════════════ Scenario C — decide-later (stay staged; re-nudged; no duplicate) ═══════
TC="$(mktemp -d)"; trap 'rm -rf "$TA" "$TB" "$TC"' EXIT
setup_sandbox "$TC"; ENVC=("${ENVV[@]}")
two_foo_tickets "$TC"
env "${ENVC[@]}" bash "$STAGE" >/dev/null 2>&1
env "${ENVC[@]}" bash "$RECORD" 10 --answer "not now" --disposition "decide-later" >/dev/null 2>&1
env "${ENVC[@]}" bash "$APPLY" >/dev/null 2>&1
assert_eq "$(wc -l < "$GH_COUNT" | tr -d ' ')" "0" "C: decide-later files NO public issue"
assert_eq "$(grep -cE '^## #1[01] ' "$TC/review.md")" "2" "C: both tickets STAY staged"
assert_contains "$(awk '/^## Resolved/{f=1} f' "$TC/escalations.md")" "### #10" "C: the answered questionnaire is Resolved"
assert_eq "$(awk '/^## Open/{f=1} /^## Resolved/{f=0} f' "$TC/escalations.md" | grep -cF '**Kind:** externalize-review')" "0" "C: no OPEN externalize questionnaire remains right after decide-later"
# Next run re-stages: no new candidates, staged tickets remain, no open questionnaire → re-file exactly ONE.
env "${ENVC[@]}" bash "$STAGE" >/dev/null 2>&1
assert_eq "$(awk '/^## Open/{f=1} /^## Resolved/{f=0} f' "$TC/escalations.md" | grep -cF '**Kind:** externalize-review')" "1" "C: decide-later re-nudges with exactly ONE fresh questionnaire (no duplicate)"

assert_done
