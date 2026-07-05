# shiploop

An autonomous engineering governor that grinds a ticket backlog across every repo in your product — from files, to PRs, to merged, unattended.

## What it does

Point shiploop at a folder containing your repositories, drop tickets into `queue/tickets.md`, and run `/shiploop:govern`. The governor picks tickets one at a time, spawns a fresh headless Claude worker per ticket, and drives each to a green PR. On repos you've opted into the merge allowlist it auto-merges once CI is green; on everything else it opens the PR and stops. Anything it cannot safely decide lands on an escalation queue, so you come back to a short list of judgment calls instead of a mess.

- Works across many repos at once — each ticket runs in its own git worktree, so multiple workers ship in parallel without stepping on each other.
- Auto-merge is guarded by three factors (own author, own branch, no forks) and defaults OFF — you opt each repo in explicitly.
- Fresh worker per ticket. Context stays flat, cost stays bounded, no run inherits the last one's bad state.

This is the tier above single-task AI coding tools. Devin, Cursor, Claude Code all do one task you hand them well; shiploop is the layer that runs a *backlog* across a *fleet* — a manager, not another IC.

## How it works

The governor is a pure-bash driver (`scripts/govern/run-loop.sh`) that owns state and control flow deterministically. The model owns the judgment inside each ticket. A fresh headless `claude -p` process per ticket keeps context flat and cost bounded.

```
queue/tickets.md ──► pick next ticket
                    │
                    ▼
        spawn fresh `claude -p` worker
        in its own git worktree
                    │
                    ▼
        worker: edit → commit → open PR
                    │
                    ▼
        wait for CI ─── green? ── no ──► escalate / park
                    │
                   yes
                    │
                    ▼
       three-factor auto-merge guard
       (own author + own branch + no forks)
                    │
              on allowlist?
             │            │
            yes           no
             │            │
             ▼            ▼
          merge         leave PR open
             │            │
             └─────┬──────┘
                   ▼
        bookkeep queue/tickets.md, next ticket
```

Between tickets a periodic supervisor (another fresh sub-session) audits the run. Hard-stops go to `governor/escalations.md`. The interactive session that started the governor stays idle — bash owns everything from there.

## Features

- **Autonomous backlog execution** — tickets → PRs → merged, without a human in the loop, for as long as you let it run.
- **Multi-repo, parallel workers** — each ticket runs in its own git worktree of every sub-repo; concurrent workers get distinct dev ports and their own Claude session.
- **Auto-merge on green CI, guarded** — three-factor guard (own author, own branch, no forks) plus a green-or-no-checks rule, plus a per-repo allowlist that starts empty.
- **Escalation lane** — anything the governor can't safely decide is filed for you, not glossed over.
- **Self-maintaining** — `/shiploop:update` pulls new hub templates in; `/shiploop:push` sends local mechanism improvements back to your fork of the hub.
- **Deterministic bash core** — the driver is pure bash, locked by a hermetic test suite (70+ tests and growing) that CI runs against a fresh scaffold on every PR.

## Commands

- **`/shiploop:govern`** — become the governor. Runs the ticket loop end-to-end.
- **`/shiploop:setup`** — scaffold a workspace on any folder that already contains repos as sub-folders.
- **`/shiploop:investigate`** — triage a bug: seed a notes file, pull logs, form a hypothesis, propose a fix.
- **`/shiploop:resolve`** — close out a ticket: confirm the fix PR is open, delete from `queue/tickets.md`, promote any durable lesson.
- **`/shiploop:update`** — pull the latest hub templates into this workspace (the `git pull` of harness code).
- **`/shiploop:push`** — push local mechanism-script improvements back to the hub (the `git push` of harness code).

## Install

### Preferred: plugin marketplace

```bash
# In Claude Code:
/plugin marketplace add anshss/shiploop
/plugin install shiploop@shiploop
```

Slash commands appear as `/shiploop:govern`, `/shiploop:setup`, etc.

### Alternative: clone + symlink

```bash
git clone https://github.com/anshss/shiploop.git ~/.claude/skills/shiploop
bash ~/.claude/skills/shiploop/install.sh
```

Both install modes keep the same commands + templates layout. `scaffold.sh` resolves the templates directory from `${CLAUDE_PLUGIN_ROOT}` first (plugin path) and from its own script directory as fallback (clone path).

## Quickstart

Get to a first governed ticket in under ten minutes.

1. **Install** (either mode above).
2. **`cd` into a folder** that contains your repos as sibling sub-folders, each with its own `.git`. If you don't have one handy, make a throwaway:
   ```bash
   mkdir demo && cd demo
   git clone https://github.com/you/repo-a.git
   git clone https://github.com/you/repo-b.git
   ```
3. **Scaffold**. Run `/shiploop:setup`. It detects your sub-repos, ports, and dev commands, asks for the root package manager and merge allowlist, and invokes the deterministic `scaffold.sh`.
4. **Write one ticket** into `queue/tickets.md` — a short description of a small change to one of your repos.
5. **Smoke-test the install for free — no auth, no tokens spent**:
   ```bash
   bash scripts/govern/config-check.sh     # sources config, resolves every knob + helper, exits nonzero on any gap
   ```
   Instant, `$0`, and doesn't touch Claude. Use it as the "does my install work" check on every fresh scaffold and after every `/shiploop:update`.
6. **Optional end-to-end rehearsal** (spends worker tokens; never merges):
   ```bash
   /shiploop:govern --dry-run     # runs a REAL claude -p worker in plan mode; merge + bookkeep are skipped
   ```
   Plan mode blocks the worker from writing files or opening a PR, so nothing lands in git — but the worker itself is a live `claude -p --model opus` process that consumes tokens like any other ticket. Use this only when you want to observe the whole loop end-to-end; skip it if the config-check above is enough.
7. **Run for real**:
   ```bash
   /shiploop:govern               # allowlist is still empty, so PR-only
   ```
   Watch it open a PR against the target repo. When you're satisfied, add that repo to `GOVERN_MERGE_REPOS` in `scripts/lib/workspace.sh` and let the next ticket auto-merge on green CI.

## Trust and cost

Read this before pointing the governor at anything you care about.

- **Auto-merge is OFF by default.** The default `GOVERN_MERGE_REPOS=""` means every repo is PR-only. You opt each repo in explicitly, one at a time. Recommended defaults: opt in backends with post-merge CI safety nets; keep frontends PR-only where a bad deploy is user-visible.
- **Three-factor merge guard.** A PR only auto-merges when its author is the governor's own worker identity, its branch matches the governor's `ticket-<N>` naming, and the head is not from a fork. Any factor missing → PR stays open for a human.
- **Workers run with `bypassPermissions` by design.** Each ticket runs in an isolated worktree with a fresh Claude Code invocation running `claude -p --permission-mode bypassPermissions`. The blast radius is that worktree plus the branch it pushes. The harness enforces this: `.githooks/pre-push` rejects harness-repo pushes to anything but `main` unless the push is a sanctioned governor run (`GOVERN_RUN=1` + `ticket-<N>` branch).
- **Cost, observed.** On the reference deployment — a working meta-repo running this harness against real product tickets — each resolved ticket costs about **623.9k output tokens (~$0.54)** on `claude-opus-4-7` workers, scaling roughly linearly with ticket complexity. The driver itself is pure bash and near-zero.
- **The only truly-free smoke is `config-check.sh`.** `scripts/govern/config-check.sh` sources your workspace config, calls every helper with fake args, prints resolved values, and exits nonzero on any missing required knob. No Claude auth, no worker, no tokens. It is the "does my install work" check.
- **`--dry-run` is a real worker in plan mode, not a free smoke.** `/shiploop:govern --dry-run` spawns an actual `claude -p --permission-mode plan --model opus` worker against the selected ticket. Plan mode blocks file edits and PR creation — so nothing lands in git and the merge + bookkeep steps are skipped — but the worker still consumes tokens like any other run. Use it to observe the whole loop end-to-end; use `config-check.sh` when you just want to know the install is wired sanely.
- **Start safe.** For your first run: keep the allowlist empty, watch a single ticket end-to-end, set a spend cap in your Anthropic dashboard before you leave it unattended.

## Updating

Two-way update channel — think `git pull` / `git push`, one command each direction.

- **`/shiploop:update`** — pull the latest hub templates into THIS workspace. Wraps `scaffold.sh --diff-only` (detect what's behind) → component-by-component bump (refresh mechanism scripts) → `config-check.sh` + `bash -n` verify → report. Idempotent. Preserves `scripts/lib/workspace.sh` — that file is NEVER overwritten. Refuses to proceed on a dirty tree or a live governor run.
- **`/shiploop:push`** — push local mechanism-script improvements back to the hub. Requires `GOVERN_UPSTREAM_HARNESS_REPO` set in `workspace.sh` (a fork you can PR against). Wraps `sync-templates.sh --check` (drift detection) → `sync-port.sh --no-merge` (headless porter genericizes your changes and opens a PR against your fork for HUMAN review). NEVER auto-merges. Workspace-specific files (`workspace.sh`, `package.json`, repo lists) are NEVER pushed.

A version stamp lives in `scripts/lib/.harness-version`; `bash scripts/doctor.sh` and `<pm> run govern:health` warn "harness N releases behind" when your workspace lags the hub. Degrades gracefully when the hub can't be resolved.

## Proof

This isn't aspirational documentation. This harness runs a production meta-repo — where it audits, fixes, and releases *itself*, and maintains a fleet of four sub-repos in production. Every governor edge case discovered in the field ports back into these templates with a regression test locking it. If a hardening batch broke the templates you're installing, the hermetic test suite would go RED in CI before it merged.

## Requirements

- **Claude Code CLI** — the plugin uses `/plugin` and slash-command mechanics; governor workers use `claude -p`.
- **`gh` CLI**, authenticated (`gh auth status`) — the governor opens PRs and reads CI check states.
- **git** ≥ 2.20 (worktree support), **bash** ≥ 4 (macOS ships 3.2 — the templates are guarded to run on both).
- **`jq`** — a handful of govern tests use it; also useful for CI.

## Opt-in knobs (edit `scripts/lib/workspace.sh`)

The harness ships with every advanced lane OFF by default so a fresh install is inert until you opt in.

- **`WSP_LINT_FIX_CMD`** — a workspace-wide lint/format FIX command (e.g. `"pnpm lint --fix"`, `"prettier --write ."`, `"gofmt -w ."`). When set, the per-sub-repo `pre-commit` hook runs it before each commit and `git add -u`'s the fixed files. Failures are soft. Sub-repos that already have a pre-commit hook are left untouched. Empty (default) = no-op.
- **`GOVERN_LOCAL_FIRST_REPOS`** — space-separated list of sub-repos that are local-first (no deployed prod DB). Additive migrations in these repos merge normally instead of parking for a manual prod apply. Empty (default) = feature off.
- **`GOVERN_EXTERNALIZE_REPO`** + **`GOVERN_EXTERNALIZE_SUBREPO`** — turn on the externalization lane. Every governor run files each OPEN Low-severity ticket whose Where targets `GOVERN_EXTERNALIZE_SUBREPO` as a public GitHub Issue on `GOVERN_EXTERNALIZE_REPO`, then removes it from the local queue. Seeds "good first issue" work for outside contributors. Both empty (default) = lane off.
- **`GOVERN_UPSTREAM_HARNESS_REPO`** + **`GOVERN_UPSTREAM_HARNESS_DIR`** — turn on the sync channel. When set, `sync-templates.sh` detects harness-→-template drift and `sync-port.sh` auto-ports it into a PR against your fork of the harness, validated fail-closed. Both empty (default) = channel inert.
- **`GOVERN_WORKER_MODEL`** — the fleet-wide default worker model (`opus` on install). The governor honors an optional per-ticket `Model:` line (values `haiku`|`sonnet`|`opus`) on a ticket's **first attempt only** — the brain filing/triaging the ticket picks the right tier (haiku = mechanical/single-file, sonnet = standard search+edit, opus = judgment-heavy). Any retry / park-retry escalates to `GOVERN_WORKER_MODEL` unconditionally. Unknown values are dropped fail-safe. File one with `scripts/govern/file-ticket.sh --model sonnet "Title"` or add a `**Model:** sonnet` line to the ticket block.

## Components

| Path | What it is |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, description) |
| `.claude-plugin/marketplace.json` | Single-plugin marketplace manifest |
| `SKILL.md` | Reference skill loaded by the plugin (the pattern doc) |
| `commands/{setup,update,push,govern,resolve,investigate}.md` | The six slash commands |
| `scaffold.sh` | Deterministic scaffolder — copies templates, fills placeholders, verifies |
| `install.sh` | Legacy clone-into-skills installer (kept working) |
| `templates/lib/workspace.sh` | The ONE config file; every mechanism script sources it |
| `templates/{status,doctor,dev,pull-all,push-prs,health,sync,tail,investigate}.sh` | Cross-cutting workspace scripts |
| `templates/worktree/*` | Parallel-worktree machinery (new/rm/status/exec + registry) |
| `templates/govern/*` | Governor driver, ticket selector, merge-PR, supervisor, escalations |
| `templates/govern/test/*` | Hermetic smoke tests locking governor invariants |
| `templates/githooks/{pre-push,prepare-commit-msg,pre-commit}` | Enforced + optional git hooks |
| `templates/governor/*.md` | Governor prompts (worker, supervisor) + operator files |
| `templates/hooks/*` | SessionStart/UserPromptSubmit/PreToolUse/Stop/SessionEnd hooks |
| `templates/seed/{CLAUDE.md,learnings.md,tickets.md,tickets-parked.md}` | First-run seeds (installed under `queue/`) |
| `templates/workflows/deep-research.js` | Model-tiered `deep-research-tiered` Workflow (installed under `.claude/workflows/`) |
| `templates/skills/deep-research-tiered/SKILL.md` | Skill entry that routes `deep-research`-shaped requests to the tiered workflow (installed under `.claude/skills/`) |
| `.github/workflows/ci.yml` | Lint + manifest validation + scaffold-and-test the full suite on every PR |

## License

MIT.
