#!/usr/bin/env bash
# The internal ticket id is suppressed on PRs BY DEFAULT — for every workspace, not just the ones
# whose repos are public.
#
# Why it exists: the run-loop's post-hoc scrub only reaches a PR's title+body. A COMMIT SUBJECT is
# unreachable (rewriting pushed history = force-push = hard stop), so the only control for commit
# subjects is telling the worker up front — and before this that instruction was injected only when
# some repo in the workspace was detected PUBLIC. A private-only fleet therefore shipped `#N` into
# commit subjects with nothing to stop it.
#
# Cases (all through the real GOVERN_SPAWN_PRINT_PROMPT=1 assembly seam):
#   1. Private-only workspace → the no-ticket-id rule IS in the prompt, and it names title, body and
#      commit subject, while explicitly preserving the `ticket-<N>` BRANCH (so it cannot be read as
#      contradicting worker-prompt.md's "branch MUST be ticket-<N>").
#   2. GOVERN_PR_TICKET_REF=1 on a private-only workspace → the rule is gone (opt-out works).
#   3. A public repo still gets the branch-neutralization block (`sl-<hex>`, not `ticket-<N>`).
#   4. The opt-out does NOT weaken the public guarantee: with GOVERN_PR_TICKET_REF=1 a public repo
#      still gets the no-ids rule.
#   5. No duplication in the default public case — "commit subject" is stated ONCE, not twice.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
COMMON="$DIR/../lib/common.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed (neutral_branch needs git hash-object)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor"
export GOVERN_VIS_CACHE="$TMP/.vis"   # isolate repo-visibility caching to this test

cat > "$TMP/tickets.md" <<'EOF'
## #601 — an ordinary ticket
**Severity:** Medium
Observed: a plain code-change ticket.
Done when: PR opens.

---
EOF
printf 'DOCTRINE-SENTINEL\n' > "$TMP/governor/preferences.md"
cat > "$TMP/governor/worker-prompt.md" <<'EOF'
ALWAYS-ON-HEAD-SENTINEL
Your branch MUST be `ticket-<N>`. {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}
EOF

render() { # <env assignments...> -- <ticket>
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  rm -f "$TMP/.vis"
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs" \
      GOVERN_WORKER_MODEL="sonnet" \
      GOVERN_VIS_CACHE="$TMP/.vis" \
      GOVERN_SPAWN_PRINT_PROMPT=1 \
      ${envs[@]+"${envs[@]}"} "$SPAWN" "$@"
}

# ── 1. Private-only workspace: the default rule is present. ──────────────────
# GOVERN_PUBLIC_REPOS="" + no gh visibility ⇒ every repo private (fail-safe path).
priv="$(render GOVERN_PUBLIC_REPOS= -- 601)"
assert_contains "$priv" "PR hygiene" \
  "private-only workspace → the default PR-hygiene block IS injected"
assert_contains "$priv" "**PR title**" "private-only → the rule names the PR title"
assert_contains "$priv" "**PR body**" "private-only → the rule names the PR body"
assert_contains "$priv" "**commit subject**" "private-only → the rule names the commit subject"
assert_contains "$priv" 'BRANCH is still `ticket-601`' \
  "private-only → the branch is explicitly still ticket-<N> (no contradiction with worker-prompt.md)"
assert_not_contains "$priv" "PUBLIC-REPO PR HYGIENE" \
  "private-only → the public-repo branch-neutralization block is NOT injected"

# ── 2. Opt-out removes it (private-only). ────────────────────────────────────
optout="$(render GOVERN_PUBLIC_REPOS= GOVERN_PR_TICKET_REF=1 -- 601)"
assert_not_contains "$optout" "**commit subject**" \
  "GOVERN_PR_TICKET_REF=1 on a private-only workspace → the no-ticket-id rule is gone"
assert_contains "$optout" "ALWAYS-ON-HEAD-SENTINEL" \
  "GOVERN_PR_TICKET_REF=1 → the rest of the prompt is unaffected"

# ── 3. A public repo still gets branch neutralization. ───────────────────────
source "$COMMON"
nb="$(govern::neutral_branch 601)"
pub="$(render GOVERN_PUBLIC_REPOS=alpha -- 601)"
assert_contains "$pub" "PUBLIC-REPO PR HYGIENE" \
  "public repo → the branch-neutralization block IS injected"
assert_contains "$pub" "$nb" "public repo → the neutral sl-<hex> branch is named"
assert_contains "$pub" "**commit subject**" \
  "public repo → the no-ticket-id rule is still present (via the default block)"

# ── 4. The opt-out must NOT weaken the public guarantee. ─────────────────────
pub_optout="$(render GOVERN_PUBLIC_REPOS=alpha GOVERN_PR_TICKET_REF=1 -- 601)"
assert_contains "$pub_optout" "PUBLIC-REPO PR HYGIENE" \
  "public repo + opt-out → branch neutralization still applies"
assert_contains "$pub_optout" "**commit subject**" \
  "public repo + opt-out → the no-ticket-id rule is RESTATED (opt-out cannot weaken public repos)"
assert_contains "$pub_optout" "$nb" "public repo + opt-out → the neutral branch is still named"

# ── 5. No duplicated tokens in the default public case. ──────────────────────
# Both blocks appending the same rule would be pure per-worker token waste.
dupes="$(grep -cF '**commit subject**' <<<"$pub" || true)"
assert_eq "$dupes" "1" \
  "default public case → the commit-subject rule is stated exactly ONCE (no duplicated prompt tokens)"

assert_done
