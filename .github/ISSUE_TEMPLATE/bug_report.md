---
name: Bug report
about: Something in the harness misbehaves. Fill in the fields below so it can be reproduced against a scaffolded workspace.
title: "bug: "
labels: bug
---

## Version

Which version of the harness are you running?

- Tag or plugin version (from `.claude-plugin/plugin.json` `version`, or `git describe --tags` in a clone):
- Git commit SHA (if not on a tagged release):

## Workspace stamp

If the bug reproduces inside an already-scaffolded workspace (not against a fresh scaffold from this repo), please provide the workspace stamp. Otherwise skip this section.

- Root `ROOT_PM` (from `scripts/lib/workspace.sh`): `npm` / `pnpm` / `yarn` / `bun`
- Sub-repo count and shape (names + ports; scrub anything you don't want public):
- `GOVERN_MERGE_REPOS` (allowlist contents, or `""` if unset):
- Any opt-in variables you have set (`WSP_LINT_FIX_CMD`, `GOVERN_LOCAL_FIRST_REPOS`, `GOVERN_EXTERNALIZE_*`, etc.):
- OS and bash version: `uname -a` + `bash --version | head -1`

## Component

Which part of the harness does the bug live in? Pick the closest.

- [ ] `scaffold.sh` — scaffolding a fresh or existing workspace
- [ ] `commands/*.md` — a slash command's behavior (`setup`, `govern`, `investigate`, `resolve`)
- [ ] `templates/govern/` — the governor driver, ticket selector, merge-PR, supervisor
- [ ] `templates/worktree/` — worktree allocation, slots, ports
- [ ] `templates/githooks/` — `pre-push`, `prepare-commit-msg`, `pre-commit`
- [ ] `templates/hooks/` — SessionStart / UserPromptSubmit / PreToolUse / Stop / SessionEnd
- [ ] `templates/lib/workspace.sh` — the config file
- [ ] A cross-cutting workspace script (`status.sh`, `doctor.sh`, `dev.sh`, `pull-all.sh`, `push-prs.sh`, `sync.sh`, `health.sh`, `tail.sh`, `investigate.sh`)
- [ ] CI (`.github/workflows/ci.yml`)
- [ ] Plugin packaging (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `install.sh`)
- [ ] Documentation (`README.md`, `SKILL.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`)
- [ ] Other (please specify below)

## Reproduction

Which script or test triggers the bug? A repro against a fresh scaffold is easiest to act on — see the "Developing" section of `CONTRIBUTING.md` for the throwaway-workspace loop.

- Exact command(s) you ran:
- Which govern test (if any) reproduces it: `bash templates/govern/test/test-<name>.sh` or the full-suite loop
- Full output (please attach or paste in a fenced code block, and scrub any workspace-identity strings):

## Expected vs. actual

- What you expected to happen:
- What actually happened:

## Friction vs. defect

Please self-assess and pick one. This helps with triage; do not stress over the classification, it is a hint not a gate.

- [ ] **Defect.** The harness did something documented behavior says it should not do, or did not do something the docs say it will.
- [ ] **Friction.** The harness technically worked, but the ergonomics tripped me up. I would like the behavior improved even though it is not strictly wrong.
- [ ] **Unclear.** I am not sure whether this is a defect or documented behavior I did not find. Pointers welcome.

## Anything else

Logs (please scrub secrets and workspace-identity strings), screenshots, links to the failing CI run, or a diff of the smallest change that reproduces it. Optional but helpful.
