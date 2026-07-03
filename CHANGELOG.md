# Changelog

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
