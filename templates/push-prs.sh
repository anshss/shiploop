#!/bin/bash
# Run from repo root: <pm> run push
# Auto-commits uncommitted changes (AI-generated messages), pushes branches,
# and opens PRs with AI-generated descriptions via claude -p.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/lib/workspace.sh"

# Derive "org/repo" from each sub-repo's git remote, not a hardcoded org literal.
# This is intentional: sub-repos may live under a different org than the workspace.
gh_repo_for() {
  local dir="$1"
  local url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  [ -z "$url" ] && return 1
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  url="${url%.git}"
  echo "$url"
}

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not found. Install from https://cli.github.com"
  exit 1
fi
if ! command -v claude &>/dev/null; then
  echo "Error: claude CLI not found. Install Claude Code."
  exit 1
fi

PR_CREATED=0

ai_commit_message() {
  echo "$1" | claude -p \
    "Write a concise git commit message for this diff. Use imperative mood. Subject line max 72 chars. Output ONLY the commit message text." \
    2>/dev/null
}

ai_pr_description() {
  echo "$1" | claude -p \
    "Write a GitHub PR description for these commits. 1-2 sentence summary, then bullet list of key changes. Concise and technical. Output only the description text." \
    2>/dev/null
}

check_cross_repo_conflicts() {
  local tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT INT TERM

  for repo in "${REPOS[@]}"; do
    local dir="$ROOT_DIR/$repo"
    [ -d "$dir/.git" ] || continue
    (cd "$dir" && {
      git diff --name-only HEAD 2>/dev/null
      git diff --cached --name-only 2>/dev/null
    } | sort -u | sed "s|^|${repo}:|") >> "$tmpfile"
  done

  local conflicts=()
  while IFS= read -r filepath; do
    local count
    count=$(grep -cF ":${filepath}" "$tmpfile" 2>/dev/null || true)
    if [ "${count:-0}" -gt 1 ]; then
      local repos_with_file
      repos_with_file=$(grep -F ":${filepath}" "$tmpfile" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
      conflicts+=("  $filepath  →  $repos_with_file")
    fi
  done < <(cut -d: -f2- "$tmpfile" | sort -u)

  trap - EXIT INT TERM
  rm -f "$tmpfile"

  if [ ${#conflicts[@]} -gt 0 ]; then
    echo ""
    echo "⚠  Cross-repo conflict detected — same relative path modified in multiple repos:"
    for c in "${conflicts[@]}"; do echo "$c"; done
    echo "   Review before merging PRs."
    echo ""
  fi
}

handle_repo() {
  local REPO="$1"
  local REPO_DIR="$ROOT_DIR/$REPO"

  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "⚠  $REPO/ not a git repo, skipping"
    return
  fi

  local GH_REPO
  GH_REPO=$(gh_repo_for "$REPO_DIR")
  if [ -z "$GH_REPO" ]; then
    echo "⚠  $REPO/ — could not detect github.com origin, skipping"
    return
  fi

  cd "$REPO_DIR"

  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$DIRTY" -gt 0 ]; then
    echo "🤖 $REPO/ — generating commit message for $DIRTY changed file(s)..."
    DIFF=$(git diff && git diff --cached)
    [ -z "$DIFF" ] && DIFF=$(git status --short)
    COMMIT_MSG=$(ai_commit_message "$DIFF")
    [ -z "$COMMIT_MSG" ] && COMMIT_MSG="chore: update $(date +%Y-%m-%d)"
    git add -A
    git commit -m "$COMMIT_MSG"
    echo "   ✓ committed: $COMMIT_MSG"
  fi

  git fetch origin --quiet 2>/dev/null || true

  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

  AHEAD=$(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "0")

  if [ "$AHEAD" -eq 0 ]; then
    echo "✓  $REPO/ — up to date"
    cd "$ROOT_DIR"
    return
  fi

  ALREADY_REMOTE=$(git branch -r --contains HEAD 2>/dev/null | grep -v "origin/$DEFAULT_BRANCH" | grep -v "HEAD" | head -1 | tr -d ' ')
  if [ -n "$ALREADY_REMOTE" ]; then
    REMOTE_BRANCH="${ALREADY_REMOTE#origin/}"
    EXISTING_PR=$(gh pr list --repo "$GH_REPO" --head "$REMOTE_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [ -n "$EXISTING_PR" ]; then
      echo "✓  $REPO/ — PR #$EXISTING_PR already open for branch '$REMOTE_BRANCH'"
    else
      echo "✓  $REPO/ — already pushed to '$REMOTE_BRANCH' (no PR yet)"
    fi
    cd "$ROOT_DIR"
    return
  fi

  CURRENT_BRANCH=$(git branch --show-current)
  SHORT_HASH=$(git rev-parse --short HEAD)

  if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ] && [ -n "$CURRENT_BRANCH" ]; then
    BRANCH="$CURRENT_BRANCH"
    git push origin "$BRANCH" --quiet
    echo "↑  $REPO/ — pushed branch '$BRANCH'"
  else
    LAST_MSG=$(git log -1 --pretty=format:"%s" | tr ' ' '-' | tr -cd '[:alnum:]-' | cut -c1-40 | tr '[:upper:]' '[:lower:]')
    BRANCH="auto/$(date +%Y%m%d)-${LAST_MSG}-${SHORT_HASH}"
    git checkout -b "$BRANCH" --quiet
    git push origin "$BRANCH" --quiet
    echo "↑  $REPO/ — pushed new branch '$BRANCH'"
  fi

  echo "🤖 $REPO/ — generating PR description..."
  LOG=$(git log "origin/$DEFAULT_BRANCH..HEAD" --oneline --stat 2>/dev/null)
  PR_TITLE=$(git log -1 --pretty=format:"%s")
  PR_BODY=$(ai_pr_description "$LOG")
  [ -z "$PR_BODY" ] && PR_BODY="$LOG"

  EXISTING_PR=$(gh pr list --repo "$GH_REPO" --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [ -n "$EXISTING_PR" ]; then
    echo "   PR already exists: #$EXISTING_PR"
  else
    PR_URL=$(gh pr create \
      --repo "$GH_REPO" \
      --title "$PR_TITLE" \
      --body "$PR_BODY" \
      --base "$DEFAULT_BRANCH" \
      --head "$BRANCH" 2>/dev/null)
    echo "   PR created: $PR_URL"
    PR_CREATED=$((PR_CREATED + 1))
  fi

  [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ] && git checkout "$DEFAULT_BRANCH" --quiet

  cd "$ROOT_DIR"
}

check_cross_repo_conflicts

for repo in "${REPOS[@]}"; do
  handle_repo "$repo"
done

# Root workspace (optional — only if .git exists at root)
if [ -d "$ROOT_DIR/.git" ]; then
  echo ""
  cd "$ROOT_DIR"
  ROOT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ROOT_DIRTY" -gt 0 ]; then
    echo "🤖 workspace root — generating commit message..."
    DIFF=$(git diff && git diff --cached)
    [ -z "$DIFF" ] && DIFF=$(git status --short)
    COMMIT_MSG=$(ai_commit_message "$DIFF")
    [ -z "$COMMIT_MSG" ] && COMMIT_MSG="chore: update $(date +%Y-%m-%d)"
    git add -A
    git commit -m "$COMMIT_MSG"
    echo "   ✓ committed: $COMMIT_MSG"
  fi

  ROOT_BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -n "$ROOT_BRANCH" ]; then
    # Refresh the remote-tracking ref so ahead/behind are accurate — the
    # meta-repo commits straight to main and a parallel session may have
    # advanced origin since this script started.
    git fetch origin "$ROOT_BRANCH" --quiet 2>/dev/null || true
    ROOT_AHEAD=$(git rev-list --count "origin/$ROOT_BRANCH..HEAD" 2>/dev/null || echo "0")
    ROOT_BEHIND=$(git rev-list --count "HEAD..origin/$ROOT_BRANCH" 2>/dev/null || echo "0")
    if [ "$ROOT_AHEAD" -gt 0 ] && [ "$ROOT_BEHIND" -gt 0 ]; then
      echo "⚠  workspace root — DIVERGED ($ROOT_AHEAD ahead, $ROOT_BEHIND behind); NOT pushing."
      echo "   reconcile first:  git pull --rebase origin $ROOT_BRANCH   (or '$ROOT_PM run pull'), then re-run push"
    elif [ "$ROOT_AHEAD" -gt 0 ]; then
      if git push origin "$ROOT_BRANCH" --quiet; then
        echo "↑  workspace root — pushed ($ROOT_AHEAD commit(s))"
      else
        echo "⚠  workspace root — push rejected (origin moved underneath); run '$ROOT_PM run pull' then re-run push"
      fi
    elif [ "$ROOT_BEHIND" -gt 0 ]; then
      echo "↓  workspace root — behind by $ROOT_BEHIND; nothing to push. Run '$ROOT_PM run pull' to catch up."
    else
      echo "✓  workspace root — up to date"
    fi
  fi
fi

echo ""
echo "Done. $PR_CREATED PR(s) created."

HEALTH_SCRIPT="$ROOT_DIR/scripts/health.sh"
if [ -f "$HEALTH_SCRIPT" ]; then
  echo ""
  echo "Running post-push health check..."
  bash "$HEALTH_SCRIPT" || true
fi
