---
name: meta-repo
description: Multi-subrepo workspace pattern — an npm-rooted workspace that wraps N independent git repos as sub-folders and operates them as one product with an autonomous harness. Use as reference when (a) working inside an existing meta-repo workspace (any workspace where sub-folders each have their own .git and the root holds scripts/ + tickets.md + a governor/), or (b) deciding whether the pattern fits a new project. Carries the operating commands, the parallel-worktree model, the ticket queue + /resolve flow, the governor (autonomous ticket loop), the SessionStart/End/Stop hooks, the CLI-vs-MCP autonomy guidance, and the load-bearing anti-patterns. For scaffolding or upgrading a workspace, invoke the /meta-repo:setup slash command.
---

# Meta-repo — multi-subrepo workspace + autonomous harness

## What it is

A workspace root that contains multiple independent git repositories as sub-folders. Each sub-repo has its own remote, PR queue, and CI. The root is *also* its own git repo, holding workspace config, cross-cutting scripts, the ticket queue, the governor, and shared AI context. You operate N services as one product without sacrificing their independent deploy cadences or PR isolation — and a harness (worktrees + tickets + governor + hooks) lets a Claude session run for long stretches autonomously, without stopping to ask permission.

Example shape: `your-workspace/{backend,console,website}/` — three sub-folders, each its own git repo, an npm-run launcher at the root.

The **root package manager is npm** (`npm run <script>`). The root is private and zero-dependency — it only holds script aliases. Each sub-repo keeps its OWN package manager (whatever its lockfile says). Don't introduce pnpm/yarn at the root: a stray root lockfile diverges and some PMs rewrite root state on every invocation.

## When to use this pattern

Use it when:
- Multiple services genuinely deploy on independent cadences
- You want to grant a contractor access to one sub-repo without exposing the rest
- AI-assisted coding benefits from full product context while editing one slice at a time, and you want the agent to grind a backlog semi-autonomously
- You want cross-stack QA (frontend ↔ backend ↔ landing) without coupling code

Don't use it when:
- All services deploy together — use Turborepo or a single repo with packages
- Sub-repos share lots of code daily — N git remotes make code sharing painful
- You're early enough that the abstraction cost outweighs deploy-independence

If unsure, default to a single repo or Turborepo. Meta-repo is a deliberate, opinionated choice.

## Operating commands (once installed)

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos; tee each one's output to `logs/<name>.log`. `-- --only a,b` to scope |
| `npm run dev:<name>` | Boot one sub-repo |
| `npm run status` | One-read table: branch / dirty / ahead / behind / PR# / CI per sub-repo |
| `npm run doctor` | Health audit: tooling, env files, ports, sub-repo presence (+ project `doctor-extra.sh`) |
| `npm run branch -- <name>` | Create a branch across sub-repos (or `--only a,b`) |
| `npm run switch -- <name>` | Checkout a branch across all (tracking origin if local missing) |
| `npm run pull` / `npm run push` | `git pull --ff-only` per repo / push changed repos + open PRs via `gh` |
| `npm run health` | Liveness check (HTTP curl each dev server) |
| `npm run worktree:new -- <slug>` | Allocate a slot; create isolated worktrees on branch `<slug>` |
| `npm run worktree:rm -- <slug>` | Clean up + remove a worktree, free its slot |
| `npm run worktree:status` | Slot table (`-- --gc` prunes orphans) |
| `npm run worktree:exec -- <slug> [-- <cmd>]` | Run a command with that slot's env |
| `npm run govern` | Launch the autonomous ticket loop (or `/govern`) |

**npm needs `--` before any arg/flag** — `npm run worktree:new -- <slug>`, `npm run dev -- --only console`. Bare verbs are fine; flags get swallowed without the `--`.

## Parallel worktrees (the isolation primitive)

**Any task that will touch code starts with `npm run worktree:new -- <slug>` and `cd` into it.** The main checkout is for reading, planning, and main-branch ops only — never edit code there. Each worktree is an isolated copy: its own branches, its own dev stack, its own ports, its own SessionEnd cleanup. Parallel Claude sessions don't collide.

- Worktrees live at `$WORKTREE_BASE/<slug>/` (a sibling of the main checkout, so editors/file-watchers don't index them).
- A slot **registry** (`.worktrees/registry.json`, mkdir-locked for atomic allocation) assigns each worktree a slot number. **Ports offset by `slot × 10`** — slot 1 adds 10 to every base port, slot 2 adds 20, etc. (set in `worktree.env`, consumed by `dev.sh`/`status.sh`/hooks). So N stacks run at once without port collisions.
- The **meta-repo worktree is detached at `main`** — workspace-coordination files (CLAUDE.md, tickets.md, learnings.md, scripts/) commit directly to main in the main checkout and are never branched. Only sub-repo code gets a feature branch (in the `--only` set; the rest sit on main read-only).
- A project's per-worktree setup (install deps, codegen, point a DB at prod, per-slot service namespace) lives in the optional `scripts/lib/worktree-bootstrap.sh` hook — `new.sh` calls it; the mechanism stays project-agnostic.
- Clean up with `npm run worktree:rm -- <slug>` after PRs merge (it runs the project's `session-cleanup.sh` first, then removes trees and frees the slot).

**Main checkout stays on `main`, every repo, always.** The `check-main-on-main.sh` SessionStart hook warns on drift. Branch work only in worktrees.

## Ticket queue

A durable, file-based backlog the whole harness reads.

- **`tickets.md`** (root) — work items only: bugs, gaps, missing capabilities, follow-ups. Each is its own numbered `## #N — Title` block (Severity / Where / Observed / Fix direction / Done when / Ref). **Numbers are stable IDs while open** — never renumber an open ticket (in-flight PRs reference it). Gaps from deleted tickets are expected.
- **`tickets-parked.md`** — defer a ticket by moving it here; the governor ignores it. Independent serial numbering (renumber to the destination queue's max+1 when moving).
- **Resolved = a fix PR is OPENED** (not merged). DELETE the entry the same session the PR opens; reference the PR# in the deletion commit. Promote any durable lesson to `CLAUDE.md` first.
- **`/resolve <N>`** does this disciplined close-out: confirm the PR, promote the lesson, delete the entry, then sweep the session diff for newly-discovered tickets and file them.
- The **Stop hook** (`ticket-sweep-reminder.sh`) fires once at the end of a code-touching session (marker-gated on session_id, honors `stop_hook_active`) reminding you to file/delete tickets. Read-only sessions stop silently.

**Route findings by stability, not topic:**

| Where | Use when |
|---|---|
| `tickets.md` | Work items — anything to fix/build later |
| `CLAUDE.md` (root or sub-repo) | Stable, reusable patterns — env vars, conventions, architecture, persistent gotchas. Home for the durable lesson from a fixed bug |
| `learnings.md` | Only transient/evolving operational knowledge not yet stable enough for CLAUDE.md. Never a work item; never a fixed-bug writeup |

## Governor (autonomous ticket loop)

`npm run govern` / `/govern` launches a **pure-bash driver** (`scripts/govern/run-loop.sh`) that spends ~zero Claude context itself and dispatches a fresh **headless `claude -p` worker** per ticket. This is what lets the workspace grind a backlog unattended.

- **Per ticket:** select (severity-ordered from `tickets.md`) → spawn a worker in a fresh `ticket-<N>` worktree → worker implements + validates + opens a PR and returns a JSON report → for an auto-merge repo, await CI and merge on **green-or-no-checks** → deterministic `tickets.md` bookkeeping (worker never writes it). Frontend/PR-only repos stop at the open PR.
- **Worker autonomy:** workers run `--permission-mode bypassPermissions` (a headless worker can't answer prompts) scoped to throwaway worktrees, with `--setting-sources user` to drop the project's own hooks (so they don't inherit a fleet-wide SessionEnd cleanup or a stdout-clobbering Stop hook). The doctrine in `governor/preferences.md` defines the **hard-stops** (destructive git; prod data / destructive schema / secrets) that make a worker **park + escalate** instead of acting.
- **Always ends:** hard bounds — `GOVERN_MAX_TICKETS` (20), `GOVERN_MAX_BAD_STREAK` (4 consecutive parked/failed), `GOVERN_MAX_RUNTIME` (~4h), `GOVERN_WORKER_TIMEOUT` (1h, a stuck worker is killed not stalled).
- **Progress-preserving:** only a cleanly-resolved worktree is torn down; failed/parked/timed-out worktrees are kept (work survives) and an existing `ticket-<N>` PR is reused on re-run (no duplicate). A clean interrupt leaves the in-flight ticket; re-running resumes. Every exit writes a plain-words `summary.md`.
- **Supervisor** every N resolved tickets (+ on anomaly) audits for duplicates/dependency-ordering/failure-patterns and can `halt`. **Self-improvement** proposes harness fixes to `governor/improvements.md` (observe→propose; opt-in guarded auto-apply).
- **Escalations** land in `governor/escalations.md` for the operator. Answer inline; mark "make this a rule" to grow the doctrine.

Before a live run, confirm a child can auth: `claude -p "ping" --model sonnet` should print text, not a 401 (run `claude login` once if it 401s).

## Hooks (deterministic session scaffolding)

Wired into the workspace `.claude/settings.json` by setup:
- **SessionStart:** print the top of `learnings.md` (skim before diving in) · `check-main-on-main.sh` (warn if the main checkout drifted off main) · optional project drift check (e.g. prod-behind-main).
- **Stop:** `ticket-sweep-reminder.sh` (reconcile tickets once per code-touching session).
- **SessionEnd:** `worktree/session-end-cleanup.sh` (run the project cleanup hook, then kill this worktree's stack ports) so dev stacks don't accumulate.

## CLIs and MCPs — built for autonomy

The harness is configured so a session runs **long without stopping to ask permission**:
- **External tools are CLIs, not MCP servers, wherever possible.** Claude shells out (`gh`, `git`, cloud CLIs, the `scripts/*.sh`) — those auth CLI-side once and never prompt mid-session. Reserve MCP servers (registered only in the root `.mcp.json`) for things with no good CLI; auth them via env-var expansion (`${TOKEN}`) so headless/governor runs inherit them. The CLI-vs-MCP asymmetry is intentional — don't look for a "missing" MCP entry for something that's already a CLI.
- **MCP servers always at the workspace root.** Never `claude mcp add` from a sub-repo.
- The governor's workers deliberately run headless (`-p`, `bypassPermissions`, `--setting-sources user`) — the safety comes from the doctrine hard-stops + throwaway worktrees + the merge allowlist, not from interactive prompts.

## Anti-patterns (load-bearing rules)

1. **MCP servers always at root.** Never `claude mcp add` from a sub-repo.
2. **`cd` into the sub-repo before committing.** `git add` from the root won't stage sub-repo files; each commits independently.
3. **Never assume sub-repos share a branch.** They drift. Run `npm run status` first.
4. **Verify which sub-repo you're in before destructive git** (`reset --hard`, `clean -fd`, `branch -D`).
5. **PRs aren't transactional across sub-repos — merge backend-first.** When the backend adds a capability the frontend consumes (enum, endpoint, response field), the backend PR merges + deploys before the frontend PR — else the frontend ships UI the live backend rejects. State the merge order in each sibling PR.
6. **`.env.example` is the contract.** Never commit `.env`. `doctor` checks each `.env` exists.
7. **The root is npm.** No pnpm/yarn/bun at the root — a stray root lockfile diverges. Sub-repos keep their own PM.
8. **Main checkout stays on `main`, every repo, always. Branch work only in worktrees.** Meta-repo coordination files (CLAUDE.md, tickets.md, learnings.md, scripts/) commit directly to main in the main checkout — never branched/PR'd.
9. **PR opened → tear the local stack down.** Don't leave dev servers idling (zombies hold ports → next `dev` serves stale code on `EADDRINUSE`). Worktree: `npm run worktree:rm`. Backstops: SessionEnd hook + `dev.sh` frees each port before binding.
10. **Workers never write `tickets.md`** — the governor's bookkeeper does, in the main checkout (avoids two writers racing the file).

## Cross-stack discipline

1. `npm run worktree:new -- feat/foo` (or `npm run branch -- feat/foo` for in-place matching branches)
2. Make changes per sub-repo
3. `cd <sub-repo> && git add … && git commit …`
4. `npm run push` (opens PRs across changed repos)
5. Track sibling PRs together; **merge backend-first** (anti-pattern #5) and state the order in each PR.

PRs land independently — don't expect atomicity.

## Setup / upgrade a workspace

Invoke **`/meta-repo:setup`**. It is idempotent:
- **Fresh folder:** detects sub-repos (folders with `.git/`), ports, and per-sub-repo dev commands; writes `package.json`, `pnpm`→npm scripts, `.gitignore`, `scripts/lib/workspace.sh` (the one config file), copies the mechanism scripts, hooks, governor scaffold, and seed `tickets.md`/`learnings.md`; wires `.claude/settings.json`; optionally installs + runs doctor.
- **Existing meta-repo (bump):** detects which capabilities are present (core scripts / worktrees / tickets / governor / hooks) vs missing or outdated, then offers to add/upgrade each. Because all customization lives in `scripts/lib/workspace.sh`, the mechanism scripts are refreshed from latest templates without clobbering your tweaks.

## Tradeoffs (state honestly)

**Costs:** N git remotes multiply every PR/CI/branch op (the scripts wrap most of it); silent cross-stack contract breaks (shared types would hedge — not built by default); custom tooling with no community ecosystem to maintain; the governor consumes real tokens and can open billable resources — the bounds + hard-stops + cleanup hooks contain it but it is not free.

**Gains:** independent deploy cadences without losing cross-product context; bounded file trees but full product visibility for agents; parallel agent work that doesn't merge-conflict; one home for MCP config + shared scripts; and a backlog that a session can grind semi-autonomously.

If a user asks "should I migrate from meta-repo to Turborepo?" — depends on whether their services *actually* deploy independently and whether the abstraction cost has been paid. Don't recommend migration unless they're hitting concrete pain.

## Skill location

`~/.claude/skills/meta-repo/`. Templates for everything scaffolded above are under `templates/` — `lib/workspace.sh` (config contract), the core git-ops scripts, `worktree/`, `govern/`, `governor/` (prompt scaffolds), `hooks/`, `seed/`, and example `lib/*.sh.example` project hooks.
