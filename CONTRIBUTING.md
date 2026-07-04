# Contributing

Thanks for looking. This repo is unusual: it is the template source for an autonomous multi-repo harness that ships as a Claude Code plugin, and it is battle-tested by running against production workspaces (the "fleet") that port hardening fixes back here. Read `README.md` and `SKILL.md` first — most contribution decisions fall out of the pattern once you understand it.

## What lives where

- `scaffold.sh` — deterministic scaffolder. Every mechanical file operation is here. Idempotent, non-interactive with `--yes`, component-scoped with `--component <name>`.
- `commands/*.md` — the four slash commands (`setup`, `govern`, `investigate`, `resolve`). Judgment only; mechanical work belongs in `scaffold.sh` or a template script.
- `templates/lib/workspace.sh` — the one config file every mechanism script sources. Mechanism scripts are byte-identical across installs; per-workspace values live here.
- `templates/govern/` — governor driver, ticket selector, merge-PR, supervisor, escalations.
- `templates/govern/test/` — 60 hermetic bash tests locking governor invariants.
- `templates/githooks/`, `templates/hooks/` — enforced git hooks and Claude Code hooks.
- `.github/workflows/ci.yml` — lint, manifest validation, and the scaffold-and-test job that runs all 60 govern tests against a freshly-scaffolded workspace on every PR.

If you are changing a mechanism, put per-workspace values in `workspace.sh` (or add a new opt-in variable there). Never inline them into a mechanism script.

## Developing

There is no dev server; everything is bash. The realistic dev loop:

1. Scaffold a throwaway workspace so you can exercise the change end-to-end:
   ```bash
   WS=/tmp/mrh-dev
   rm -rf "$WS" && mkdir -p "$WS"
   for r in backend console; do
     mkdir "$WS/$r"
     ( cd "$WS/$r" && git init -q \
       && printf '{"name":"%s","scripts":{"dev":"echo dev"}}\n' "$r" > package.json \
       && git -c user.email=you@test -c user.name=you add -A \
       && git -c user.email=you@test -c user.name=you commit -qm init )
   done
   bash scaffold.sh \
     --workspace-dir "$WS" --pm npm --org acme-dev \
     --repos "backend:3080:npm run dev,console:3000:npm run dev" \
     --merge-allowlist "backend" \
     --worktree-base "$WS.wt" \
     --git-init --verify --yes
   ```

2. Run the full govern suite against that scaffolded workspace:
   ```bash
   cd "$WS"
   for t in scripts/govern/test/test-*.sh; do
     name=$(basename "$t" .sh)
     if bash "$t" >/tmp/testout.log 2>&1; then
       echo "ok   - $name"
     else
       echo "FAIL - $name"
       sed 's/^/         /' /tmp/testout.log
     fi
   done
   ```
   This mirrors the CI `scaffold-and-test` job. If it is green locally against a fresh scaffold, CI will almost always be green too.

3. Iterate on the template, re-run only the affected test (`bash scripts/govern/test/test-<name>.sh`), then re-run the full suite before pushing.

### The safe-redirect + wait test idiom

Bash tests in `templates/govern/test/` invoke scripts like this:

```bash
</dev/null >/tmp/out.log 2>&1 &
wait $!
```

Meaning:
- `</dev/null` — the child never inherits your terminal's stdin; it cannot block on a prompt.
- `>/tmp/out.log 2>&1` — both streams captured for assertion. Nothing leaks to the CI log unless the test fails and dumps it.
- `&` + `wait $!` — the child is a background job so a hang is escapable (`GOVERN_WORKER_TIMEOUT` in production, `kill %1` in test), but the test still waits for its full exit status.

Follow this idiom for any new test that shells out to a mechanism script. A test that inherits the parent's TTY or does not `wait` will race the runner and produce flakes that only reproduce on CI.

## Porting discipline (for changes coming FROM a production fleet)

Most fixes here originated on a production workspace and were ported back. The three rules that keep the templates re-installable everywhere:

1. **Additive union.** A new mechanism ships OFF by default (empty variable, guarded branch). Existing installs upgrade by re-running `bash scaffold.sh --component <name>`; nobody's workspace changes behavior on bump. Every entry in `CHANGELOG.md` under `## 1.1.0` follows this rule — read them for the shape.
2. **Genericization.** Anything that mentions a fleet workspace by name, an internal ticket number, a stakeholder email, or a per-project convention is stripped. What lands here is the mechanism, not the story that produced it.
3. **Zero workspace-identity strings.** No fleet workspace names, org handles, hostnames, private repo names, or personal tokens in any added line. This is a reviewer-enforced discipline (CI does not currently grep for it); the check is manual on every PR. If you are porting from a private fleet, `grep -rn` your workspace's name across the diff before opening the PR.

## Pull request expectations

Before opening a PR:

- Full govern suite green locally against a freshly-scaffolded workspace (the loop above).
- `bash -n` clean on every touched `*.sh` — the lint job runs it repo-wide.
- No leftover conflict markers (CI enforces this).
- Manifests still parse (`jq empty .claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`).
- No workspace-identity strings in the diff (see above).
- Template-only features preserved: a mechanism you touched must still be OFF by default for a fresh install, and its opt-in variable must still be documented in `README.md` under "Opt-in knobs" (or added there).
- `CHANGELOG.md` updated for anything a user of the harness would see — a new opt-in variable, a behavior change under an existing flag, a new template file, a new test. Internal refactors that leave user-visible behavior identical do not need a changelog line.

CI must be fully green before merge. The `scaffold-and-test` job takes a couple of minutes; it is the load-bearing gate.

## Dogfood + external contributions

This repo is maintained partly by an autonomous governor running the same mechanism it distributes. That has two consequences for outside contributors:

- **External PRs are never auto-merged.** The merge guard in `templates/govern/lib/common.sh` (`govern::pr_automerge_allowed`, added in PR #32) enforces three independent conditions before auto-merging any PR: the PR author must be the governor's own GitHub login; the head branch must match the governor's branch pattern; and the head repository must be the same owner as the base (no cross-owner forks). A PR from anyone else fails all three and is routed to human review. This is the entire trust boundary — read that function for the truth.
- **Your improvements may be ported into maintainers' production fleets via sync-port.** The templates and the fleet workspaces stay in sync deliberately (see `README.md`, "Dogfood story"). A useful fix here may be adopted downstream via the project's own port mechanism, which is how the templates got most of what is in them.

Human review is the norm for outside PRs; the governor is not on the review path.

## Questions vs. bugs

- Real defect (a script errors, a test fails, a documented behavior is missing) → open an issue with the bug template.
- Friction ("it worked but was awkward") → open a feature-request issue; describe what you tried.
- "How does X work" → read `README.md` + `SKILL.md` + the linked section in `templates/`; the trust model is in the README's "The governor + trust model" section.

Thanks for the read.
