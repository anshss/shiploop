#!/usr/bin/env bash
# ── Shared "code-work" state fingerprint for the ticket-sweep Stop hook ──
# SOURCE this file (after lib/workspace.sh, which defines REPOS). Do NOT execute.
#
# Produces a single deterministic blob capturing the workspace's code-work state:
#   - the main checkout's tickets.md content
#   - every sub-repo's HEAD, working-tree status, and tracked-content diff
# The SessionStart hook (session-snapshot.sh) snapshots this once at session
# start; the Stop hook (ticket-sweep-reminder.sh) recomputes it and fires only
# when the blob CHANGED — i.e. work happened SINCE this session began. That stops
# prior-session residue (commits ahead of origin/main or dirty trees left by an
# earlier run) from counting as "this session touched code", which would otherwise
# spend the once-per-session reminder at session START on stale state.
#
# Determinism: HEAD sha, `git status --porcelain` (stable order, includes
# untracked), and `git diff HEAD` are all reproducible for an unchanged tree, so
# two calls with no intervening edits produce byte-identical output.

# ticket_sweep_state_fingerprint <main_checkout> <worktree_root>
#   <main_checkout> — fixed path that owns tickets.md (the meta-repo root).
#   <worktree_root> — the resolved repo root the session is operating in; sub-repos
#                     are read from "<worktree_root>/<repo>".
ticket_sweep_state_fingerprint() {
  local main="$1" root="$2" r dir
  # MAIN tickets.md content (a content hash, so in-place edits are detected).
  if [ -f "$main/tickets.md" ]; then
    printf 'tickets:%s\n' "$(git -C "$main" hash-object "$main/tickets.md" 2>/dev/null || echo unknown)"
  else
    printf 'tickets:absent\n'
  fi
  for r in "${REPOS[@]:-}"; do
    dir="$root/$r"
    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
      printf '%s|head:%s|status:%s|diff:%s\n' \
        "$r" \
        "$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)" \
        "$(git -C "$dir" status --porcelain=v1 2>/dev/null | git hash-object --stdin 2>/dev/null || echo none)" \
        "$(git -C "$dir" diff HEAD 2>/dev/null | git hash-object --stdin 2>/dev/null || echo none)"
    else
      printf '%s|absent\n' "$r"
    fi
  done
}
