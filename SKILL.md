---
name: shiploop
description: Multi-subrepo workspace pattern — a workspace (npm, pnpm, or yarn at the root) that wraps N independent git repos as sub-folders and operates them as one product with an autonomous harness. Use as reference when (a) working inside an existing meta-repo workspace (any workspace where sub-folders each have their own .git and the root holds scripts/ + queue/tickets.md + a governor/), or (b) deciding whether the pattern fits a new project. Carries the operating commands, the parallel-worktree model, the ticket queue + /resolve flow, the governor (autonomous ticket loop), the SessionStart/End/Stop hooks, the CLI-vs-MCP autonomy guidance, and the load-bearing anti-patterns. For scaffolding or upgrading a workspace, invoke the /shiploop:setup slash command.
---

# Meta-repo — multi-subrepo workspace + autonomous harness

## What it is

A workspace root that contains multiple independent git repositories as sub-folders. Each sub-repo has its own remote, PR queue, and CI. The root is *also* its own git repo, holding workspace config, cross-cutting scripts, the ticket queue, the governor, and shared AI context. You operate N services as one product without sacrificing their independent deploy cadences or PR isolation — and a harness (worktrees + tickets + governor + hooks) lets a Claude session run for long stretches autonomously, without stopping to ask permission.

Example shape: `your-workspace/{backend,console,website}/` — three sub-folders, each its own git repo, a script launcher at the root invoked via your chosen package manager.

**The root uses ONE package manager — your choice of npm, pnpm, yarn, or bun** (`ROOT_PM` in `scripts/lib/workspace.sh`, default `npm`). The root is private and near-zero-dependency: its `package.json` holds only thin `bash scripts/<x>.sh` aliases, so `npm run dev`, `pnpm dev`, and `yarn dev` all execute the same PM-agnostic bash. `ROOT_PM` only governs which CLI you type and what `doctor` checks for. Each sub-repo independently keeps its OWN package manager (whatever its lockfile says). The one rule: **don't mix two package managers at the root** — a stray second root lockfile (e.g. a `package-lock.json` left by an accidental `npm install` in a pnpm root) diverges from the real one, and some PMs (pnpm v11) rewrite root state on every invocation. The root `.gitignore` ignores the off-PM lockfiles so a stray install can't pollute the tree.

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

Examples below use `npm run` (the default `ROOT_PM`); substitute your root PM — `pnpm <script>`, `yarn <script>`, or `bun run <script>` (the `<pm> run <script>` form works for all four).

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

**Pass args/flags after the script with `--`** — `npm run worktree:new -- <slug>`, `npm run dev -- --only console`. npm and pnpm both need the `--` or they swallow the flags; yarn classic tolerates it either way. Bare verbs are fine without it.

## Parallel worktrees (the isolation primitive)

**Any task that will touch code starts with `npm run worktree:new -- <slug>` and `cd` into it.** The main checkout is for reading, planning, and main-branch ops only — never edit code there. Each worktree is an isolated copy: its own branches, its own dev stack, its own ports, its own SessionEnd cleanup. Parallel Claude sessions don't collide.

- Worktrees live at `$WORKTREE_BASE/<slug>/` (a sibling of the main checkout, so editors/file-watchers don't index them).
- A slot **registry** (`.worktrees/registry.json`, mkdir-locked for atomic allocation) assigns each worktree a slot number. **Ports offset by `slot × 10`** — slot 1 adds 10 to every base port, slot 2 adds 20, etc. (set in `worktree.env`, consumed by `dev.sh`/`status.sh`/hooks). So N stacks run at once without port collisions.
- The **meta-repo worktree is detached at `main`** — workspace-coordination files (CLAUDE.md, queue/tickets.md, learnings.md, scripts/) commit directly to main in the main checkout and are never branched. Only sub-repo code gets a feature branch (in the `--only` set; the rest sit on main read-only).
- A project's per-worktree setup (install deps, codegen, point a DB at prod, per-slot service namespace) lives in the optional `scripts/lib/worktree-bootstrap.sh` hook — `new.sh` calls it; the mechanism stays project-agnostic.
- Clean up with `npm run worktree:rm -- <slug>` after PRs merge (it runs the project's `session-cleanup.sh` first, then removes trees and frees the slot).

**Main checkout stays on `main`, every repo, always.** The `check-main-on-main.sh` SessionStart hook warns on drift. Branch work only in worktrees.

## Ticket queue

A durable, file-based backlog the whole harness reads.

- **`queue/tickets.md`** — work items only: bugs, gaps, missing capabilities, follow-ups. Each is its own numbered `## #N — Title` block (Severity / Where / Observed / Fix direction / Done when / Ref). **Numbers are stable IDs while open** — never renumber an open ticket (in-flight PRs reference it). Gaps from deleted tickets are expected.
- **The queue is ISOLATED to two scopes: the PROJECT + the HARNESS.** `queue/tickets.md` admits only (1) work on this workspace's own sub-repos and (2) improvements to the meta-repo harness itself (`scripts/`, `governor/`, `queue/`, hooks, config). The harness, the project, and any external tool are three isolated concerns that merely share a terminal. Any tool, skill, or product EXTERNAL to those two scopes (a marketing/GTM skill, a doc generator, any bolt-on) MUST NEVER file a ticket into `queue/tickets.md` — even when invoked from the project's terminal — its follow-ups belong in its own tracker. A ticket that turns out to be about external tooling is deleted from the queue, not worked. State this in the root `CLAUDE.md` (always-on context) so in-workspace skill runs inherit it.
- **`tickets-parked.md`** — defer a ticket by moving it here; the governor ignores it. Independent serial numbering (renumber to the destination queue's max+1 when moving).
- **Resolved = a fix PR is OPENED** (not merged). DELETE the entry the same session the PR opens; reference the PR# in the deletion commit. Promote any durable lesson to `CLAUDE.md` first.
- **`/resolve <N>`** does this disciplined close-out: confirm the PR, promote the lesson, delete the entry, then sweep the session diff for newly-discovered tickets and file them.
- The **Stop hook** (`ticket-sweep-reminder.sh`) fires once at the end of a code-touching session (marker-gated on session_id, honors `stop_hook_active`) reminding you to file/delete tickets. Read-only sessions stop silently.

**Capture learnings at natural breakpoints — don't wait to be asked. Route findings by stability, not topic:**

| Where | Use when |
|---|---|
| `queue/tickets.md` | Work items — anything to fix/build later |
| `CLAUDE.md` (root or sub-repo) | Stable, reusable patterns — env vars, conventions, architecture, persistent gotchas. Home for the durable lesson from a fixed bug. **Sub-repo `CLAUDE.md` wins in its scope**; the root file is cross-repo orchestration only |
| `learnings.md` (root or sub-repo) | Only transient/evolving operational knowledge not yet stable enough for CLAUDE.md. Never a work item; never a fixed-bug writeup |
| Project memory (`~/.claude/projects/<encoded-workspace-path>/memory/`) | Strategic cross-session context — product direction, durable preferences |

Bar: would knowing this save a future session 5+ min? If yes, propose the edit and ask before ending the session. The scaffolded root `CLAUDE.md` (`templates/seed/CLAUDE.md`) is the always-on home for these conventions — it auto-loads every session, whereas this skill loads only on demand.

## Governor (autonomous ticket loop)

`npm run govern` / `/govern` launches a **pure-bash driver** (`scripts/govern/run-loop.sh`) that spends ~zero Claude context itself and dispatches a fresh **headless `claude -p` worker** per ticket. This is what lets the workspace grind a backlog unattended.

- **Per ticket:** select (severity-ordered from `queue/tickets.md`) → spawn a worker in a fresh `ticket-<N>` worktree → worker implements + validates + opens a PR and returns a JSON report → for an auto-merge repo, await CI and merge on **green-or-no-checks** → deterministic `queue/tickets.md` bookkeeping (worker never writes it). Frontend/PR-only repos stop at the open PR.
- **Worker autonomy:** workers run `--permission-mode bypassPermissions` (a headless worker can't answer prompts) scoped to throwaway worktrees, with `--setting-sources user` to drop the project's own hooks (so they don't inherit a fleet-wide SessionEnd cleanup or a stdout-clobbering Stop hook). The doctrine in `governor/preferences.md` defines the **hard-stops** (destructive git; prod data / destructive schema / secrets) that make a worker **park + escalate** instead of acting.
- **Always ends:** hard bounds — `GOVERN_MAX_TICKETS` (20), `GOVERN_MAX_BAD_STREAK` (4 consecutive parked/failed), `GOVERN_MAX_RUNTIME` (~4h), `GOVERN_WORKER_TIMEOUT` (1h, a stuck worker is killed not stalled).
- **Progress-preserving:** only a cleanly-resolved worktree is torn down; failed/parked/timed-out worktrees are kept (work survives) and an existing `ticket-<N>` PR is reused on re-run (no duplicate). A clean interrupt leaves the in-flight ticket; re-running resumes. Every exit writes a plain-words `summary.md`.
- **Supervisor** every N resolved tickets (+ on anomaly) audits for duplicates/dependency-ordering/failure-patterns and can `halt`. **Self-improvement** proposes harness fixes to `governor/improvements.md` (observe→propose; opt-in guarded auto-apply).
- **Escalations** land in `governor/escalations.md` for the operator. Answer inline; mark "make this a rule" to grow the doctrine.

Before a live run, from a **plain terminal** (not nested in a Claude session), confirm a child can auth: `claude -p "ping" --model sonnet --strict-mcp-config` should print text, not a 401 (run `claude login` once if it 401s). Workers run lean (`--strict-mcp-config`, no MCP) and scrub inherited `CLAUDE_CODE_*` env — a headless worker that inherits `CLAUDE_CODE_ENTRYPOINT` from a parent session never finalizes (answers but emits no `result`, hangs to the timeout), so `spawn-worker.sh` strips it; a manual nested `claude -p` won't, which is why the preflight wants a real terminal.

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
7. **One package manager at the root — never two.** The root PM is your choice (`ROOT_PM` = npm/pnpm/yarn/bun in `workspace.sh`); the root scripts are PM-agnostic bash aliases, so any of them works. What breaks is *mixing*: a stray second root lockfile (e.g. a `package-lock.json` left by an accidental `npm install` in a pnpm root) diverges from the real one. The root `.gitignore` ignores the off-PM lockfiles to prevent this. Sub-repos keep their own PM independently.
8. **Main checkout stays on `main`, every repo, always. Branch work only in worktrees.** Meta-repo coordination files (CLAUDE.md, queue/tickets.md, learnings.md, scripts/) commit directly to main in the main checkout — never branched/PR'd.
9. **PR opened → tear the local stack down.** Don't leave dev servers idling (zombies hold ports → next `dev` serves stale code on `EADDRINUSE`). Worktree: `npm run worktree:rm`. Backstops: SessionEnd hook + `dev.sh` frees each port before binding.
10. **Workers never write `queue/tickets.md`** — the governor's bookkeeper does, in the main checkout (avoids two writers racing the file).

## Cross-stack discipline

1. `npm run worktree:new -- feat/foo` (or `npm run branch -- feat/foo` for in-place matching branches)
2. Make changes per sub-repo
3. `cd <sub-repo> && git add … && git commit …`
4. `npm run push` (opens PRs across changed repos)
5. Track sibling PRs together; **merge backend-first** (anti-pattern #5) and state the order in each PR.

PRs land independently — don't expect atomicity.

## Setup / upgrade a workspace

Invoke **`/shiploop:setup`**. It is idempotent:
- **Fresh folder:** detects sub-repos (folders with `.git/`), ports, and per-sub-repo dev commands; asks which package manager you'll use at the root (sets `ROOT_PM`); writes `package.json` (thin bash-alias scripts), `.gitignore` (ignoring the off-PM root lockfiles), `scripts/lib/workspace.sh` (the one config file), copies the mechanism scripts, hooks, governor scaffold, and seed `queue/tickets.md`/`learnings.md`; wires `.claude/settings.json`; optionally installs + runs doctor.
- **Existing meta-repo (bump):** detects which capabilities are present (core scripts / worktrees / tickets / governor / hooks) vs missing or outdated, then offers to add/upgrade each. Because all customization lives in `scripts/lib/workspace.sh`, the mechanism scripts are refreshed from latest templates without clobbering your tweaks.

## Tradeoffs (state honestly)

**Costs:** N git remotes multiply every PR/CI/branch op (the scripts wrap most of it); silent cross-stack contract breaks (shared types would hedge — not built by default); custom tooling with no community ecosystem to maintain; the governor consumes real tokens and can open billable resources — the bounds + hard-stops + cleanup hooks contain it but it is not free.

**Gains:** independent deploy cadences without losing cross-product context; bounded file trees but full product visibility for agents; parallel agent work that doesn't merge-conflict; one home for MCP config + shared scripts; and a backlog that a session can grind semi-autonomously.

If a user asks "should I migrate from meta-repo to Turborepo?" — depends on whether their services *actually* deploy independently and whether the abstraction cost has been paid. Don't recommend migration unless they're hitting concrete pain.

## Baseline vs. the production reference harness (intentional omissions)

These templates are a **deliberately-minimal baseline**, not a byte-for-byte mirror of the
production harness this skill was extracted from. The scaffold tracks the governor's *core loop*
(select → spawn worker in a worktree → open PR → green-or-none auto-merge → deterministic
bookkeeping → escalations → supervisor → observe→propose self-improvement). On top of that loop the
production harness has accreted several **governor-internal hardening refinements** that only start
to matter once you run a *large, long, fleet-concurrent* backlog. Those are **intentionally not
vendored into the scaffold** — they add moving parts a fresh or small workspace doesn't need, and
each is easy to port the day you actually hit its failure mode. Recording them here makes the
divergence a *documented choice* rather than silent lag.

Currently omitted from the templates (port from the reference harness as you scale):

| Feature | Reference harness has | The baseline does instead | Why it's safe to omit at first |
|---|---|---|---|
| **Monotonic ticket numbering** (#54) | `govern-bookkeep` allocates new ticket numbers above a persisted high-water mark, so deleting the highest `## #N` then filing a new ticket leaves a *gap* instead of reusing the id | `this-file max + 1` — reuses a number if the previous top ticket was just deleted | Id reuse only bites when an in-flight PR references a now-recycled number; rare below high churn |
| **Tolerant PR-head matching + same-run adoption** (#55) | `find_pr` first tries an exact `ticket-N` head, then falls back to a tolerant `(^\|[^0-9])ticket-N([^0-9]\|$)` regex, and adopts a PR opened earlier in the same run | exact-head only (`--head "ticket-N"`) | A worker that names its branch exactly `ticket-<N>` (the doctrine *requires* this) is always found by the exact match |
| **Tolerant worker-report extraction** (#66) | `extract_report` / `_json_objects` pull the *last* balanced `{…}` object carrying a `status` field out of arbitrary text, so a worker that drifts to "JSON + trailing prose" still counts | whole final message must `jq`-parse as one object | A compliant worker emits *only* the JSON object (the contract); tolerance only rescues a drifting worker |
| **Run-start preflight-main reconcile** (#71) | `preflight-main.sh` reconciles every repo onto a clean `main` before a run starts | no preflight; the run trusts the checkout is on `main` | The main-on-main SessionStart hook already warns on drift; a tidy workspace starts clean |
| **Run-scoped worker logs** (#75) | `worker_logdir` + an exported `GOVERN_RUN_DIR` isolate each run's worker logs so a re-run never reads a prior run's stale log | flat per-ticket log paths | Stale-log confusion only appears across many re-runs of the *same* ticket number |

The `govern-improve.sh` / `govern-self-apply.sh` self-improvement loop **is** scaffolded, but is kept
leaner than the reference harness's copy for the same reason. If you later want the templates to
track the full harness, port the rows above as their own template PRs; otherwise this list is the
record of what the baseline deliberately leaves out.

## Skill location

`~/.claude/skills/shiploop/`. Templates for everything scaffolded above are under `templates/` — `lib/workspace.sh` (config contract), the core git-ops scripts, `worktree/`, `govern/`, `governor/` (prompt scaffolds), `hooks/`, `seed/`, and example `lib/*.sh.example` project hooks.
