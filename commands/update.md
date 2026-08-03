---
description: Pull direction: bumps this workspace's scripts to match the latest hub template. Opposite of /push.
allowed-tools: Bash, Read
---

# /shiploop:update

The **pull direction** of the harness-code update channel — `git pull` for harness code. Reconciles
this workspace against the latest installed hub, the ongoing-maintenance path after
`/shiploop:setup` has scaffolded once. `scaffold.sh` is the machinery; this command wraps it with
reachability resolution + safety guards + verification.

## Procedure
1. **Locate the hub** (same priority as `/setup`, see "Locate the plugin" there).
2. **Verify preconditions** — meta-repo workspace, harness paths not dirty, no governor running.
3. **Cheap version + diff check** (writes nothing).
4. **Component-by-component bump** via `scaffold.sh --component <name> --yes` — PRESERVES
   `scripts/lib/workspace.sh` (never overwritten without explicit ask).
5. **Run no-auth verifiers** — `config-check.sh` + `bash -n` sweep + stale-relocations warning.
   The bump itself also **purges retired files**: every writer run applies `templates/lib/purge.txt`,
   so files an older shiploop installed and no longer ships are deleted from this workspace. Report
   what went, since a purge can remove something the operator was still opening by habit.
6. **Update `.harness-version` stamp** (scaffold does this every run).
7. **Report** a concise per-component `in-sync | bumped | skipped` summary.

## Phase 0 — Locate the hub

Resolve `HUB` in priority order:
1. `${CLAUDE_PLUGIN_ROOT}` (plugin run)
2. `${GOVERN_UPSTREAM_HARNESS_DIR}` from `scripts/lib/workspace.sh` (operator's local fork clone)
3. `~/.claude/skills/shiploop/` (legacy clone-into-skills)
4. Glob `~/.claude/plugins/**/shiploop/VERSION` (plugin-cache install)

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

`SCAFFOLD=$HUB/scaffold.sh`. Confirm `bash "$SCAFFOLD" --version` prints a version and `$HUB/templates`
is a directory — either check failing means the hub is unresolvable; print the same guidance.

## Phase 0.5 — Hub freshness probe (network, best-effort)

`/update` is otherwise a no-network LOCAL reconcile — it compares this workspace against the hub clone
on disk, which can itself be behind GitHub (observed: a clone 1 commit behind a merged PR would report
"already at hub VERSION" while both are stale). Only when `$HUB` is a git clone
(`git -C "$HUB" rev-parse --git-dir` succeeds), do a best-effort upstream check that degrades
gracefully with no network and never blocks the update:

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

If behind, WARN with the count and OFFER to pull `--ff-only` — do NOT auto-pull (operator may be
pinned intentionally). If declined, proceed against the clone as-is and note in Phase 5 that the hub
itself may be stale. Offline / non-git hub → skip silently.

## Phase 1 — Workspace preconditions

Must be a meta-repo workspace (`scripts/lib/workspace.sh` exists) — else STOP, tell operator to run
`/shiploop:setup` first.

**Branch guard.** Root must be on its default branch (`main`) — same rationale as setup.md Phase 0.5.
Not on it → STOP, offer `git switch` first.

**Dirty-tree guard.** `git status --porcelain` on harness-owned paths (`scripts`, `.githooks`,
`governor`, `.claude/settings.json`, `.claude/commands`, `package.json`, `.gitignore`) must be clean —
else STOP and print the paths; the command overwrites mechanism scripts and would clobber uncommitted
changes.

**Governor lock guard.** If `governor/.govern.lock` or any `governor/.locks/ticket-<N>` claim lock is
held, a live governor is running — STOP, tell the operator to wait (or reclaim a stale lock with
`bash scripts/govern/lock-release.sh`). A bump overwriting `govern/lib/common.sh` mid-run is a real
hazard.

## Phase 2 — Version + diff check (no writes)

```bash
HUB_V="$(bash "$SCAFFOLD" --version)"
STAMP_V="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' scripts/lib/.harness-version 2>/dev/null || echo unknown)"
echo "hub:    $HUB_V"
echo "stamp:  $STAMP_V"
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --diff-only    # exit 3 = drift, 0 = clean
```

Exit 0 + stamps match → print `── /update: workspace is up to date (hub=$HUB_V) ──` and stop. Else
proceed to Phase 3 with the `behind` components as the bump plan.

## Phase 3 — Component-by-component bump

Safe to refresh without an interview — these only read `workspace.sh`. Must cover every component
`--diff-only` tracks, or an untracked one loops "behind" forever:

```bash
for c in core-scripts worktrees govern githooks commands workflows; do
  bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component "$c" --yes
done
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component config-merge --yes
```

`config-merge` is the **merge tier** — the components that converge an EXISTING workspace's config.
None are byte-comparable, and until this landed none were reachable from `/update` at all, so a hub
release that added an npm entrypoint or a `GOVERN_*` knob reached only brand-new installs. It bundles
`seeds`, `readme`, `gitignore`, `package-json-merge`, `workspace-sh-merge`, `settings-merge`.
Every one is additive and idempotent: a second run is a byte-level no-op. What each does:

| Component | Converges | Never does |
|---|---|---|
| `package-json-merge` | adds harness script keys the hub ships and this `package.json` lacks (`govern:validations`, `govern:dry-run`, …) plus `dev:<repo>` per sub-repo | overwrite a key you defined, remove a key, reorder yours |
| `workspace-sh-merge` | appends `GOVERN_*` knobs added to the hub seed since you scaffolded, each with its doc comment | touch an existing knob, your values, or the identity fields (`REPOS`, `GITHUB_ORG`, `ROOT_PM`, …) |
| `settings-merge` | adds missing harness hooks **and repairs** a harness hook whose command string or timeout drifted from canonical | touch a hook whose command points outside this workspace (yours) |
| `seeds` | fills an absent seed; upgrades one that is **byte-identical to a version shiploop shipped** (proof it was never edited) | modify a seed with even one byte of local content |
| `gitignore` | appends missing patterns | remove or reorder your lines |
| `readme` | writes `README.md` when absent, using the real PM + sub-repo list read from `workspace.sh` | overwrite an existing README |

The seed rule is the load-bearing one. A hub seed trim (v1.14.0 cut `CLAUDE.md` 5,895 → 4,417 B) is
worth propagating, but a real workspace's `CLAUDE.md` accumulates every promoted lesson — measured on
one live fleet it had grown to 47 KB. Overwriting that to "save bytes" would be catastrophic, so the
upgrade is gated on a sha256 hit against `templates/lib/seed-hashes.txt`, which records every version
of every seed the hub has ever shipped. Byte-identity is the entire safety argument: no diff, no merge,
no heuristic. Anything else is left untouched and silent.

**Deletions already ride a separate channel** and need nothing here: `templates/lib/purge.txt` lists
every path shiploop used to install and no longer ships, and `purge_removed` applies it on EVERY
writer run — so the v1.15.0 install-footprint cut (7 cross-repo wrappers, 2 commands, the 134-file
hub-only test suite) is removed from an old workspace by the Phase-3 loop above. CI guard
`purge-manifest-complete` fails any PR that deletes a template without registering its installed path.

**One-time (v1.10.0): relocate the validation sink.** Moved from `.claude/context/` to
`.claude/shiploop/validation/`. A workspace converging past v1.10.0 must move its existing sink once,
BEFORE running the governor:

```bash
[ -e validation/flows.md ] && { mkdir -p .claude/shiploop/validation; git mv validation/flows.md .claude/shiploop/validation/flows.md; }
[ -e validation/evidence ] && git mv validation/evidence .claude/shiploop/validation/evidence
[ -d .claude/context/validation ] && { mkdir -p .claude/shiploop/validation; git mv .claude/context/validation/* .claude/shiploop/validation/ 2>/dev/null; rmdir .claude/context/validation 2>/dev/null; }
```
Refs citing `.claude/context/validation/*.md` will flag as dangling via `lint-validation-refs.sh`
(Stop hook) until repointed.

**Never run the WHOLE-FILE writer for these without the operator's explicit ask** — they carry
per-workspace customization, and the full component regenerates rather than merges. The merge-tier
counterpart (run above, in `config-merge`) is always safe; only the full writer needs an ask:

| Full writer (needs explicit ask) | Safe merge-tier counterpart |
|---|---|
| `workspace-sh` — regenerates the config sink from the interview answers | `workspace-sh-merge` |
| `package-json` — rewrites the whole file | `package-json-merge` |
| `settings` — rewrites the whole hook block | `settings-merge` |
| `readme` (only overwrites if you pass `--yes` on an existing file) | `readme` (no-ops when present) |

Force a full regen with e.g.
`bash "$HUB/scaffold.sh" --workspace-dir . --component workspace-sh --yes` after saving your edits.

`gitignore` stays excluded from `--diff-only` — it is merge-only by construction, so a byte compare
would false-report drift forever.

The knob-type migration guard (v1.1.0 → v1.2.0 array→string, inside `component_workspace_sh`) prints
the mechanical migration if it detects the legacy shape — surface it in the report.

## Phase 3b — Re-assert sub-repo commit hooks

`githooks` above only refreshes the harness root's `.githooks/`. Each sub-repo is an INDEPENDENT git
repo not inheriting `core.hooksPath`; a framework reinstall (husky's `prepare`) silently WIPES the
attribution/pre-commit hooks installed there. `/update` re-runs the installers across every sub-repo
every converge (not just fresh-setup) to restore a wiped hook:

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
  install_subrepo_attribution_hook "$(pwd)" "$(pwd)/$repo"
  install_subrepo_pre_commit_hook "$(pwd)" "$(pwd)/$repo"
done
```
The pre-commit installer is chain-safe (leaves a non-ours pre-commit in place) and a no-op unless
`WSP_LINT_FIX_CMD` is set. `doctor.sh` flags a sub-repo whose resolved hook still differs — re-run when
it warns.

## Phase 3.5 — Advance the sync marker

A hub→workspace bump rewrites mirrored mechanism scripts, so the converge commit touches mirrored
files. `sync-templates.sh` is marker-based and would otherwise count the pull as harness→hub "drift" —
a later `/shiploop:push` would try to port the hub's own code back to itself. Advance the marker
through the converge so a pull doesn't masquerade as unported local work.

**Guard — only auto-advance when there was NO pre-existing local drift.** Record drift state BEFORE
the Phase-3 bump:

```bash
bash scripts/govern/sync-templates.sh --check >/dev/null 2>&1; PRE_DRIFT=$?   # 3 = had local drift, 0 = clean
```

AFTER the operator commits the converge (Phase 5), advance the marker only if `PRE_DRIFT` was 0:

```bash
if [ "${PRE_DRIFT:-0}" -eq 0 ]; then
  bash scripts/govern/sync-templates.sh --mark HEAD    # marks THROUGH the converge commit
else
  echo "⚠ pre-existing unported local drift — NOT auto-advancing the sync marker."
  echo "  Run /shiploop:push to port your local mechanism improvements first, then --mark by hand."
fi
```
`PRE_DRIFT=3` means genuine unpushed local mechanism improvements exist; auto-advancing would silently
bury them — warn and leave the marker for `/shiploop:push`.

## Phase 4 — Verify (no auth needed)

```bash
bash scripts/govern/config-check.sh                                              # cheap no-auth smoke
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes --verify # bash -n + stale-relocation check
```
The govern test suite is hub-only (never installed into a workspace) — there is nothing to run here.

**`dry-run.sh` spawns a live authenticated Claude worker** — inside a nested Claude session or headless
env with no worker auth it will fail. That's the auth caveat, not an update regression.

## Phase 5 — Report

```
── /shiploop:update ──
Hub:         $HUB_V   ($HUB)
Stamp:       $STAMP_V → $HUB_V
Mechanism:
  core-scripts   bumped     (N files)
  worktrees      in-sync
  govern         bumped     (M files)
  githooks       in-sync
  commands       bumped     (K files)
  workflows      in-sync
Config (merge tier):
  package.json   +govern:validations, +govern:dry-run
  workspace.sh   +GOVERN_PARALLEL_DEFAULT   ← review the default, it changes govern concurrency
  settings.json  +1 hook, 1 stale command repaired
  seeds          CLAUDE.md left as-is (customized) · CLAUDE-APPENDIX.md upgraded (was unedited)
  .gitignore     +2 lines
  README.md      created
Preserved:   every operator-defined package.json script, every existing workspace.sh knob value,
             every hook pointing outside this workspace, every seed carrying local edits
Purged:      <retired paths removed this run, or "none">
Verifiers:   config-check ok · bash -n ok · relocations ok
Next:        review the diff, commit tooling paths explicitly:
             git add scripts .githooks governor package.json .claude/settings.json .claude/commands
             git commit -m "chore(harness): converge to shiploop v$HUB_V"
```
Stop. Do not push, do not commit — the operator reviews the diff and commits themselves (may want to
split it or write a specific message).

Call out a `workspace.sh` knob append explicitly — a new knob can change runtime behavior (
`GOVERN_PARALLEL_DEFAULT` sets governor concurrency), so the operator should see and tune it rather
than discover it on the next run.

## Guarantees
- **Idempotent.** Re-running when in sync prints "up to date" and exits. Every merge-tier component
  is a byte-level no-op on a second run — verified by test-update-config-converge.sh.
- **`workspace.sh` values preserved.** Existing knobs are never rewritten; only absent ones are
  appended, with their doc comments.
- **Operator content is never lost.** No package.json key you defined is overwritten, no hook of yours
  is touched, and no seed carrying local edits is modified — a seed upgrade requires a sha256 match
  against a version the hub actually shipped.
- **No network required.** Runs against the local hub clone / plugin install; no `gh`, no `git fetch`.
- **Fail-closed on dirty tree / live governor.** Refuses rather than clobbers your work.

## Pair with the push direction

Once you've improved a mechanism script here and want to contribute it back, run `/shiploop:push` —
the mirror of this command, reusing the same `GOVERN_UPSTREAM_HARNESS_DIR` knob to find the hub clone
and open a PR against your fork.
