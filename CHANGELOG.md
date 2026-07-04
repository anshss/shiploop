# Changelog

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
