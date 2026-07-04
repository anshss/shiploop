<!--
Thanks for the PR. A few things worth knowing before you check the boxes below:

- This repo's CI has three jobs: shell-script lint (bash -n + conflict-marker scan), manifest
  validation (jq empty on the two .claude-plugin/*.json), and a scaffold-and-test job that
  scaffolds a throwaway workspace with two fake sub-repos and runs all 60 hermetic govern tests
  against it. The scaffold-and-test job is the load-bearing gate — please make sure it is green
  locally before opening the PR (see CONTRIBUTING.md, "Developing").

- External PRs are always human-reviewed. The autonomous governor never auto-merges a PR from a
  contributor: the three-factor guard in templates/govern/lib/common.sh checks author, head-branch
  pattern, and same-owner base/head, and only the maintainer's governor login passes all three.
-->

## What this changes

One or two sentences on the outcome. Not the diff — the user-visible or maintainer-visible effect.

## Why

Motivation: which behavior was wrong, missing, or awkward. Link the issue if there is one.

## How (only if non-obvious)

Skip if the diff speaks for itself. Include a note if you changed anything load-bearing:

- The auto-merge guard (`templates/govern/lib/common.sh` `govern::pr_automerge_allowed`).
- `scaffold.sh` scaffolding order or component boundaries.
- `templates/lib/workspace.sh` variable semantics (new variable, changed default, changed meaning).
- The govern test harness idiom (`</dev/null >/tmp/out.log 2>&1 & wait $!`).

## Checklist

- [ ] The full govern suite is **green locally** against a freshly-scaffolded workspace (the loop in `CONTRIBUTING.md` → "Developing"). Paste the passed/failed/total line if convenient.
- [ ] Any new test uses the **safe-redirect + `wait`** idiom (`</dev/null >/tmp/out.log 2>&1 &` + `wait $!`). No inherited TTY, no unbounded blocking.
- [ ] `bash -n` clean on every touched `*.sh` (the CI lint job will re-run this repo-wide).
- [ ] **No workspace-identity strings** in added lines: no private workspace names, no fleet org handles, no internal ticket numbers, no personal tokens or emails. `grep -rn` your own workspace's name over the diff before pushing.
- [ ] **Template-only feature discipline preserved.** Any new mechanism is OFF by default (empty opt-in variable in `workspace.sh`, guarded branch). Existing installs upgrade cleanly with `bash scaffold.sh --component <name>`.
- [ ] `CHANGELOG.md` updated for anything a user of the harness would see — new opt-in variable, behavior change under an existing flag, new template file, new test. Pure refactors with no user-visible change do not need a line.
- [ ] If this touches the auto-merge guard, a hermetic test under `templates/govern/test/` locks the new invariant.
- [ ] If this touches `scaffold.sh`, `bash scaffold.sh --verify` still passes against a fresh workspace.

## Anything reviewers should know

Trade-offs you considered and rejected, related PRs, follow-up tickets. Optional.
