# Contributing

Thanks for looking. This repo is unusual: it is the template source for an autonomous multi-repo harness that ships as a Claude Code plugin, and it is battle-tested by running against production workspaces (the "fleet") that port hardening fixes back here. Read `README.md` and `SKILL.md` first — most contribution decisions fall out of the pattern once you understand it.

## What lives where

- `scaffold.sh` — deterministic scaffolder. Every mechanical file operation is here. Idempotent, non-interactive with `--yes`, component-scoped with `--component <name>`.
- `commands/*.md` — the slash commands (`setup`, `update`, `flows`, `push`). Judgment only; mechanical work belongs in `scaffold.sh` or a template script.
- `templates/lib/workspace.sh` — the one config file every mechanism script sources. Mechanism scripts are byte-identical across installs; per-workspace values live here.
- `templates/lib/mechanism-hashes.txt`: every shipped version of every mechanism script; `bash tools/gen-mechanism-hashes.sh > templates/lib/mechanism-hashes.txt` after changing one (the `mechanism-hashes-current` check fails otherwise).
- `templates/govern/` — governor driver, ticket selector, merge-PR, escalations.
- `templates/govern/test/`: 159 hermetic bash tests locking governor invariants.
- `templates/githooks/`, `templates/hooks/` — enforced git hooks and Claude Code hooks.
- `.github/workflows/ci.yml`: lint, manifest validation, and the scaffold-and-test job that runs the govern tests against a freshly-scaffolded workspace on every PR (the 15 hub-context tests listed in `tools/hub-context-tests.txt` skip there and run in their own job).

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

2. `scaffold.sh` deliberately does not install `scripts/govern/test/` into a workspace (the suite is hub-only), so copy it in yourself, exactly as the CI `scaffold-and-test` job does, then run the whole thing with `tools/run-suite.sh`, the same runner CI's shard job calls, so a local run uses the ONE definition of the run order (slow-tests-first hint, coverage assertion, shard selection):
   ```bash
   mkdir -p "$WS/scripts/govern/test"
   cp templates/govern/test/*.sh "$WS/scripts/govern/test/"
   chmod +x "$WS"/scripts/govern/test/*.sh
   bash tools/run-suite.sh --suite-dir "$WS/scripts/govern/test" --jobs 8
   ```
   `--jobs 8` runs tests concurrently with each test's output captured to its own log file and a fail summary (log paths included) at the end; omit it for CI's exact sequential order. Other flags: `--shard i/n` runs one round-robin partition, `--hint FILE` overrides the scheduling hint, `--hub-context FILE` enables CI's skip accounting (off locally), and the order check (on by default for a full run, off for a shard) runs the whole selection a second time in reversed order and fails naming any test whose verdict depends on run order. If it is green locally against a fresh scaffold, CI will almost always be green too.

   Negative controls (does a guard actually fire?) run against the NEW test file only: `bash templates/govern/test/test-<name>.sh` from this checkout. Never run negative controls against the whole suite: a deliberately broken fixture in a full run wastes the run and risks the broken copy leaking into a commit.

   Some of the copied tests skip (exit 77) here by design: they assert on the hub itself (`scaffold.sh`, `templates/`, `VERSION`, `purge.txt`, `seed-hashes.txt`) and resolve the hub as `$DIR/../../..`, which only resolves correctly from a hub checkout, not a scaffolded workspace. Those are listed in `tools/hub-context-tests.txt` and gated by the separate CI `hub-context-tests` job, which runs them straight from the checkout and treats a skip there as a failure. To exercise them locally, run them from this repo directly, e.g. `bash templates/govern/test/test-update-channel.sh`.

3. Iterate on the template, re-run only the affected test (`bash scripts/govern/test/test-<name>.sh`), then finish with a full `tools/run-suite.sh` run (step 2) before pushing.

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

The environment a test runs in is the harness's, not yours: sourcing `templates/govern/test/assert.sh` installs a per-test sandbox before your test body runs (a private `HOME` holding a canary dotfile, a private `TMPDIR`, git config pointed inside the sandbox), and `assert_done` verifies it after. Write fixtures through `$HOME` and `mktemp` as usual and they land inside the sandbox automatically; a test that genuinely needs host behavior opts out with `govern_sandbox_off  # <one-line reason>` right after the source.

### Never simulate a missing tool with a hardcoded PATH

To test a "tool not installed → fail open" branch, it is tempting to write `PATH="/usr/bin:/bin"` and
assume the tool is gone. Do not. CI runs on an Ubuntu runner whose `/usr/bin` holds far more than a
macOS `/usr/bin` — `gh`, for instance, is pre-installed there. The stub then silently keeps the tool
on `PATH`, the test stops exercising the branch it names, and the failure only appears on CI.

Dropping the offending directory instead is also wrong: on Ubuntu, `gh` shares `/usr/bin` with
`dirname`, `date`, and `mkdir`, which the script under test needs before it ever looks for `gh`.

Derive the `PATH` from the ambient environment: mirror every directory that actually contains the
tool into a shadow directory that symlinks all its *other* entries, and substitute it. The tool
disappears wherever it happens to live; everything else stays reachable. See
`test-preflight-base-ci.sh` for the worked version — collect with a glob and link in one batched `ln`
call (destination directory last), which is portable to both GNU and BSD `ln`. Note that
`find … -exec ln -sf {} "$dir/" +` does **not** work: `{}` must be the final argument before `+`.

The general rule behind both idioms: **a local pass on macOS is not evidence of a CI pass on Linux.**
When a test encodes an assumption about the machine — where a binary lives, which flags a coreutil
accepts (`stat`, `sed`, `date` are the classic GNU/BSD splits) — verify it against the runner's
environment rather than your own, and prefer deriving the fact at runtime over hardcoding it.

### A test runs from two different layouts — never hardcode one

The same corollary applies to paths. Every test file executes twice: as `templates/govern/test/test-x.sh` in this repo, and as `scripts/govern/test/test-x.sh` inside the scaffolded workspace CI builds. `$DIR/../` (the mechanism script under test) is stable across both; anything *above* that is not — `templates/gitignore` becomes the workspace's `.gitignore`, `templates/governor/worker-prompt.md` becomes `governor/worker-prompt.md`. A test that asserts on a shipped file must resolve the first path that exists across both layouts (and skip if neither does), or it passes locally and fails only in `scaffold-and-test`.

**The inverse failure is silent, and it bit us.** A test asserting on the *hub itself* — `scaffold.sh`, `templates/`, `VERSION`, `purge.txt`, `seed-hashes.txt` — resolves `HUB="$DIR/../../.."` and exits `77` ("skip") when that is not a hub checkout. Inside `scaffold-and-test` that path is the throwaway workspace root, so the test always skips, and `77` is counted as a skip rather than a failure. Result: seven tests — `test-update-channel`, `test-purge-removed`, `test-reconcile-update`, `test-scaffold-verify-standalone`, `test-detect-inputs`, `test-wrap-in-place`, `test-update-config-converge` — ran green locally and **never executed in CI at all** — the entire mechanism behind `/shiploop:update` was ungated while looking gated. Hub-context tests belong in the `hub-context-tests` job, which runs them from the checkout and treats a `77` as a hard failure. The list lives in `tools/hub-context-tests.txt`, and `scaffold-and-test` fails if a test skips there without being listed — so a new hub-context test cannot silently run nowhere.

### Never treat `mkdir`'s exit status as a lock

Some coreutils builds (observed: uutils on ubuntu-26.04 runners) let two racing `mkdir` calls both succeed, so a bare `mkdir lockdir` claims nothing. Claim through the existing helpers: `govern::_lock_claim` (`templates/govern/lib/common.sh`), `sem_claim` (`templates/lib/install-semaphore.sh`), `wt_lock_claim` (`templates/worktree/lib/registry.sh`). Each follows `mkdir` with an `O_EXCL` noclobber create of a holder file. A new lock uses one of them or the same idiom.

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
- Template-only features preserved: a mechanism you touched must still be OFF by default for a fresh install, and its opt-in variable must still be documented in `CONFIGURATION.md` (or added there).
- `CHANGELOG.md` updated for anything a user of the harness would see — a new opt-in variable, a behavior change under an existing flag, a new template file, a new test. Internal refactors that leave user-visible behavior identical do not need a changelog line.

CI must be fully green before merge. The `scaffold-and-test` job takes a couple of minutes; it is the load-bearing gate.

## Release trains

The default is one release per PR: bump `VERSION` and both manifest versions, add a `CHANGELOG.md` section, regenerate `templates/lib/mechanism-hashes.txt` if a mechanism template changed. That serializes independent PRs: two in flight always conflict on those files, and N small tickets cost N releases, N local suite runs and N CI runs.

A **release train** batches that ceremony. A PR joins a train with a `Release-Train: <train-id>` line in its commit message: `tools/check-release-parity.sh` skips parity for that commit (both on the PR run and on the push-to-main run), and the PR merges with no release files touched. The train closes with one ordinary release commit that bumps `VERSION` and the manifests, adds one `CHANGELOG.md` entry per train PR (each naming the train id), regenerates mechanism hashes if needed, and is tagged and released as usual. Parity runs at full strength on that commit, and the coverage check applies to it: a train PR whose CHANGELOG entry never lands fails the train-close parity. The close itself is one command: `tools/make-release.sh <version> --headline "<headline>"` runs the preconditions, mutations, verification, tag, push and release-body extraction (with a bounded self-heal) as one verified step, and `--dry-run` mutates nothing.

When to train: several small, independent changes with no shared release-file churn. When never: anything that wants its own release-level revert (reverting a train-close merge undoes every ticket on the train, not one), or anything users must be able to pick up before the train closes. A per-ticket release bump is superseded for any PR riding a train.

While a train is open (trailer commits merged, no covering release yet), a push-to-main parity run that is not the train close fails by design, with an error telling you to merge the train-close release: close the train promptly, and route urgent standalone fixes either onto the train or after it closes.

One caveat: the trailer must survive into the commit that lands on `main`. A squash merge keeps only the PR title and the commit subjects by default, so put the trailer where your merge flow will keep it (a commit subject line, or the edited squash message).

## Dogfood + external contributions

This repo is maintained partly by an autonomous governor running the same mechanism it distributes. That has two consequences for outside contributors:

- **External PRs are never auto-merged.** The merge guard in `templates/govern/lib/common.sh` (`govern::pr_automerge_allowed`) enforces three independent conditions before auto-merging any PR: the PR author must be the governor's own GitHub login; the head branch must match the governor's branch pattern; and the head repository must be the same owner as the base (no cross-owner forks). A PR from anyone else fails all three and is routed to human review. This is the entire trust boundary — read that function for the truth.
- **Your improvements may be ported into maintainers' production fleets via sync-port.** The templates and the fleet workspaces stay in sync deliberately (see `README.md`, "Dogfood story"). A useful fix here may be adopted downstream via the project's own port mechanism, which is how the templates got most of what is in them.

Human review is the norm for outside PRs; the governor is not on the review path.

## Questions vs. bugs

- Real defect (a script errors, a test fails, a documented behavior is missing) → open an issue with the bug template.
- Friction ("it worked but was awkward") → open a feature-request issue; describe what you tried.
- "How does X work" → read `README.md` + `SKILL.md` + the linked section in `templates/`; the trust model is in the README's "The governor + trust model" section.

Thanks for the read.
