# Changelog

## 1.2.0 — 2026-07-05

Update-channel release. Ships the two-way channel that lets an adopter know a bump is due AND lets them contribute back — plus a batch of upgrade-friction fixes distilled from three real convergence runs (claude-keepalive, splito, tokenjam).

### Added — the update channel core
- **`VERSION` file at hub root.** Records the hub's current version (`1.2.0`); readable by `scaffold.sh --version`. Existed nowhere before this release — convergence reports depended on a floating string in setup.md.
- **Workspace stamp.** `scaffold.sh` writes `scripts/lib/.harness-version` on every run and every component bump. The stamp is the version this workspace was last synced against.
- **Staleness warning in `doctor.sh` + `govern-health.sh`.** Both compare the stamp against the installed hub's `VERSION` (resolved via `CLAUDE_PLUGIN_ROOT` → `~/.claude/skills/…` → the plugin cache). If behind: "harness N releases behind — run the setup upgrade". Graceful when the hub is unresolvable (offline / cache-only install): degrades to a soft "cannot compare" notice, never an error.

### Added — generalized sync channel
- **`templates/govern/sync-templates.sh`.** Ports the drift reporter into the templates. Detects which live files have drifted from the templates repo (by MIRROR PRESENCE — files with a template counterpart are drift-relevant, workspace-specific files are filtered out). Read the file — it documents the mapping (govern, worktree, lib, .githooks, .claude/commands, hook scripts, CLAUDE.md seed) + the exclusions (workspace.sh config sink, runtime artifacts). Regression-locked by `test-sync-templates.sh` (25 assertions).
- **`templates/govern/sync-port.sh`.** Auto porter that opens + validates + merges a template-sync PR. Fail-closed at every step: bash -n on changed shell files, forbidden-identity-strings gate on ADDED diff lines (org + repo names + `$META_NAME` + `$GOVERN_FORBIDDEN_EXTRA`, all lowercased/deduped), scaffold suite baseline-diff, empty-diff / strand / uncommitted-work guards, EXIT-trap restore of the templates repo to `main`, escalation dedup by branch fingerprint. `--no-merge` mode for safe first rollout. Regression-locked by `test-sync-port.sh` (44 assertions).
- **Genericized via workspace.sh knobs.** `GOVERN_UPSTREAM_HARNESS_REPO` (short repo name) and `GOVERN_UPSTREAM_HARNESS_DIR` (local working dir of the fork clone). BOTH empty (default) → the whole mechanism is inert (sync-port exits 0 with "feature off"). Adopters who don't contribute back pay zero cost. Adopters who do point them at their fork.
- **`run-loop.sh` auto-trigger.** At the end of every governor run, if `GOVERN_UPSTREAM_HARNESS_REPO` is set AND `sync-port.sh` is present in the workspace, sync-port fires. Best-effort; never overrides the run's exit code. `GOVERN_SYNC_PORT_ON_END=0` disables.
- **`templates/governor/sync-porter-prompt.md`.** Genericized porter prompt (worker instructions).

### Added — upgrade-friction fixes
- **`scripts/govern/lock-release.sh`** (from tokenjam friction #1). Inspects the run lock, verifies holder pid liveness, reclaims iff dead — the scripted path that was missing when a prior worker crashed. `--status` (holder info), `--force` (bypass — prints holder for the record). Setup.md B-pre calls it out.
- **Knob-type migration guard** (tokenjam friction #2). `scaffold.sh --component workspace-sh` detects the legacy `GOVERN_MERGE_REPOS=(...)` / `GOVERN_LOCAL_FIRST_REPOS=(...)` array shape and warns with the exact mechanical migration to the v1.1.0+ space-separated string form. Setup.md B2 documents it too.
- **`--component settings-merge`** (tokenjam friction #3). Idempotent jq-driven insertion of the harness hook stanzas (SessionStart / UserPromptSubmit / PreToolUse / Stop / SessionEnd) into an EXISTING `.claude/settings.json` — one script call replaces the "merge missing hook entries yourself" hand-edit. Re-run is a no-op (each event is skipped if a harness marker script is already referenced there).
- **`templates/lib/relocations.txt`** (tokenjam friction #4). Machine-readable manifest of file relocations. Seeded with the v1.1.0 test relocation (`scripts/worktree/test/test-base-ref.sh` → `scripts/govern/test/test-base-ref.sh`). `scaffold.sh --verify` reads it and warns about stale copies still living at the old path. When you move a template file, add a line here.
- **`scripts/govern/config-check.sh`** (tokenjam friction #5). Cheap no-auth smoke — sources workspace.sh + common.sh, resolves every knob, calls every helper (`wsp_repo_slug`, `wsp_repo_localdir`, `wsp_repo_port`, `wsp_is_merge_repo`, `wsp_is_local_first_repo`, `govern::next_ticket_number`, `govern::meta_root`), prints values, exits nonzero on any missing required. `--json` mode. Setup.md B3 points here first; dry-run.sh (which spawns a live worker) is the second step.
- **`scaffold.sh --diff-only`** (tokenjam friction #7). Per-component sync report without writing — `in-sync` (all installed files match template) or `behind (N file(s) drift)` per component. Also prints the hub VERSION + workspace stamp. Exit 0 if in sync, exit 3 if any component is behind.
- **Pipe-stall test idiom in setup.md** (tokenjam friction #6). Documents the `timeout … bash test.sh </dev/null > file.log 2>&1 & wait` idiom for headless environments where the piped `... | tail` form stalls.
- **BUMP-mode caveats in setup.md** (splito frictions #4, #6, #8, #9). Adds: test-suite step (was omitted in the doctrine), `--run-tests` escape hatch mention, dry-run auth caveat in B3 (was only mentioned in fresh mode), `--component all` warn-and-continue behavior for `workspace.sh` / `package.json` / `.claude/settings.json`, structured commit-message body template.

### Changed
- `scaffold.sh` gains `--version` and `--diff-only` flags.
- `component_govern` also copies `governor/sync-porter-prompt.md` when present (v1.2.0+).
- `templates/lib/workspace.sh` gains two new opt-in knobs: `GOVERN_UPSTREAM_HARNESS_REPO`, `GOVERN_UPSTREAM_HARNESS_DIR`.
- `templates/govern/run-loop.sh` calls `sync-port.sh` at run-end (guarded by knob + script presence).

### Compatibility
- Existing installs pick up the update channel by re-running `scaffold.sh --component <name>` — the stamp gets written; doctor.sh + govern-health.sh start comparing vs the hub VERSION.
- The sync channel is OFF by default (both `GOVERN_UPSTREAM_HARNESS_REPO` and `GOVERN_UPSTREAM_HARNESS_DIR` empty). Zero-cost for pure-consumer instances.
- Adopters carrying the legacy bash-array `GOVERN_MERGE_REPOS=(...)` / `GOVERN_LOCAL_FIRST_REPOS=(...)` are warned at `--component workspace-sh` with the exact rewrite. Multi-element arrays SILENTLY BROKE in v1.1.0; this release makes the migration visible.

### Test suite
- Grew from 60 → 62 hermetic tests (added `test-sync-templates.sh` + `test-sync-port.sh`).

## 1.1.0 — 2026-07-04

Fleet-harvest release. Two production instances (a tokenjam-shaped workspace and the splito workspace) fed a batch of hardening fixes and small-but-load-bearing features back into the templates. Every added mechanism is OFF by default; existing installs upgrade cleanly with `scaffold.sh --component <name>`.

### Added (from tokenjam harvest, PR #30)
- **Validation-gate action ladder.** Worker's `## Validation` block now carries an explicit action (`retry` / `escalate` / `park`) that the governor honors, replacing string-heuristic disposition. Locked by `test-validation-gate-action.sh`.
- **Opt-in externalization lane.** Every governor run can file each OPEN Low-severity ticket whose Where targets `GOVERN_EXTERNALIZE_SUBREPO` as a public GitHub Issue on `GOVERN_EXTERNALIZE_REPO`. Sibling-repo name containment is excluded. Auto-label mode when `GOVERN_EXTERNALIZE_LABELS` is empty. 42-assertion `test-externalize.sh`.
- **Local-first migration classification.** `GOVERN_LOCAL_FIRST_REPOS` marks sub-repos that ship schema changes as self-applying code, so additive migrations merge normally instead of parking for a manual prod apply. Destructive migrations still escalate. Regression: `test-local-first-migration.sh`.
- **PR-hygiene scrubbing.** Worker PR bodies are scrubbed of the harness-internal disposition/validation blocks before opening. `test-pr-hygiene.sh`.
- **Worktree base-ref fix.** `worktree/new.sh` now resolves the sub-repo's actual default branch instead of assuming `main`, so worktrees created against `master`/`develop`/etc. no longer fail to pick a base. `test-base-ref.sh`.
- **`govern-improve` lib discovery fix.** The self-improve triage no longer walks past the meta root looking for its lib.

### Added (from splito harvest, this PR)
- **Workspace pre-commit lint-fix hook.** `templates/githooks/pre-commit` runs `WSP_LINT_FIX_CMD` (any idempotent formatter/linter fixer) in each sub-repo before commit, then `git add -u`'s the touched tracked files. Failures are soft (commit proceeds). Chain-safe: sub-repos that already have a pre-commit hook (husky, lefthook, hand-rolled) are left untouched. Empty CMD (default) = the hook is a no-op. `install_subrepo_pre_commit_hook()` in `templates/lib/githooks.sh` propagates it into sub-repos alongside the attribution hook. 12-assertion `test-pre-commit-hook.sh`.
- **Cross-repo file-conflict warning in `push-prs.sh`.** Before opening PRs, warn when two sub-repos have touched the same relative path — the operator can review before both PRs go out. Uses `grep -F` for bracket-safe filenames and a trap-cleaned tmpfile. (Feature already ported into templates; this changelog records its provenance.)
- **`merge-pr.sh` local-branch cleanup guard.** When deleting the post-merge local ticket-`<N>` branch, skip silently if the branch is checked out in any worktree, instead of leaving noise on every merge. Worktree teardown handles that case. Locked by `test-merge-pr-branch-cleanup.sh`. (Feature already ported into templates; this changelog records its provenance.)

### Changed
- Test suite grew from 54 → 60 hermetic tests.
- CI scaffold-and-test job now exercises all 60 tests against a freshly-scaffolded workspace on every PR.

### Compatibility
- Every new mechanism is OFF-by-default. Existing installs pick up the new hook by re-running `scaffold.sh --component githooks` plus `install_subrepo_pre_commit_hook` in the sub-repo loop from `commands/setup.md` Phase 3.
- No migrations required; `workspace.sh` gains one new opt-in variable (`WSP_LINT_FIX_CMD`).

## 1.0.0 — 2026-07-04

First Claude Code **plugin** release. Prior to this, the repo installed as a skill via a symlink installer. That path still works; the plugin path is now the recommended install method.

### Added
- **Plugin packaging.** `.claude-plugin/plugin.json` manifest + `.claude-plugin/marketplace.json` marketplace catalog. Users install via `/plugin marketplace add anshss/meta-repo-harness` + `/plugin install meta-repo-harness@meta-repo-harness`. Slash commands appear as `/meta-repo-harness:*` under the plugin namespace.
- **Deterministic `scaffold.sh`.** All mechanical file operations (template copies, placeholder fills, chmod, git init, initial commit, verification) extracted from `commands/setup.md` into a top-level bash script. Idempotent, non-interactive (`--yes`), component-scoped (`--component <name>` refreshes one part), verifiable (`--verify` runs `bash -n` + sources `workspace.sh`). `setup.md` now interviews the operator, invokes `scaffold.sh`, and does only judgment work (detection, disambiguation, migration decisions).
- **Real CI.** New `scaffold-and-test` job runs `scaffold.sh` against 2 fake sub-repos and executes all 54 govern tests in the throwaway workspace on every PR. A `validate-manifests` job asserts the plugin + marketplace JSON parse and carry required fields. Existing `bash -n` and conflict-marker gates preserved.
- **`CHANGELOG.md`** + this version tag.

### Ported from the reference deployment (2026-06 → 2026-07 hardening batch)
The templates absorbed a run of production-driven fixes ahead of this release:
- Fail-closed CI lane + escalation lifecycle + ticket-block parser + claim-lock heartbeat + worktree rm-guard + port SSOT (batch of 2026-07-03).
- Round-2 drift: supervisor / self-improve input fidelity (#122), duplicate-heading hook (#73), wakeup-guard (#308), +6 new govern tests bringing the suite to 54.
- Round-1 drift: ROI telemetry (#272), interrupted-retry (#34b), worktree-leak fix.
- Git-hooks enforcement, router-posture guard, `/investigate` command, CLAUDE.md core/appendix split.

### Fixed
- `templates/govern/test/test-validation-promote.sh` — hardcoded template-layout path replaced with the existing `GOVERN_HOOKS_DIR` resolver so the test passes in both template and scaffolded-workspace layouts. Without this fix the scaffold-and-test CI job would be red on 1 test.

### Compatibility
- Legacy `install.sh` (clone → symlink into `~/.claude/commands`) continues to work.
- `scaffold.sh` resolves the templates directory from `${CLAUDE_PLUGIN_ROOT}` first, then from its own script directory, so the same command runs correctly in both install modes.
- `commands/setup.md` no longer hardcodes `~/.claude/skills/meta-repo-harness/templates/` — it resolves `PLUGIN_ROOT` at runtime.
