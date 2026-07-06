---
description: The self-improvement channel, pull direction. Pulls the latest hub templates into THIS workspace so mechanism improvements ported back from other fleets land here. Component-by-component bump via scaffold.sh — refreshes mechanism scripts, preserves scripts/lib/workspace.sh, updates the harness-version stamp, runs the no-auth verifiers. Idempotent; safe to re-run. Read-only when the workspace is already at the hub VERSION.
allowed-tools: Bash, Read
---

# /shiploop:update

**The pull direction of the harness-code update channel.** Reconciles this workspace against the
latest installed hub — the ongoing-maintenance path after `/shiploop:setup` has scaffolded
the workspace once. Think of it as `git pull` for harness code: `scaffold.sh` is the machinery, this
command wraps it into a one-command action with reachability resolution + safety guards +
verification.

## What it does (procedure)

1. **Locate the hub** (same priority order as `/setup` — see "Locate the plugin" in that command).
2. **Verify workspace preconditions** — you're in a meta-repo workspace, the harness paths aren't
   dirty, no governor is running.
3. **Cheap version + diff check** (writes nothing).
4. **Component-by-component bump** via `scaffold.sh --component <name> --yes` — refreshes mechanism
   scripts, PRESERVES `scripts/lib/workspace.sh` (never overwritten without an explicit ask).
5. **Run the no-auth verifiers** — `config-check.sh` + `bash -n` sweep + stale-relocations warning.
6. **Update the `.harness-version` stamp** (scaffold does this on every run — no separate step).
7. **Report** a concise per-component `in-sync | bumped | skipped` summary.

## Phase 0 — Locate the hub

Templates + `scaffold.sh` live in the same directory. Resolve `HUB` in this priority order:

1. `${CLAUDE_PLUGIN_ROOT}` — set when this command runs as a plugin.
2. `${GOVERN_UPSTREAM_HARNESS_DIR}` sourced from `scripts/lib/workspace.sh` — an operator with a local
   fork clone pointed the workspace at it for the sync channel; the same clone is a valid hub source.
3. `~/.claude/skills/shiploop/` — legacy clone-into-skills install.
4. Glob `~/.claude/plugins/**/shiploop/VERSION` — plugin-cache install.

If none resolve, STOP and print:

```
Cannot locate the shiploop hub.

Options:
  - Install as a plugin (recommended):
      /plugin marketplace add anshss/shiploop
      /plugin install shiploop@shiploop
  - Point at a local clone by exporting one of:
      CLAUDE_PLUGIN_ROOT=/path/to/shiploop   (env)
      GOVERN_UPSTREAM_HARNESS_DIR=/path/to/shiploop   (workspace.sh)
```

Otherwise let `SCAFFOLD=$HUB/scaffold.sh`. Confirm `bash "$SCAFFOLD" --version` prints a version and
that `$HUB/templates` is a directory. If either check fails, treat the hub as unresolvable and print
the same guidance.

## Phase 0.5 — Hub freshness probe (network, best-effort)

`/update` is otherwise a **no-network LOCAL reconcile** — it compares this workspace against the hub
clone on disk. But that clone can itself be behind GitHub: if it is, `/update` would happily report
"already at hub VERSION" while both the clone AND this workspace are stale (observed live: a clone 1
commit behind, missing a merged PR). Nothing else nudges the device clone to refresh — workspaces get
doctor staleness warnings; the clone has no equivalent. This probe closes that gap (K5).

Only when `$HUB` is a git clone (`git -C "$HUB" rev-parse --git-dir` succeeds — a plugin-cache or
tarball install may not be), do a **best-effort** upstream check. It must degrade gracefully with no
network and never block the update:

```bash
if git -C "$HUB" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$HUB" fetch -q origin 2>/dev/null; then
    behind="$(git -C "$HUB" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
    if [ "${behind:-0}" -gt 0 ]; then
      echo "⚠ hub clone is $behind commit(s) BEHIND origin/main ($HUB)."
      echo "  This local reconcile can only pull what the clone already has."
      echo "  Refresh it first (recommended):  git -C \"$HUB\" pull --ff-only origin main"
    fi
  else
    echo "── /update: offline or no 'origin' remote — skipping hub freshness probe (local reconcile only) ──"
  fi
fi
```

If the clone is behind, WARN with the count and OFFER to `git -C "$HUB" pull --ff-only origin main`
before continuing — do NOT auto-pull (the operator may be pinned intentionally). If the operator
declines, proceed against the clone as-is and note in the Phase 5 report that the hub itself may be
stale. Offline / non-git hub → skip silently and carry on with the local reconcile.

## Phase 1 — Workspace preconditions

Must be a meta-repo workspace: `scripts/lib/workspace.sh` exists. Else STOP and tell the operator to
run `/shiploop:setup` first (fresh scaffold).

**Branch guard.** Root must be on its default branch (`main`) — same rationale as setup.md Phase 0.5.
If not, STOP and offer to `git switch` first.

**Dirty-tree guard.** `git status --porcelain` on the harness-owned paths — `scripts`, `.githooks`,
`governor`, `.claude/settings.json`, `.claude/commands`, `package.json`, `.gitignore` — must be
clean. If dirty, STOP and print the paths. The operator commits/stashes first; the command overwrites
mechanism scripts and would clobber uncommitted changes to them.

**Governor lock guard.** If the single-run lock `governor/.govern.lock` is held, or any per-ticket
claim lock `governor/.locks/ticket-<N>` exists (both under `governor/`, never under `scripts/govern/`),
a live governor is running — STOP and tell the operator to wait for the run to end (or reclaim a stale
lock with `bash scripts/govern/lock-release.sh`). A bump that overwrites `govern/lib/common.sh` while a
governor run is live is a real hazard — the reference-instance doctrine documents this.

## Phase 2 — Version + diff check (no writes)

```bash
HUB_V="$(bash "$SCAFFOLD" --version)"
STAMP_V="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' scripts/lib/.harness-version 2>/dev/null || echo unknown)"
echo "hub:    $HUB_V"
echo "stamp:  $STAMP_V"
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --diff-only    # exit 3 = drift, 0 = clean
```

Save the diff-only output. If it exits 0 AND stamps match, the workspace is fully in sync. Print
`── /update: workspace is up to date (hub=$HUB_V) ──` and stop; nothing to do.

Otherwise proceed to Phase 3 with the list of `behind` components as the bump plan.

## Phase 3 — Component-by-component bump

Bump every mechanism component reported behind. These are safe to refresh without an
interview — they only read `workspace.sh`. The loop MUST cover every component `--diff-only`
tracks (`core-scripts worktrees govern githooks commands workflows`), or an untracked component
loops "behind" forever (N5):

```bash
for c in core-scripts worktrees govern githooks commands workflows; do
  bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component "$c" --yes
done
# seeds: only fills absent seeds (never overwrites operator data).
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component seeds --yes
# settings-merge: idempotent jq-driven hook insertion into an EXISTING settings.json.
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component settings-merge
```

**Never bump these without the operator's explicit ask** — they carry per-workspace customization:

- `workspace-sh` — `scripts/lib/workspace.sh` (config sink). If new knobs landed in the hub, warn and
  point at the diff; do NOT overwrite. To force the regen, the operator runs
  `bash "$HUB/scaffold.sh" --workspace-dir . --component workspace-sh --yes` themselves after saving
  their edits. This is a hard preservation guarantee — the update path never silently overwrites
  their config.
- `package-json` — carries operator-added scripts. Same rule: warn, don't overwrite.
- `settings` (full) — carries operator hook additions. Use `settings-merge` (already run above) to
  add missing harness stanzas without touching the rest of the file.
- `gitignore` — intentionally **not** a bump target and intentionally absent from the `--diff-only`
  drift set. `.gitignore` is placeholder-filled (sub-repo names, lockfile ignores per package
  manager) and **merge-only** — `component_gitignore` appends any missing scaffolded lines but never
  overwrites operator entries, so a byte-for-byte template compare would false-report drift. New
  scaffolded ignore lines land automatically the next time any interview-driven scaffold runs; there
  is nothing to reconcile here.

The knob-type migration guard (v1.1.0 → v1.2.0 array→string) inside `component_workspace_sh` prints
the mechanical migration when it detects the legacy shape. If it fires, surface it in the report.

## Phase 3b — Re-assert sub-repo commit hooks

The `githooks` component above refreshes the harness root's `.githooks/` — but each sub-repo is an
INDEPENDENT git repo that does NOT inherit the root's `core.hooksPath`. A framework reinstall in a
sub-repo (husky's `prepare` on `npm install`) silently regenerates its hooks dir and WIPES the
attribution/pre-commit hooks the harness installed there. `/update` therefore RE-RUNS the installers
across every sub-repo (not fresh-setup-only) so a wiped hook is restored on each converge:

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
  install_subrepo_attribution_hook "$(pwd)" "$(pwd)/$repo"
  install_subrepo_pre_commit_hook "$(pwd)" "$(pwd)/$repo"
done
```

The pre-commit installer is chain-safe (a non-ours pre-commit is left in place) and a no-op unless
`WSP_LINT_FIX_CMD` is set. `doctor.sh`'s "sub-repo commit hooks" section flags any sub-repo whose
resolved hook still differs from `.githooks/` — run this step when it warns.

## Phase 3.5 — Advance the sync marker (converge bookkeeping)

A hub→workspace bump REWRITES mirrored mechanism scripts, so the converge commit you're about to
make touches mirrored files. `sync-templates.sh` is marker-based, so it would otherwise count that
pull as harness→hub "drift" — a `/shiploop:push` run would then try to port the hub's own code back
to the hub (`drift_commits`' content-aware skip catches most of this, but the marker is the durable
fix). Advance the marker THROUGH the converge so a pull doesn't masquerade as unported local work.

**Guard — only auto-advance when there was NO pre-existing local drift.** Record the drift state
BEFORE the Phase-3 bump:

```bash
bash scripts/govern/sync-templates.sh --check >/dev/null 2>&1; PRE_DRIFT=$?   # 3 = had local drift, 0 = clean
```

Then, AFTER the operator commits the converge (Phase 5), advance the marker to that commit **only if
`PRE_DRIFT` was 0**:

```bash
if [ "${PRE_DRIFT:-0}" -eq 0 ]; then
  bash scripts/govern/sync-templates.sh --mark HEAD    # marks THROUGH the converge commit
else
  echo "⚠ pre-existing unported local drift — NOT auto-advancing the sync marker."
  echo "  Run /shiploop:push to port your local mechanism improvements first, then --mark by hand."
fi
```

If `PRE_DRIFT` was 3 there were genuine local mechanism improvements not yet pushed to the hub;
auto-advancing would silently bury them. Warn and leave the marker for `/shiploop:push`.

## Phase 4 — Verify (no auth needed)

Cheap no-auth smoke — resolves every knob + helper, prints them, exits nonzero on any missing
required:

```bash
bash scripts/govern/config-check.sh
```

Full `bash -n` verify + stale-relocation check:

```bash
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes --verify
```

Optionally the full govern test suite (per setup.md B3's pipe-stall-safe idiom for headless envs).

**`dry-run.sh` spawns a live authenticated Claude worker** — from inside a nested Claude session or
a headless env with no worker auth, it will fail. That's the auth caveat, not an update regression.

## Phase 5 — Report

Print a compact summary:

```
── /shiploop:update ──
Hub:         $HUB_V   ($HUB)
Stamp:       $STAMP_V → $HUB_V
Components:
  core-scripts   bumped     (N files)
  worktrees      in-sync
  govern         bumped     (M files)
  githooks       in-sync
  commands       bumped     (K files)
  seeds          in-sync
  settings-merge idempotent (no changes)
Preserved:   scripts/lib/workspace.sh, package.json, .claude/settings.json (except added hook stanzas)
Verifiers:   config-check ok · bash -n ok · relocations ok
Next:        review the diff, commit tooling paths explicitly:
             git add scripts .githooks governor package.json .claude/settings.json .claude/commands
             git commit -m "chore(harness): converge to shiploop v$HUB_V"
```

Stop. Do not push, do not commit. The operator reviews the diff and commits themselves — a bump
touches many files and they may want to split it or write a specific commit message.

## Guarantees

- **Idempotent.** Re-running when everything is in sync prints "up to date" and exits.
- **`workspace.sh` preserved.** Never overwritten by `/update`. New knobs surface as warnings.
- **No network required.** Everything runs against the local hub clone / plugin install. No `gh`,
  no `git fetch` — this is a LOCAL reconcile of files.
- **Fail-closed on dirty tree / live governor.** Refuses to proceed rather than clobber your work.

## Pair with the push direction

Once you've made improvements to a mechanism script inside this workspace and want to contribute
them back to the hub, run `/shiploop:push` — the mirror of this command. It reuses the same
`GOVERN_UPSTREAM_HARNESS_DIR` knob to find the hub clone and opens a PR against your fork.
