---
name: Feature request
about: A capability the harness does not have today and you would like it to.
title: "feat: "
labels: enhancement
---

## What you want to do

Describe the outcome, not the implementation. What is the workflow you are trying to run, and what makes it hard or impossible today?

## Where in the harness

Which component would grow the new capability?

- [ ] `scaffold.sh` or `commands/setup.md` (scaffolding + upgrade)
- [ ] `templates/govern/` (the governor loop, ticket selection, merging, supervision, escalations)
- [ ] `templates/worktree/` (parallel worktrees, slots, ports)
- [ ] `templates/githooks/` or `templates/hooks/` (git hooks or Claude Code hooks)
- [ ] Cross-cutting workspace script (`status`, `doctor`, `dev`, `pull-all`, `push-prs`, `sync`, `health`, `tail`, `investigate`)
- [ ] `templates/lib/workspace.sh` (a new opt-in variable)
- [ ] Plugin packaging or install path
- [ ] Documentation only
- [ ] Not sure

## Constraints inherited from the pattern

Please confirm your proposal fits the harness's existing shape (you can override any of these — flag it if you do).

- [ ] The new mechanism can be **OFF by default** so existing installs upgrade cleanly (an empty opt-in variable in `workspace.sh` disables it).
- [ ] The new mechanism does not require a mechanism script to hold per-workspace values — those live in `workspace.sh` only.
- [ ] The new mechanism can be exercised by a **hermetic bash test** under `templates/govern/test/` (or explain why not).
- [ ] The new mechanism does not weaken the auto-merge guard in `templates/govern/lib/common.sh` (`govern::pr_automerge_allowed`). If it interacts with the guard at all, describe how.

## Sketch (optional)

If you have an implementation sketch in mind — file paths, variable names, tests it would need — drop it here. If not, skip; a well-described use case is enough to start from.

## Alternatives

What have you tried today that almost works? A shell alias, a workspace-local script, another tool?
