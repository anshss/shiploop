#!/usr/bin/env bash
# Regression for ticket #91: the post-merge local ticket-<N> branch delete in merge-pr.sh must NOT
# log "could not delete local branch ... (checked out in a worktree?)" on every merge. At merge time
# the worker's worktree still has ticket-<N> checked out, so `branch -D` is a guaranteed no-op — the
# delete is tied to worktree TEARDOWN (`worktree:rm`) instead. merge-pr.sh now:
#   (a) skips silently when the branch is checked out in a worktree (no noise), and
#   (b) still deletes a genuinely-lingering local branch (no worktree) — the #76 backstop.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/scripts/lib"
# Bypass the external-PR auto-merge safety guard: this test targets #91 (branch cleanup), not the
# guard. The guard has its own dedicated tests (test-automerge-guard.sh).
export _GOVERN_ASSUME_MERGE_ALLOWED=1

# The merge path runs under GOVERN_WS_ROOT="$T", so common.sh sources $T/scripts/lib/workspace.sh.
# Seed a minimal one: alpha is auto-mergeable and its local checkout resolves to $T/alpha.
cat > "$T/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$T}"
GITHUB_ORG="acme"
REPOS=(alpha)
GOVERN_MERGE_REPOS=(alpha)
wsp_is_merge_repo() { [ "\$1" = alpha ]; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF

# A real clone of an allowlisted repo lives at $WS_ROOT/alpha (so localdir resolves there).
REPODIR="$T/alpha"
mkdir -p "$REPODIR"
( cd "$REPODIR" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )

# gh stub: `pr merge` succeeds; `pr view ... headRefName` returns the head we ask for via $HEAD env;
# everything else passes. (await-ci is skipped via GOVERN_SKIP_CI=1.)
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr merge"*)  exit 0;;
  *"pr view"*"headRefName"*) echo "$HEAD";;
  *)             echo '[]';;
esac
EOF
chmod +x "$T/bin/gh"

run_merge() { # $1=head-branch
  HEAD="$1" PATH="$T/bin:$PATH" GOVERN_WS_ROOT="$T" GOVERN_SKIP_CI=1 \
    bash "$MERGE" alpha 123 2>&1
}

# ── Scenario A: branch checked out in a worktree → skip SILENTLY, no #91 noise, branch survives ──
( cd "$REPODIR" && git branch ticket-91 \
    && git worktree add -q "$T/wt-91" ticket-91 >/dev/null 2>&1 )
outA="$(run_merge ticket-91)"

if printf '%s' "$outA" | grep -qF "could not delete local branch"; then
  assert_eq "noisy" "silent" "#91: no 'could not delete local branch' noise when branch is checked out"
else
  assert_eq "silent" "silent" "#91: no 'could not delete local branch' noise when branch is checked out"
fi
if printf '%s' "$outA" | grep -qF "deleted lingering local branch"; then
  assert_eq "deleted" "skipped" "#91: a checked-out branch is NOT deleted at merge (worktree:rm handles it)"
else
  assert_eq "skipped" "skipped" "#91: a checked-out branch is NOT deleted at merge (worktree:rm handles it)"
fi
if ( cd "$REPODIR" && git rev-parse --verify ticket-91 >/dev/null 2>&1 ); then
  assert_eq "exists" "exists" "#91: checked-out branch survives the merge (torn down later by worktree:rm)"
else
  assert_eq "gone" "exists" "#91: checked-out branch survives the merge (torn down later by worktree:rm)"
fi

# ── Scenario B: a genuinely-lingering branch (no worktree) → backstop still deletes it (#76) ──
( cd "$REPODIR" && git branch ticket-76 )   # exists, not checked out anywhere
outB="$(run_merge ticket-76)"
assert_contains "$outB" "deleted lingering local branch ticket-76" "#76 backstop: lingering branch IS deleted"
if ( cd "$REPODIR" && git rev-parse --verify ticket-76 >/dev/null 2>&1 ); then
  assert_eq "exists" "gone" "#76 backstop: lingering branch removed after merge"
else
  assert_eq "gone" "gone" "#76 backstop: lingering branch removed after merge"
fi

assert_done
