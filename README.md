# meta-repo

A Claude Code skill that scaffolds and operates **multi-subrepo pnpm workspaces** — a pattern where one parent workspace wraps N independent git repositories as sub-folders. The workspace root provides cross-cutting tooling (dev, status, doctor, branch ops, parallel PR push); each sub-repo keeps its own remote, PR queue, and CI.

## When this pattern fits

You have multiple services that ship on independent cadences (e.g., `app/`, `backend/`, `website/`), but you want to operate them as one product — share product context with AI agents, run cross-stack QA, dispatch parallel work without merge conflicts.

You don't have to give up sub-repo independence to get workspace-level ergonomics.

## When it doesn't

- All services deploy together → use Turborepo or a single repo
- Sub-repos share a lot of code daily → three git remotes make code sharing painful
- You're early enough that the abstraction cost outweighs deploy-independence

## Install

```bash
git clone https://github.com/anshss/meta-repo.git ~/.claude/skills/meta-repo
bash ~/.claude/skills/meta-repo/install.sh
```

The install script symlinks `commands/` into `~/.claude/commands/meta-repo/`, making `/meta-repo:setup` available in every Claude Code session.

## Usage

In any folder containing your sub-repos as sub-folders (each with its own `.git/`):

```
/meta-repo:setup
```

Claude walks an 8-phase interactive scaffolder:

1. Detects existing setup vs fresh
2. Inventories sub-repos (folders with `.git/`)
3. Detects dev ports from each sub-repo's `package.json`
4. Writes `package.json`, `pnpm-workspace.yaml`, `.gitignore`, `health.sh`
5. Writes workspace-root `CLAUDE.md` with auto-managed + user-written sections
6. Copies + parameterizes the 7 cross-cutting scripts into `scripts/`
7. Optionally runs `pnpm install` + `pnpm doctor`
8. Optionally initializes root git, reports what was created

After setup, you get:

| Command | Purpose |
|---------|---------|
| `pnpm dev` | Boot all sub-repos in parallel; tee output to `logs/<name>.log` |
| `pnpm dev:<name>` | Boot one sub-repo |
| `pnpm status` | Single-read state table: branch / dirty / ahead / behind / PR# / CI per sub-repo |
| `pnpm doctor` | Tooling + env + ports + workspace health audit |
| `pnpm branch <name>` | Create branch across root + sub-repos (`--only a,b` to scope) |
| `pnpm switch <name>` | Checkout branch across all (tracks origin if local missing) |
| `pnpm pull` | `git pull --ff-only` per repo |
| `pnpm push` | Push changed sub-repos and auto-open PRs via `gh` |
| `./health.sh` | HTTP liveness check on each dev server |

## Repo layout

```
meta-repo/
├── SKILL.md              # Ambient skill — reference doc loaded by description match
├── commands/
│   └── setup.md          # /meta-repo:setup slash command
├── templates/            # Cross-cutting scripts (copied + parameterized at scaffold)
│   ├── status.sh         # Live-state table
│   ├── doctor.sh         # Health audit (24+ checks)
│   ├── branch.sh         # Cross-sub-repo branch creation
│   ├── switch.sh         # Cross-sub-repo checkout
│   ├── dev.sh            # Parallel dev with per-sub-repo log tee
│   ├── pull-all.sh       # ff-only pull across all
│   ├── push-prs.sh       # Push + auto-open PRs via gh
│   └── health.sh         # HTTP liveness check
└── install.sh            # Symlinks commands/ → ~/.claude/commands/meta-repo/
```

## Anti-patterns (load-bearing rules the skill enforces)

1. **MCP servers always at root.** Never run `claude mcp add` from a sub-repo — they must be scoped to the workspace root.
2. **Always `cd` into the sub-repo before committing.** The workspace root is its own git repo; `git add` from root won't stage sub-repo files.
3. **Never assume sub-repos are on the same branch.** They drift. Run `pnpm status` first.
4. **Never run destructive git commands without verifying which sub-repo you're in.**
5. **PRs are not transactional across sub-repos.** Plan merge order deliberately (usually backend before app if there's a new endpoint).
6. **Sub-repo `.env.example` is the contract.** Never commit `.env`.

## CLAUDE.md auto-managed section

`/meta-repo:setup` writes a workspace-root `CLAUDE.md` with delimited sections:

- **Between `<!-- meta-repo:auto-start -->` and `<!-- meta-repo:auto-end -->`** — structural: sub-repo table, operating commands, anti-patterns. Regenerable from current state by asking Claude to refresh.
- **Below the end marker** — user-written: project purpose, decisions, accumulated learnings, per-sub-repo notes. Never auto-overwritten.

Agents invoked from inside a sub-repo (e.g., `cd app && claude`) automatically load the workspace `CLAUDE.md` via Claude Code's parent-directory walk — no per-sub-repo files needed.

## Tradeoffs (honest)

**Costs:**
- Three git remotes multiply every PR, CI, and branch op by N — the scripts here wrap most of that pain
- No central tracking for sub-repo CLAUDE.md content (git can't track files inside embedded repos); everything lives in the workspace root
- Custom tooling, no community ecosystem like Turborepo

**Gains:**
- Independent deploy cadences without losing cross-product context
- AI agents get bounded file trees but full product visibility
- Parallel agent work across sub-repos doesn't merge-conflict (different git indexes)
- Workspace root is the canonical home for MCP config, shared scripts, integrated QA harness

## Status

This is a small, opinionated skill maintained for personal use. It scaffolds a pattern that's been used in production but isn't a polished open-source product. PRs welcome; expect terse responses.
