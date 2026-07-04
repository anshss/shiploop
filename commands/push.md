---
description: Push your workspace's mechanism-script improvements back to the hub. Detects drift (harness→template) with sync-templates.sh, then invokes sync-port.sh to genericize the changes via a headless porter and open a PR against your fork for HUMAN review. Reuses the existing fail-closed sync-port pipeline — never auto-merges.
allowed-tools: Bash, Read
---

# /shiploop:push

**The push direction of the harness-code update channel.** Reconciles the hub against improvements
you've made locally to mechanism scripts inside THIS workspace. Think of it as `git push` for
harness code: `sync-port.sh` is the machinery (already generalized in v1.2.0), this command wraps
it into a one-command action for interactive use.

Companion to `/shiploop:update` (pull). The two commands close the loop on fleet drift.

## What it does (procedure)

1. **Preconditions:** `GOVERN_UPSTREAM_HARNESS_REPO` set in `workspace.sh`; the workspace scaffolded
   from v1.2.0 or later (so `scripts/govern/sync-port.sh` is present); a local hub clone reachable.
2. **Drift detection** via `scripts/govern/sync-templates.sh --check` — mirrored files you've
   changed vs the last sync marker.
3. If drift → **invoke `scripts/govern/sync-port.sh`** (the existing porter). It:
   - Cuts a branch off `origin/main` in the hub clone.
   - Spawns a headless porter that genericizes your changes (strips your identity strings, adds
     placeholders like `__META_NAME__`, `__GITHUB_ORG__`).
   - Validates: `bash -n` on changed shell files + forbidden-identity-strings gate on ADDED lines +
     scaffold-test-suite baseline diff.
   - On any gate failure, files an escalation and exits non-zero. NEVER pushes an unvalidated port.
   - On pass, opens a PR against your fork of the hub for **HUMAN review**.
4. **Report** the PR URL (if any) and the marker state.

## Why HUMAN review, never auto-merge

`sync-port.sh` in v1.2.0 gained a `--no-merge` mode for safe first rollouts. `/push` invokes it
with `--no-merge` unconditionally — this is an INTERACTIVE command driven by an operator, and the
whole point is a human reviews the genericized port before it lands on the global skill. Even if
`--no-merge` weren't set, the hub's three-factor auto-merge guard (own-author + own-branch-pattern
+ no-forks) would block the governor from merging it. Both belts, both suspenders.

Workspace-specific files (`scripts/lib/workspace.sh`, `package.json`, repo lists, `governor/`
operator-data files) are intentionally NEVER pushed. `sync-templates.sh` filters them out at the
git-pathspec level. This command's summary tells the operator so — no surprises.

## Phase 0 — Preconditions

### Must be in a meta-repo workspace

`scripts/lib/workspace.sh` exists AND `scripts/govern/sync-port.sh` + `scripts/govern/sync-templates.sh`
exist. If either sync script is missing, the workspace was scaffolded before v1.2.0 — instruct the
operator:

```
This workspace is missing scripts/govern/sync-{port,templates}.sh — scaffold predates v1.2.0.
Run /shiploop:update first to install the sync channel, then re-run /shiploop:push.
```

### `GOVERN_UPSTREAM_HARNESS_REPO` must be set

Source `scripts/lib/workspace.sh` (in a subshell) and check. If empty, STOP and print:

```
GOVERN_UPSTREAM_HARNESS_REPO not set in scripts/lib/workspace.sh — the sync channel is inert.

To enable /shiploop:push:
  1. Fork https://github.com/anshss/shiploop on GitHub.
  2. Clone your fork locally (call it $FORK_DIR).
  3. Edit scripts/lib/workspace.sh and set:
       GOVERN_UPSTREAM_HARNESS_REPO="shiploop"
       GOVERN_UPSTREAM_HARNESS_DIR="$FORK_DIR"
  4. Re-run /shiploop:push.
```

### Local hub clone must be reachable

`sync-port.sh` reads `GOVERN_UPSTREAM_HARNESS_DIR` (or `wsp_repo_localdir` from workspace.sh) to
locate the templates repo working dir. If the resolved directory isn't a git repo, `sync-port.sh`
will itself escalate with a clear reason. That's fine — surface its output.

### `gh` must be authenticated

`gh auth status` must succeed. `sync-port.sh` calls `gh pr create` and errors out clean if not.

## Phase 1 — Dry-run first (recommended by default)

Unless the operator passed `--run` or `--yes` in `$ARGUMENTS`, run the dry-run first:

```bash
bash scripts/govern/sync-port.sh --dry-run
```

The dry-run prints the plan: drifted mirrored files, the branch it WOULD cut, the forbidden identity
strings that will gate the porter, and the templates root. It touches nothing. Print the output and
ask the operator to confirm before proceeding.

If the dry-run reports no drift (`templates in sync — nothing to port.`), stop. Print:

```
── /shiploop:push ──
No drift to port — every mirrored file in this workspace matches the hub through <marker-sha>.
Nothing to do.
```

## Phase 2 — Full run

On operator confirm (or when `--run` was passed), invoke the full porter with `--no-merge`:

```bash
GOVERN_SYNC_PORT_NO_MERGE=1 bash scripts/govern/sync-port.sh
```

`sync-port.sh` handles everything from here:

- Single-owner lock (`scripts/govern/.locks/sync-port`) — if held by another run, exits 0 with a
  friendly message and no work.
- Fail-closed EXIT trap that restores the hub-clone worktree to `main` on any error, so a failed
  port doesn't strand you on a half-baked branch.
- If the porter escalates or leaks a forbidden identity string, files a NUMBERED escalation in
  `governor/escalations.md ## Open` (fingerprint-deduped by branch, so repeated failed runs against
  the same drift produce ONE entry with a `Last-seen` bump).

## Phase 3 — Report

The porter's stdout carries the PR URL on success. Surface it verbatim, then print a compact summary:

```
── /shiploop:push ──
Drifted files:  <N>
Porter:         ported cleanly · gate PASSED
PR:             <url>   (opened for HUMAN review — NOT merged)
Next:           review the PR on GitHub. On approval + merge, the local marker advances the next
                time /push runs (or when the governor auto-triggers sync-port at run-end).
Preserved:      workspace.sh, package.json, repo lists — never pushed.
```

If the porter escalated, surface the escalation reason and its number in `governor/escalations.md`,
then STOP. The operator inspects and resolves per the standard escalations flow.

## Failure modes and what each means

| Symptom | What it means | What to do |
|---|---|---|
| `feature off` — `GOVERN_UPSTREAM_HARNESS_REPO` empty | Sync channel is inert | Set the knobs per Phase 0. |
| `not a git repo` — hub clone missing | `GOVERN_UPSTREAM_HARNESS_DIR` wrong | Point at the actual clone. |
| `porter did not port cleanly` — status not `ported` | Headless porter escalated | Read the escalation; port by hand if needed. |
| `FORBIDDEN identity string` — leak in ADDED lines | Porter left workspace identity in a template | Read the leak; retry after fixing the source. |
| `bash -n' syntax error` — changed template broke | Porter produced a bad shell file | Escalation carries the file list; fix by hand. |
| `scaffold test` — NEWLY broke a suite test | Port regressed a govern invariant | Read `/tmp/scaffold-ported-*.log`; the port needs work. |
| `empty diff` / `UNCOMMITTED changes` | Porter half-finished | Escalation carries the strand info; investigate. |

## Guarantees

- **Never merges.** `--no-merge` is unconditional in this command.
- **Reuses sync-port.sh** — no duplicated logic. Same gates, same escalation flow, same lock, same
  fingerprint dedup as the governor's auto-triggered run-end path.
- **Workspace files preserved.** `sync-templates.sh` filters out `workspace.sh`, `package.json`,
  operator-owned governor files.
- **No side effects on dry-run** — no branch, no PR, no marker change.

## Pair with the pull direction

`/shiploop:update` is the reverse channel — pull the latest hub templates INTO this
workspace. Same reachability resolution (`GOVERN_UPSTREAM_HARNESS_DIR` participates).
