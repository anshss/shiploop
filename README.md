# shiploop

> **shiploop**
>
> You do the specs and systems engineering. shiploop ships the code.
>
> A self-improving multi-agent harness that grinds your ticket backlog across every repo in your product — a fresh right-sized agent per ticket, guarded auto-merge, ~$0.54 a resolved ticket.

## Install

```bash
# In Claude Code:
/plugin marketplace add anshss/shiploop
/plugin install shiploop@shiploop
```

Slash commands appear as `/shiploop:govern`, `/shiploop:setup`, `/shiploop:flows`, etc. Or clone + symlink instead: `git clone https://github.com/anshss/shiploop.git ~/.claude/skills/shiploop && bash ~/.claude/skills/shiploop/install.sh`. Both modes keep the same commands + templates layout; `scaffold.sh` resolves the templates directory from `${CLAUDE_PLUGIN_ROOT}` first (plugin path) and its own script directory as fallback (clone path).

The fastest way to see what shiploop is for is the quickstart — point it at code you already have and read back a map of every user-facing path that might break, before you commit to anything.

## Quickstart

### Act 1 — 10 minutes: see your product's risk map

Point shiploop at a repo you already have and get back an inventory of **every user-facing path that might break** — every route, endpoint, and provider×action cell — keyed by a stable id and pinned to the code it maps to. Nothing deploys, nothing merges, nothing billable. It's a read.

1. **Install the plugin** (above).
2. **Put your repo(s) in a workspace folder**, each as a sub-folder with its own `.git`. **One repo is a fine meta-repo** — you are not required to have microservices; the queue, governor, worktrees, and lesson-accretion all pay for themselves on a single repo, and you add more later.
   ```bash
   mkdir myproduct && cd myproduct
   mv ~/code/your-repo .          # or: git clone <url> inside myproduct
   ```
3. **Scaffold the workspace** — run `/shiploop:setup`. It detects your sub-repo(s), their ports and dev commands, and writes the harness config into `myproduct/`. This is local file-ops plus a first git commit — no deploys, no product tokens spent, nothing leaves your machine.
4. **Extract the flow registry** — run `/shiploop:flows extract`. shiploop fans out over your codebase (one agent per surface, so no single context holds the whole repo) and inventories the combinatorial list of paths a user might take that could break. The inventory is **staged for your approval** and never auto-applied — you review the diff before a single row lands.
5. **Read your risk map** — run `/shiploop:flows list`. It groups the registry by proven / measuring / untested / stale / failed / blocked. On a fresh extract everything is UNTESTED: that list is exactly the map of what you don't yet know works.

That is the payoff with zero commitment. Extract reads your code and produces the map; it opens no PRs, merges nothing, and rents no compute. When you later want to *prove* a path actually works, `/shiploop:flows file <id>` queues a validation — and that one can deploy, so it is gated behind an explicit `--yes` and a spend cap.

### Act 2 — file one ticket, watch it ship

Now let the harness ship a change. Your workspace starts on the **safe rung of the [trust ladder](#trust-and-cost)** — pr-only — so this first ticket ends at a PR you review, never an automatic merge.

1. **Write a starter ticket.** Setup seeds one to try, or file your own: a small, well-scoped change to one file in one repo. `scripts/govern/file-ticket.sh "Title"` writes it into `queue/tickets.md` with a collision-safe number.
2. **Smoke-test the install for free** — `bash scripts/govern/config-check.sh`. It sources your config, resolves every knob and helper, and exits nonzero on any gap. Instant, `$0`, no Claude auth, no tokens.
3. **Run the governor** — `/shiploop:govern`. It spawns one fresh headless worker in its own git worktree; the worker edits → commits → opens a PR against your repo, then waits for CI. Because you're on the pr-only rung, it stops at the open PR.
4. **Review, then graduate.** Read the PR. When you trust the pattern for that repo, add it to `GOVERN_MERGE_REPOS` in `scripts/lib/workspace.sh` — the next ticket auto-merges on green CI, guarded by the three-factor check in [Trust and cost](#trust-and-cost).

A backlog goes in; reviewed PRs (then, once you graduate, merges) come out.

## Requirements

- **Claude Code CLI** — the plugin uses `/plugin` and slash-command mechanics; governor workers use `claude -p`. Act 1 (setup + extract) needs only this plus git and `jq`.
- **git** ≥ 2.20 (worktree support), **bash** ≥ 4 (macOS ships 3.2 — the templates are guarded to run on both).
- **`jq`** — hard-required, not optional: `scaffold.sh`'s settings-merge and `run-loop.sh` both fail closed without it (`govern::require jq`), and it's pervasive across the governor (spawn-worker, bookkeep, supervise, health, sync-port). Install it before `/shiploop:setup`.
- **`gh` CLI**, authenticated (`gh auth status`) — needed for Act 2 and the governor (it opens PRs and reads CI check states), not for the Act 1 risk map.

## How it ships without burning your quota

The interactive session doesn't ship the code — it dispatches. The governor is a **pure-bash driver** (`scripts/govern/run-loop.sh`) that owns state and control flow deterministically: it can drive the loop all day and spends near-zero Claude context doing it. Model tokens burn only inside the fresh headless workers it spawns.

- **One ticket = one fresh headless session.** Each ticket runs its own `claude -p` process in its own git worktree. Context stays flat, no run inherits the last one's bad state, and two unrelated tasks never share a quota.
- **Brain-decided right-sized models.** The interactive session — the "brain" — assigns each agent the cheapest capable tier at file time: haiku for mechanical single-file work, sonnet for standard search-and-edit, opus for judgment-heavy tickets. The governor honors an optional per-ticket `**Model:** haiku|sonnet|opus` field on a ticket's first attempt; any retry escalates to `GOVERN_WORKER_MODEL` (opus by default) unconditionally, because a cheap-tier bet that didn't land the first time shouldn't be re-bet. Router-posture hooks and tiered workflows carry the same sizing rule so delegation is right-sized end-to-end (v1.5.0).
- **Measured cost.** On the reference deployment — a working meta-repo running this harness against real product tickets — each resolved ticket costs about **623.9k output tokens (~$0.54)** on `claude-opus-4-7` workers, scaling roughly linearly with ticket complexity. Cheaper tiers scale down from there. Methodology is spelled out in **Trust and cost** below.

## How it ships without shipping slop

The reviewer's question — "who reads all these PRs?" — is answered by mechanism, not trust.

- **Guarded auto-merge, off by default.** A PR only auto-merges when the target repo is on the `GOVERN_MERGE_REPOS` allowlist (which starts empty — you opt each repo in explicitly), its author is the governor's own worker identity, its branch matches the `ticket-<N>` naming, its head is not from a fork, and CI is **green-or-no-checks**. Any factor missing → the PR stays open for a human. Frontends stay human-merged where a bad deploy is user-visible; backends with post-merge CI safety nets are safer to opt in.
- **Evidence gates on the ports that matter.** The self-improvement ports and the harness-sync ports run under a fail-closed pipeline: `bash -n` on every changed shell file, a forbidden-identity-strings gate on added lines, and a scaffold-test-suite baseline diff. Any gate failure files an escalation instead of merging.
- **Escalation queue for hard-stops.** Destructive git, prod data, destructive schema, secrets — the doctrine in `governor/preferences.md` lists the hard-stops that make a worker **park + escalate** instead of acting. Anything the governor can't safely decide lands on `governor/escalations.md` for the operator; you come back to a short list of judgment calls instead of a mess.

The net: the layer decides which decisions it's allowed to make on its own, and every other decision waits for you.

## Why it gets better — and cheaper — over time

Self-improving, spelled out as mechanism: every resolved ticket writes a lesson into your git-tracked `CLAUDE.md` — memory you can read, diff, and edit. Nothing is buried in an opaque model state.

- **`/shiploop:resolve` promotes the durable lesson first, then deletes the ticket.** If fixing a ticket taught something stable and reusable — an env var, a convention, an architecture gotcha, a load-bearing rule — it lands in the right `CLAUDE.md` (root for cross-repo, sub-repo for scoped) **before** the ticket is deleted. Git history + the PR are the only record once the ticket is gone, so the lesson must land somewhere durable.
- **observe → propose → triage → guarded-self-apply.** The supervisor and workers propose harness improvements into `governor/improvements.md`; a triage step decides which graduate to preferences and which stay as one-off observations. A decision graduates to `governor/preferences.md` only after it recurs — a single incident doesn't rewrite the doctrine.
- **Two-way hub channel.** `/shiploop:update` pulls the latest hub templates into this workspace (the `git pull` of harness code, preserving your `workspace.sh`). `/shiploop:push` sends local mechanism-script improvements back to your fork of the hub through the fail-closed porter (see the slop section above) and opens a PR for human review — never auto-merges.

So the loop gets better: lessons harden CLAUDE.md, improvements harden the templates, and the model bill for each ticket drops as the router learns which tier suffices.

## Proof

The maintainer has run **400+ tickets auto-found and resolved on their own production multi-repo product** through this harness. The harness also audits, fixes, and releases *itself* through the same loop — every governor edge case discovered in the field ports back into these templates with a regression test locking it. If a hardening batch broke the templates you're installing, the hermetic test suite would go RED in CI before it merged.

A sanitized public evidence artifact (auto-merge acceptance / revert rate, per-tier cost breakdown) is on the roadmap.

## How it compares

Devin, Cursor, Copilot, Claude Code all do one task you hand them well. shiploop is the layer above: it runs a **backlog** across a **fleet**. A manager, not another IC. If your bottleneck is "I have one hard task and I want an AI pair-programmer," use those. If your bottleneck is "I have a growing queue of small-to-medium changes across N repos and I'd rather do the spec work than the shipping," use this.

## How it works

The governor is a pure-bash driver (`scripts/govern/run-loop.sh`) that owns state and control flow deterministically. The model owns the judgment inside each ticket.

```
queue/tickets.md ──► pick next ticket
                    │
                    ▼
        spawn fresh `claude -p` worker
        in its own git worktree
        (right-sized: haiku/sonnet/opus)
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

- Each ticket runs in its own git worktree, so multiple workers ship in parallel without stepping on each other.
- Fresh worker per ticket. Context stays flat, cost stays bounded, no run inherits the last one's bad state.
- The `--setting-sources user` flag drops the workspace's own hooks inside the worker, so a fleet-wide SessionEnd cleanup or a stdout-clobbering Stop hook never bleeds into a ticket run.

## Commands

- **`/shiploop:govern`** — ships your backlog. Runs the bash-driven ticket loop end-to-end.
- **`/shiploop:setup`** — scaffold a workspace on any folder that already contains repos as sub-folders.
- **`/shiploop:investigate`** — triage a bug: seed a notes file, pull logs, form a hypothesis, propose a fix.
- **`/shiploop:resolve`** — close out a ticket: confirm the fix PR is open, promote the durable lesson into `CLAUDE.md`, delete the ticket, sweep for newly-discovered tickets.
- **`/shiploop:update`** — the self-improvement channel, pull direction. Refresh mechanism scripts from the hub, preserve `scripts/lib/workspace.sh`.
- **`/shiploop:push`** — the self-improvement channel, push direction. Send local mechanism-script improvements back to your fork of the hub through a fail-closed porter; never auto-merges.

## Trust and cost

Read this before pointing the governor at anything you care about.

**The trust ladder — observe → pr-only → auto.** You don't hand shiploop the keys on day one; you graduate it one repo at a time, as you watch it behave.

- **observe** — run `/shiploop:govern --dry-run` (a real worker in plan mode; ships nothing) or just read the PRs the governor opens. See how it works a ticket before it can change anything.
- **pr-only** — the rung every new workspace starts on. The default `GOVERN_MERGE_REPOS=""` (and the pr-only autonomy default) means every repo is PR-only: the governor opens a PR and stops, a human merges. Nothing auto-lands.
- **auto** — opt a single repo in by adding it to `GOVERN_MERGE_REPOS`. Now that repo's tickets auto-merge on green CI — but only through the three-factor guard below. Opt in backends with post-merge CI safety nets first; keep frontends on pr-only where a bad deploy is user-visible.

You graduate a repo when you've watched enough PRs to trust the pattern, not before. The guards that make the auto rung safe to reach for:

- **Three-factor merge guard.** A PR only auto-merges when its author is the governor's own worker identity, its branch matches the governor's `ticket-<N>` naming, and the head is not from a fork. Any factor missing → PR stays open for a human.
- **Evidence gates on the paths that matter.** CI must be green-or-no-checks before any auto-merge, the self-improvement and harness-sync ports run fail-closed (`bash -n` + a forbidden-identity gate + a scaffold-test baseline diff), and hard-stops (destructive git, prod data, destructive schema, secrets) make a worker park and escalate instead of acting. The flow registry from Act 1 is the outcome side of this: `/shiploop:flows` tracks which user-facing paths are *proven at HEAD* so a merge can be checked against real coverage, not just a green pipeline.
- **Workers run with `bypassPermissions` by design.** Each ticket runs in an isolated worktree with a fresh Claude Code invocation running `claude -p --permission-mode bypassPermissions`. The blast radius is that worktree plus the branch it pushes. The harness enforces this: `.githooks/pre-push` rejects harness-repo pushes to anything but `main` unless the push is a sanctioned governor run (`GOVERN_RUN=1` + `ticket-<N>` branch).
- **Cost, observed.** On the reference deployment — a working meta-repo running this harness against real product tickets — each resolved ticket costs about **623.9k output tokens (~$0.54)** on `claude-opus-4-7` workers, scaling roughly linearly with ticket complexity. The driver itself is pure bash and near-zero. Brain-decided right-sizing (haiku/sonnet on tickets that don't need opus) pushes that number down further; the observed figure is the opus-only baseline.
- **The only truly-free smoke is `config-check.sh`.** `scripts/govern/config-check.sh` sources your workspace config, calls every helper with fake args, prints resolved values, and exits nonzero on any missing required knob. No Claude auth, no worker, no tokens. It is the "does my install work" check.
- **`--dry-run` is a real worker in plan mode, not a free smoke.** `/shiploop:govern --dry-run` spawns an actual `claude -p --permission-mode plan --model opus` worker against the selected ticket. Plan mode blocks file edits and PR creation — so nothing lands in git and the merge + bookkeep steps are skipped — but the worker still consumes tokens like any other run. Use it to observe the whole loop end-to-end; use `config-check.sh` when you just want to know the install is wired sanely.
- **Start safe.** For your first run: keep the allowlist empty, watch a single ticket end-to-end, set a spend cap in your Anthropic dashboard before you leave it unattended.

## Updating

Two-way update channel — think `git pull` / `git push`, one command each direction.

- **`/shiploop:update`** — pull the latest hub templates into THIS workspace. Wraps `scaffold.sh --diff-only` (detect what's behind) → component-by-component bump (refresh mechanism scripts) → `config-check.sh` + `bash -n` verify → report. Idempotent. Preserves `scripts/lib/workspace.sh` — that file is NEVER overwritten. Refuses to proceed on a dirty tree or a live governor run.
- **`/shiploop:push`** — push local mechanism-script improvements back to the hub. Requires `GOVERN_UPSTREAM_HARNESS_REPO` set in `workspace.sh` (a fork you can PR against). Wraps `sync-templates.sh --check` (drift detection) → `sync-port.sh --no-merge` (headless porter genericizes your changes and opens a PR against your fork for HUMAN review). NEVER auto-merges. Workspace-specific files (`workspace.sh`, `package.json`, repo lists) are NEVER pushed.

A version stamp lives in `scripts/lib/.harness-version`; `bash scripts/doctor.sh` and `<pm> run govern:health` warn "harness N releases behind" when your workspace lags the hub. Degrades gracefully when the hub can't be resolved.

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
