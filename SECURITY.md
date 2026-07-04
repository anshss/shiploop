# Security policy

## Supported versions

Only the **latest tagged release** on `main` receives security fixes. The current version is tracked in `.claude-plugin/plugin.json` (`version`) and in the top entry of `CHANGELOG.md`.

There is no long-term support branch. If you are pinned to an older tag, the fix path is: upgrade to the latest release and, if that is not possible, apply the patch by cherry-picking the fix commit onto your fork.

## Reporting a vulnerability

Preferred: **GitHub private vulnerability reporting** on this repository (Security → Report a vulnerability). This opens a private advisory only the maintainer can see.

Fallback: email the maintainer address listed in `.claude-plugin/marketplace.json` under `owner.email`.

Please include:
- Version (git commit SHA or `plugin.json` `version`).
- A minimal reproduction — ideally an invocation against a freshly-scaffolded workspace, since that is how CI runs.
- What the harness did that it should not have done (see the scope note below for what counts).
- Any log excerpts, but scrub workspace names, org handles, and tokens before pasting.

Do **not** open a public issue for a suspected vulnerability. If you are unsure whether something qualifies, err on the side of the private report; it is easier to convert a private advisory to a public issue than the reverse.

### Response expectation (solo maintainer)

This project is maintained by one person on best effort. Realistic timelines:

- Acknowledgement of the report: within about a week.
- Triage and severity assessment: within two weeks of acknowledgement.
- Fix or documented mitigation on `main`: as fast as the severity warrants; a critical issue takes precedence over other work, a lower-severity one is queued.
- Coordinated disclosure: happy to hold public disclosure until a fix is on `main` and tagged. Please give at least 30 days after the initial report before public disclosure; longer if a fix is in progress.

Credit in the release notes on request.

## Scope: what a "harness vulnerability" means here

The harness's job is to run headless Claude workers with `--permission-mode bypassPermissions` inside throwaway worktrees and, on the merge allowlist, auto-merge those workers' PRs on green-or-no-checks CI. That elevated permission model is intentional and is documented in `README.md` under **"The governor + trust model"** — a headless worker cannot answer permission prompts, so the design gives it broad rights inside a bounded workspace and enforces boundaries through the governor's guard rails, not through the worker's runtime prompts.

Given that design, in scope for a security report:

- Anything that causes the governor to **auto-merge a PR it should not** — e.g. a PR from an author who is not the governor's own login, a PR from a cross-owner fork, a PR whose head branch does not match the governor's branch pattern. The three-factor guard lives in `templates/govern/lib/common.sh` (`govern::pr_automerge_allowed`, merged in PR #32); a way around it is in scope.
- Anything that causes the governor or a worker to **execute code from an untrusted source** — a crafted ticket, PR body, or CI payload that ends up as an argument to `bash -c`, a template substitution, or a shell interpolation the harness performs.
- Anything that causes the governor to **spend beyond its documented bounds** without operator action — bypassing `GOVERN_MAX_TICKETS`, `GOVERN_MAX_RUNTIME`, `GOVERN_WORKER_TIMEOUT`, or `GOVERN_MAX_BAD_STREAK`.
- Anything that lets a workspace file (ticket, PR body, worker report) **exfiltrate secrets** the operator did not intend to expose — the governor reads `governor/preferences.md`, worker reports, ticket bodies; a channel from any of those to the outside world through the governor's own actions is in scope.
- Escaping the throwaway worktree in a way the harness's own machinery (worktree registry, session cleanup, port isolation) is meant to prevent.
- Command injection, path traversal, or shell metacharacter handling in any script under `scaffold.sh`, `templates/`, `install.sh`, or a template hook.
- Manifest or plugin-loading issues (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) that could cause a plugin install to run unexpected code.

Out of scope (these are documented design choices, not defects):

- The worker running with `bypassPermissions` inside its own worktree. This is the entire point of a headless worker and is a load-bearing property of the harness. See the README's trust-model section.
- The governor auto-merging its own PRs on green-or-no-checks CI when the operator has explicitly added a repo to `GOVERN_MERGE_REPOS`. The operator opted in.
- Operator-provided values in `scripts/lib/workspace.sh` behaving as documented (e.g. setting `GOVERN_MAX_TICKETS=1000` letting the governor run for a long time). Configuration is not a vulnerability.
- Anything requiring the attacker to already be an authenticated operator on the machine running the governor.
- Vulnerabilities in `gh`, `git`, `bash`, `jq`, `claude`, GitHub, or the transitive dependencies of a scaffolded workspace's sub-repos. Report those upstream.

If you are unsure whether something is in or out of scope, report it privately and we will sort it out together.
