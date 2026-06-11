# meta-repo

A Claude Code skill that scaffolds and operates **multi-subrepo workspaces with an autonomous harness** — a pattern where one npm-rooted parent workspace wraps N independent git repositories as sub-folders. The workspace root provides cross-cutting tooling (dev, status, doctor, branch ops, parallel PR push), **parallel git worktrees**, a **file-based ticket queue**, and a **governor** that drives headless `claude -p` workers to grind that backlog semi-autonomously. Each sub-repo keeps its own remote, PR queue, and CI.

## When this pattern fits

You have multiple services that ship on independent cadences (e.g., `backend/`, `console/`, `website/`), but you want to operate them as one product — share product context with AI agents, run parallel work without merge conflicts, and let a session work a backlog for long stretches without stopping for permission.

## When it doesn't

- All services deploy together → use Turborepo or a single repo
- Sub-repos share a lot of code daily → N git remotes make code sharing painful
- You're early enough that the abstraction cost outweighs deploy-independence

## Install

```bash
git clone <this-repo> ~/.claude/skills/meta-repo
bash ~/.claude/skills/meta-repo/install.sh
```

The install script symlinks `commands/` into `~/.claude/commands/meta-repo/`, making `/meta-repo:setup`, `/meta-repo:resolve`, and `/meta-repo:govern` available in every Claude Code session.

## Usage

In a folder containing your sub-repos as sub-folders (each with its own `.git/`):

```
/meta-repo:setup
```

The setup command is **idempotent**:
- **Fresh folder** → full scaffold: detects sub-repos, ports, and per-sub-repo dev commands; writes `package.json` (npm-run scripts), `.gitignore`, the single config file `scripts/lib/workspace.sh`, the mechanism scripts, hooks, the governor scaffold, and seed `tickets.md`/`learnings.md`; wires `.claude/settings.json`; optionally installs + runs doctor.
- **Existing meta-repo** → component-by-component **bump**: detects which capabilities are present (core scripts / worktrees / tickets / governor / hooks) vs missing or outdated and offers to add/upgrade each. All customization lives in `scripts/lib/workspace.sh`, so mechanism scripts refresh from latest templates without clobbering your tweaks.

## What you get

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos; tee output to `logs/<name>.log` (`-- --only a,b` to scope) |
| `npm run status` | Branch / dirty / ahead / behind / PR# / CI per sub-repo |
| `npm run doctor` | Tooling + env + ports + workspace health audit (+ project `doctor-extra.sh`) |
| `npm run branch -- <name>` / `npm run switch -- <name>` | Cross-sub-repo branch create / checkout |
| `npm run pull` / `npm run push` | ff-only pull / push changed repos + auto-open PRs via `gh` |
| `npm run health` | HTTP liveness check on each dev server |
| `npm run worktree:new\|rm\|status\|exec` | Parallel isolated worktrees (slot registry, port-offset, per-slot bootstrap) |
| `npm run govern` (or `/govern`) | Autonomous ticket loop — headless workers, green-or-none auto-merge, bounded |
| `/meta-repo:resolve <N>` | Disciplined ticket close-out (confirm PR → promote lesson → delete → sweep) |

## The harness (what makes this more than a script bundle)

- **Worktrees** — `worktree:new` allocates a slot (atomic mkdir-locked registry), creates a meta worktree detached at main + sub-repo worktrees on a feature branch, offsets every port by `slot × 10`, and runs an optional per-project bootstrap. `SessionEnd` tears the stack down. Parallel Claude sessions never collide.
- **Ticket queue** — `tickets.md` (numbered, stable-ID work items) + `tickets-parked.md` + `/resolve` + a Stop hook that reconciles tickets at the end of a code-touching session.
- **Governor** — a pure-bash driver dispatches a fresh headless `claude -p` worker per ticket: select → implement-in-worktree → open PR → green-or-none auto-merge (allowlisted repos only) → deterministic bookkeeping. Hard bounds, hard-stop doctrine (park + escalate), progress preservation, supervisor, and observe→propose self-improvement.
- **Hooks** — SessionStart (learnings skim + main-on-main check + optional drift check), Stop (ticket sweep), SessionEnd (worktree cleanup).
- **CLI-first** — external tools are CLIs Claude shells out to (auth once, never prompt mid-run); MCP servers live only in the root `.mcp.json`. Built so a session runs long without asking permission.

## Architecture — one config file

Every mechanism script sources **`scripts/lib/workspace.sh`** — the single generated file holding this workspace's specifics (sub-repo names, dev commands, ports, GitHub org, worktree base, the governor merge allowlist). The mechanism scripts are therefore byte-identical across every install, which is what makes the `/meta-repo:setup` bump safe: it refreshes mechanism scripts from latest templates and only ever (re)writes `workspace.sh` for your customization.

## Repo layout

```
meta-repo/
├── SKILL.md                  # Ambient reference doc (loaded by description match)
├── commands/
│   ├── setup.md              # /meta-repo:setup — scaffold + idempotent bump
│   ├── resolve.md            # /meta-repo:resolve — disciplined ticket close-out
│   └── govern.md             # /meta-repo:govern — launch the autonomous loop
├── templates/
│   ├── lib/workspace.sh          # the one config file every script sources
│   ├── lib/*.sh.example          # optional project hooks (worktree-bootstrap, session-cleanup, doctor-extra)
│   ├── status|doctor|branch|switch|dev|pull-all|push-prs|health.sh
│   ├── worktree/{new,rm,status,exec,main,session-end-cleanup}.sh + lib/registry.sh
│   ├── govern/{run-loop,spawn-worker,select-ticket,await-ci,merge-pr,
│   │           govern-bookkeep,govern-supervise,govern-improve,govern-self-apply,dry-run}.sh + lib/common.sh
│   ├── governor/{README,preferences,worker-prompt,supervisor-prompt,escalations,improvements}.md
│   ├── hooks/{check-main-on-main,ticket-sweep-reminder}.sh
│   ├── seed/{tickets,tickets-parked,learnings}.md
│   └── gitignore
└── install.sh                # Symlinks commands/ → ~/.claude/commands/meta-repo/
```

## Anti-patterns (load-bearing rules the skill enforces)

1. **MCP servers always at root.** Never `claude mcp add` from a sub-repo.
2. **`cd` into the sub-repo before committing.** `git add` from root won't stage sub-repo files.
3. **Never assume sub-repos share a branch.** They drift. Run `npm run status` first.
4. **Verify which sub-repo you're in before destructive git.**
5. **PRs aren't transactional — merge backend-first.**
6. **`.env.example` is the contract.** Never commit `.env`.
7. **The root is npm.** No pnpm/yarn/bun at the root.
8. **Main checkout stays on `main`; branch work only in worktrees.** Coordination files commit direct to main.
9. **PR opened → tear the local stack down.**
10. **Workers never write `tickets.md`** — the governor's bookkeeper does.

## Status

A small, opinionated skill maintained for personal use. It scaffolds a pattern used in production but isn't a polished open-source product. PRs welcome; expect terse responses.

The templates are a **deliberately-minimal baseline**, not a byte-for-byte mirror of the production harness this skill was extracted from. They track the governor's core loop; several governor-internal hardening refinements (monotonic ticket numbering, tolerant PR-head matching, tolerant worker-report extraction, run-start preflight-main reconcile, run-scoped worker logs) are intentionally omitted until you run a large, long, fleet-concurrent backlog. See **"Baseline vs. the production reference harness (intentional omissions)"** in `SKILL.md` for the full list and rationale.
