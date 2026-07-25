#!/usr/bin/env bash
# #71 run-start preflight: reconcile the meta-repo MAIN checkout with origin/main BEFORE the
# governor cuts any harness-lane PR.
#
# When the governor delivers a meta-repo-file ticket as a PR, it branches that PR off the meta
# checkout's main (the worktree is detached at origin/main; bookkeep commits + pushes tickets.md on
# local main). If local main has drifted or DIVERGED from origin/main — e.g. a pre-existing UNPUSHED
# filing commit plus a squash-merged PR landing on origin — then a bookkeep ff-pull fails, its push
# is rejected, and every LATER meta-lane PR is born conflicting on tickets.md → "merge commit cannot
# be cleanly created" → parked. One stale unpushed commit silently cascades a whole run. This
# preflight closes that hole.
#
# Reconcile deterministically (the local meta commits are append-only tickets.md/scripts edits,
# so a rebase replays them cleanly):
#   - in sync (0 ahead / 0 behind) → no-op
#   - behind only                  → git pull --ff-only
#   - ahead only                   → git push  (publish the unpushed append-only meta commits)
#   - diverged (ahead AND behind)  → git pull --rebase  (replay local meta commits) + git push
#
# Exit 0 when main == origin/main afterwards, OR when reconcile does not apply (no origin remote,
# not on main, fetch failed offline, GOVERN_NO_PUSH=1) — the run proceeds. Exit 2 ONLY when main
# truly diverged and the rebase/push could NOT reconcile it (rebase conflict / rejected push):
# the caller (run-loop) then HALTS with one clear message instead of silently cascading.
#
# Usage: preflight-main.sh <meta-checkout-dir>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
d="${1:?meta-checkout dir required}"

# Reconcile only applies to a real, on-main, origin-backed checkout where pushing is allowed.
[[ "${GOVERN_NO_PUSH:-0}" != "1" ]] || { govern::log "preflight: GOVERN_NO_PUSH=1 — skipping main reconcile"; exit 0; }
git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { govern::log "preflight: $d is not a git repo — skipping reconcile"; exit 0; }
git -C "$d" remote get-url origin >/dev/null 2>&1 || { govern::log "preflight: no origin remote — skipping reconcile (local-only repo, e.g. tests)"; exit 0; }
br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
[[ "$br" == "main" ]] || { govern::log "preflight: meta checkout on '$br' (not main) — skipping reconcile"; exit 0; }
git -C "$d" fetch --quiet origin main 2>/dev/null || { govern::log "preflight: fetch origin main failed (offline?) — skipping reconcile"; exit 0; }

# left-right of a symmetric diff: left = commits on origin/main not local (behind), right = local
# not on origin/main (ahead). Tab-separated; `read` splits on whitespace.
read -r behind ahead < <(git -C "$d" rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo "0	0")
behind="${behind:-0}"; ahead="${ahead:-0}"

# #111: a dirty working tree only blocks the reconcile when a PULL is needed (behind != 0): both
# `git pull --ff-only` (behind-only) and `git pull --rebase` (diverged) abort with "cannot pull with
# rebase: You have unstaged changes". git surfaces this as a pull failure, which the divergence path
# below would otherwise MISREPORT as a rebase conflict that 'cascades un-mergeable PRs'. The usual
# culprit is a tracked governor runtime artifact left uncommitted (governor/improvements.md from the
# self-improvement step). Distinguish + handle it here BEFORE any pull, so the run never self-blocks
# on its own output and a genuine conflict still reports the real cause.
if [[ "$behind" != "0" ]] && [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]]; then
  # Known governor runtime artifacts the harness writes to main. Anything OUTSIDE this allowlist is
  # unexpected — don't silently commit it; halt with the actionable cause instead.
  # Allowlist of governor runtime artifacts a run legitimately writes to main:
  #   - governor/improvements.md          — the self-improvement notes writer
  #   - governor/.ticket-seq              — the monotonic ticket seq high-water mark; a crash
  #                                         between the bump and its commit leaves it dirty
  #   - governor/escalations.md           — file_open_escalation / park writers commit same-step
  #                                         but a crash between write + commit can still leave dirty
  #   - governor/pending-escalations.json — regenerated at run-start + run-end from escalations.md
  allow_re='(^|[[:space:]])(governor/improvements\.md|governor/\.ticket-seq|governor/escalations\.md|governor/pending-escalations\.json)$'
  other="$(git -C "$d" status --porcelain 2>/dev/null | grep -vE "$allow_re" || true)"
  if [[ -n "$other" ]]; then
    govern::log "preflight: meta main is $behind behind origin/main but the working tree has UNCOMMITTED changes that will block the rebase — this is NOT a merge conflict. Commit or stash them, then re-run. Offending paths:"
    git -C "$d" status --porcelain 2>/dev/null | sed 's/^/    /' >&2
    exit 2
  fi
  # Only known runtime artifacts are dirty → commit them so the rebase below isn't blocked
  # (self-heal, #111). Commit ONLY (no push) — the existing reconcile paths below replay + publish
  # them. Committing locally turns a behind-only state into diverged, so recompute ahead/behind
  # afterwards. Each pathspec is best-effort: a path that isn't dirty is a harmless no-op.
  ( cd "$d"
    _pf_paths=()
    for p in governor/improvements.md governor/.ticket-seq governor/escalations.md governor/pending-escalations.json; do
      git add -- "$p" 2>/dev/null && _pf_paths+=("$p") || true
    done
    # #375 sweep-guard: commit ONLY the allowlist paths that exist (pathspec), never a bare
    # `git commit`. The old "at run-start nothing else should be staged" assumption is FALSE in a
    # shared checkout — a co-tenant's staged .claude/context WIP was present and a bare commit swept
    # it onto origin/main (incident 2026-07-17). Pathspec-scoping is structurally sweep-proof and
    # still tolerates a clean allowlist path (git just omits it; `|| true` covers "nothing to commit").
    [[ ${#_pf_paths[@]} -gt 0 ]] && git commit -q -m "chore(govern): commit uncommitted runtime artifacts before reconcile (preflight self-heal #111)" -- "${_pf_paths[@]}" 2>/dev/null || true
  ) || true
  govern::log "preflight: committed uncommitted governor runtime artifacts so the rebase isn't blocked (#111 self-heal)"
  read -r behind ahead < <(git -C "$d" rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo "0	0")
  behind="${behind:-0}"; ahead="${ahead:-0}"
fi

if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
  govern::log "preflight: local main == origin/main (clean base for the harness lane)"; exit 0
fi

if [[ "$ahead" == "0" ]]; then
  # strictly behind → fast-forward is always safe.
  if git -C "$d" pull --ff-only origin main >/dev/null 2>&1; then
    govern::log "preflight: local main was $behind behind origin/main — fast-forwarded"; exit 0
  fi
  govern::log "preflight: local main $behind behind but ff-pull FAILED (dirty tree?) — refusing to start the harness lane"; exit 2
fi

if [[ "$behind" == "0" ]]; then
  # strictly ahead → publish the unpushed local meta commits.
  if git -C "$d" push origin HEAD:main >/dev/null 2>&1; then
    govern::log "preflight: published $ahead unpushed meta commit(s) — local main == origin/main"; exit 0
  fi
  # push rejected though the fetch showed us not-behind → origin advanced between fetch and push;
  # fall through to rebase-and-push below.
  govern::log "preflight: push of $ahead-ahead local main rejected — origin advanced; rebasing"
fi

# Diverged (ahead AND behind), or an ahead-only push lost a race: rebase local meta commits onto
# origin/main, then push.
if git -C "$d" pull --rebase origin main >/dev/null 2>&1 && git -C "$d" push origin HEAD:main >/dev/null 2>&1; then
  govern::log "preflight: local main DIVERGED (ahead=$ahead behind=$behind) — rebased meta commits onto origin/main + pushed"; exit 0
fi
git -C "$d" rebase --abort >/dev/null 2>&1 || true   # restore the pre-rebase working state
govern::log "preflight: local main DIVERGED from origin/main (ahead=$ahead behind=$behind) and auto-reconcile FAILED (rebase conflict or rejected push). Reconcile manually: cd '$d' && git pull --rebase origin main && git push — then re-run."
exit 2
