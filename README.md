# meta-repo-harness

Autonomous multi-repo harness for Claude Code. One workspace wraps **N independent git repos** as sub-folders, provides parallel git worktrees, a file-based **ticket queue**, and a **governor loop** that spawns a fresh headless `claude -p` worker per ticket and auto-merges allowlisted repos on green CI.

The design tenet: **the workspace is a product; the sub-repos are its services.** Each sub-repo keeps its own remote, CI, PR queue, and deploy cadence. The workspace root holds cross-cutting scripts, the ticket queue, the governor, and shared AI context — so an operator (or an agent grinding a backlog) can work across the whole product without collapsing it into a monorepo.

## What you get

- **`/meta-repo-harness:setup`** — one command scaffolds a workspace on any folder containing sub-repos with their own `.git`. Interviews the operator, invokes a deterministic `scaffold.sh`, and verifies the install.
- **`/meta-repo-harness:govern`** — becomes the governor. Launches the pure-bash driver `scripts/govern/run-loop.sh`: fresh headless worker per ticket, periodic supervisor, auto-merge allowlisted repos on green-or-no-checks CI, escalate hard-stops, deterministic bookkeeping. The interactive session's context stays flat.
- **`/meta-repo-harness:investigate`** — generic bug-triage command: seed a notes file, pull logs, form a hypothesis, propose a fix.
- **`/meta-repo-harness:resolve`** — close out a ticket (confirm fix PR is open, delete from `tickets.md`, promote any durable lesson).
- **Parallel worktrees.** `npm run worktree:new -- feature-x` gives each concurrent session its own tree of every sub-repo, with distinct dev ports and its own Claude session, so the operator (or the governor) can run multiple work streams without collisions.
- **Git-hook enforcement.** `.githooks/pre-push` rejects harness-repo pushes to any branch other than `main` unless the push is a sanctioned governor run (`GOVERN_RUN=1` + `ticket-<N>` branch). `.githooks/prepare-commit-msg` auto-appends the `Co-Authored-By` attribution trailer on agent commits.

## Install

### Preferred: plugin marketplace

```bash
# In Claude Code:
/plugin marketplace add anshss/meta-repo-harness
/plugin install meta-repo-harness@meta-repo-harness
```

Slash commands appear as `/meta-repo-harness:setup`, `/meta-repo-harness:govern`, etc.

### Alternative: clone + symlink

```bash
git clone https://github.com/anshss/meta-repo-harness.git ~/.claude/skills/meta-repo-harness
bash ~/.claude/skills/meta-repo-harness/install.sh
```

Both install modes keep the same commands + templates layout. `scaffold.sh` resolves the templates
directory from `${CLAUDE_PLUGIN_ROOT}` first (plugin path) and from its own script directory as
fallback (clone path).

## Requirements

- **Claude Code CLI** — the plugin uses `/plugin` and slash-command mechanics; governor workers use `claude -p`.
- **`gh` CLI**, authenticated (`gh auth status`) — the governor opens PRs and reads CI check states.
- **git** ≥ 2.20 (worktree support), **bash** ≥ 4 (macOS ships 3.2 — the templates are guarded to run on both).
- **`jq`** — a handful of govern tests use it; also useful for CI.

## Five-minute quickstart

1. Install (either mode above).
2. `cd` into a folder that already contains **your sub-repos as sibling folders**, each with its own `.git`.
3. Run **`/meta-repo-harness:setup`**. It will:
   - Detect your sub-repos, ports, dev commands, GitHub org.
   - Ask for root package manager, worktree base, governor merge-allowlist.
   - Invoke `scaffold.sh` (deterministic, idempotent).
   - Run `bash -n` over every installed script + source `workspace.sh`.
   - Optionally `npm install` + `npm run doctor`.
4. Try it:
   ```bash
   npm run status                             # workspace overview
   npm run worktree:new -- try-it && cd $(pwd).wt/try-it
   /govern --dry-run                          # prove the governor loop, ship nothing
   ```
5. Fill in per-sub-repo `.env` files, customize `governor/preferences.md`, opt sub-repos into `GOVERN_MERGE_REPOS` in `scripts/lib/workspace.sh`.

## The governor + trust model

The governor loop (`scripts/govern/run-loop.sh`) is designed for **long-running autonomous work with a bounded blast radius**. The mechanism:

- One **fresh headless worker** per ticket, spawned via `claude -p --permission-mode bypassPermissions`. Each worker is a separate Claude Code invocation with its own context, running with elevated permissions in its own worktree.
- The worker opens a PR, self-verifies (`bash -n`, `npm run doctor`, whatever the sub-repo's CI enforces), and reports a machine-readable status back to the driver.
- The driver applies a **green-or-no-checks merge rule** on the merge-allowlist. Repos NOT on the allowlist stay PR-only — the governor opens the PR and stops.
- A **periodic supervisor** (another fresh sub-session) audits the run every N tickets.
- **Hard-stops escalate**. A `governor/escalations.md` file collects anything the governor couldn't safely decide, so the human comes back to a queue of judgment calls, not a mess.

**Auto-merge is OFF by default.** The default `GOVERN_MERGE_REPOS=""` means every repo is PR-only. The operator explicitly opts each repo in — typically backends whose CI runs post-merge, never frontends where a bad deploy is visible to users. The `.githooks/pre-push` guard makes the harness repo itself non-force-pushable outside sanctioned governor branches.

### Cost

Observed on the reference deployment (a working meta-repo running this harness against real product tickets): **~623.9k output tokens / ~$0.54 per resolved ticket** on `claude-opus-4-7` workers. Expect that to scale roughly linearly with ticket complexity. The driver itself is pure bash — near-zero parent cost. All spend lives in the per-ticket workers and periodic supervisor.

## How the templates + tests work

- `scaffold.sh` is a **deterministic bash script** that owns every mechanical file operation. `commands/setup.md` interviews the operator, calls `scaffold.sh`, and does only judgment work (detection, disambiguation).
- Every mechanism script sources ONE file — `scripts/lib/workspace.sh` — so the mechanism scripts are **byte-identical across every install**. Bumps refresh mechanism scripts without ever touching `workspace.sh`.
- **62 hermetic bash tests** ship under `templates/govern/test/`. They exercise the governor's edge cases: ff-only pushes, claim-lock heartbeats, ticket-block parsing, worktree teardown, escalation flow, merge-CI unverifiable, disk guard, orphan teardown, and dozens more. CI scaffolds a throwaway workspace from `scaffold.sh` on every PR and runs all 62 tests against it — so a broken template goes RED before it can be merged.

## Dogfood story

This harness is extracted from a production instance where it grinds a real product's ticket backlog. Hardening batches ported back into these templates via a batched sync mechanism — every time the production instance discovers a governor edge case, the fix ports to the templates and a regression test locks it. The templates and the production harness stay in sync deliberately; this repo is not aspirational documentation, it is the working code.

## Components

| Path | What it is |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, description) |
| `.claude-plugin/marketplace.json` | Single-plugin marketplace manifest |
| `SKILL.md` | Reference skill loaded by the plugin (the pattern doc) |
| `commands/{setup,govern,resolve,investigate}.md` | The four slash commands |
| `scaffold.sh` | Deterministic scaffolder — copies templates, fills placeholders, verifies |
| `install.sh` | Legacy clone-into-skills installer (kept working) |
| `templates/lib/workspace.sh` | The ONE config file; every mechanism script sources it |
| `templates/{status,doctor,dev,pull-all,push-prs,health,sync,tail,investigate}.sh` | Cross-cutting workspace scripts |
| `templates/worktree/*` | Parallel-worktree machinery (new/rm/status/exec + registry) |
| `templates/govern/*` | Governor driver, ticket selector, merge-PR, supervisor, escalations |
| `templates/govern/test/*` | 62 hermetic smoke tests locking governor invariants |
| `templates/githooks/{pre-push,prepare-commit-msg,pre-commit}` | Enforced + optional git hooks (pre-push is harness-only; the other two propagate into sub-repos) |
| `templates/governor/*.md` | Governor prompts (worker, supervisor) + operator files (preferences, decisions log) |
| `templates/hooks/*` | SessionStart/UserPromptSubmit/PreToolUse/Stop/SessionEnd hooks |
| `templates/seed/{CLAUDE.md,learnings.md,tickets.md,tickets-parked.md}` | First-run seeds |
| `.github/workflows/ci.yml` | Lint + manifest validation + scaffold-and-test the 62-test suite on every PR |

## Opt-in knobs (edit `scripts/lib/workspace.sh`)

The harness ships with every advanced lane OFF by default so a fresh install is inert until the operator opts in. The knobs that matter most:

- **`WSP_LINT_FIX_CMD`** — a workspace-wide lint/format FIX command (e.g. `"pnpm lint --fix"`, `"prettier --write ."`, `"gofmt -w ."`). When set, the per-sub-repo `pre-commit` hook runs it before each commit and `git add -u`'s the fixed files. Failures are soft (commit proceeds — CI catches real regressions). Sub-repos that already have a pre-commit hook (husky, lefthook, hand-rolled) are left untouched. Empty (default) = the hook is a no-op.
- **`GOVERN_LOCAL_FIRST_REPOS`** — space-separated list of sub-repos that are local-first (no deployed prod DB — a schema change ships as code that self-applies on the user's local DB open). Additive migrations in these repos merge normally instead of parking for a manual prod apply. Empty (default) = feature off.
- **`GOVERN_EXTERNALIZE_REPO`** + **`GOVERN_EXTERNALIZE_SUBREPO`** — turn on the externalization lane. Every governor run files each OPEN Low-severity ticket whose Where targets `GOVERN_EXTERNALIZE_SUBREPO` as a public GitHub Issue on `GOVERN_EXTERNALIZE_REPO`, then removes it from the local queue. Seeds "good first issue" work for outside contributors. Both empty (default) = lane off.
- **`GOVERN_UPSTREAM_HARNESS_REPO`** + **`GOVERN_UPSTREAM_HARNESS_DIR`** — turn on the sync channel (v1.2.0). When set, `sync-templates.sh` detects harness-→-template drift and `sync-port.sh` auto-ports it into a PR against your fork of the harness, validated fail-closed. Both empty (default) = channel inert.

## Updating

The harness has a two-way update channel.

**One-way: is my workspace behind the hub?** Every scaffold run writes `scripts/lib/.harness-version` — the hub `VERSION` this workspace was last synced against. `bash scripts/doctor.sh` and `<pm> run govern:health` compare the stamp against the installed hub's `VERSION` file and warn "harness N releases behind — run the setup upgrade". Graceful when the hub can't be resolved (offline / plugin-cache-only install): degrades to a soft "cannot compare" notice.

**The update path.**

```bash
# Cheap version + drift check first (no writes):
bash "$HUB/scaffold.sh" --version                             # print hub VERSION
bash "$HUB/scaffold.sh" --workspace-dir . --diff-only         # per-component in-sync/behind

# If a prior worker crashed and left a run lock, reclaim it (safe: dead-holder-only):
bash scripts/govern/lock-release.sh                            # inspect + reclaim iff safe

# Component-by-component bump — refresh mechanism scripts (they only read workspace.sh):
bash "$HUB/scaffold.sh" --workspace-dir . --component core-scripts --yes
bash "$HUB/scaffold.sh" --workspace-dir . --component worktrees    --yes
bash "$HUB/scaffold.sh" --workspace-dir . --component govern       --yes
bash "$HUB/scaffold.sh" --workspace-dir . --component githooks     --yes
bash "$HUB/scaffold.sh" --workspace-dir . --component commands     --yes
bash "$HUB/scaffold.sh" --workspace-dir . --component seeds        --yes

# Idempotent hook merge into an EXISTING .claude/settings.json:
bash "$HUB/scaffold.sh" --workspace-dir . --component settings-merge

# Verify: no-auth smoke, then bash -n + stale-relocation warning, then optional full suite.
bash scripts/govern/config-check.sh
bash "$HUB/scaffold.sh" --workspace-dir . --component core-scripts --yes --verify
```

**Two-way: contributing back.** If you set `GOVERN_UPSTREAM_HARNESS_REPO` + `GOVERN_UPSTREAM_HARNESS_DIR` (a local clone of your fork of the harness) in `workspace.sh`, then:

- `bash scripts/govern/sync-templates.sh --check` reports mirrored files you've changed in your workspace since the last sync — exit 3 = drift, exit 0 = clean. `--files` lists them; `--diff` emits the consolidated diff to port.
- `bash scripts/govern/sync-port.sh --dry-run` prints what a headless porter WOULD do (which files, forbidden-identity-strings gate, planned PR title). Full run spawns the porter, validates its port (bash -n + forbidden-strings gate on ADDED lines + scaffold test suite baseline-diff), opens a PR against your fork, merges it green-or-no-checks, and advances the local marker. Fail-closed at every step: any failure files an escalation and does NOT merge.
- The governor calls `sync-port.sh` automatically at run-end (best-effort — never overrides the run's exit code).

For first live use, set `GOVERN_SYNC_PORT_NO_MERGE=1` (or invoke `sync-port.sh --no-merge`) so it opens the PR for review instead of auto-merging.

## License

MIT.
