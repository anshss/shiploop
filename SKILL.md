---
name: meta-repo
description: Multi-subrepo workspace pattern — pnpm root + N independent git repos operated as one product. Use as reference when (a) working inside an existing meta-repo workspace (splito, or any pnpm workspace where sub-folders each have their own .git) or (b) deciding whether the pattern fits a new project. For scaffolding a new workspace, invoke the dedicated /meta-repo:setup slash command instead. Skill carries operating commands, anti-patterns, and explicit tradeoffs.
---

# Meta-repo — multi-subrepo workspace pattern

## What it is

A workspace root that contains multiple independent git repositories as sub-folders. Each sub-repo (e.g., `app/`, `backend/`, `website/`) has its own remote, PR queue, and CI. The root is *also* its own git repo, holding workspace config, cross-cutting scripts, integrated QA/audit, and shared MCP/agent context. The result: you operate N services as one product without sacrificing their independent deploy cadences or PR isolation.

Reference implementation: `/Users/anshs/Folder/code/splito` (sub-repos: `app/`, `backend/`, `website/`).

## When to use this pattern

Use it when:
- Multiple services genuinely deploy on independent cadences
- You want to grant a contractor or teammate access to one sub-repo without exposing the rest
- AI-assisted coding benefits from full product context while editing one slice at a time
- You want cross-stack QA (frontend ↔ backend ↔ landing) without coupling code

Don't use it when:
- All services deploy together — use Turborepo or a single repo with packages
- Sub-repos share lots of code daily — three git remotes make code sharing painful
- You're early enough that the abstraction cost outweighs deploy-independence

If unsure, default to a single repo or Turborepo. Meta-repo is a deliberate, opinionated choice — not the cheapest path.

## Operating commands (once installed)

| Command | Purpose |
|---------|---------|
| `pnpm dev` | Boot all sub-repos in parallel; tee each one's output to `logs/<name>.log` |
| `pnpm dev:raw` | Original `pnpm --parallel -r dev` (no log tee) |
| `pnpm dev:<name>` | Boot one sub-repo only |
| `pnpm status` | One-read table: branch / dirty / ahead / behind / PR# / CI per sub-repo + root |
| `pnpm doctor` | Health audit: tooling, env files, ports, sub-repo presence, Prisma, port-drift between CLAUDE.md and health.sh |
| `pnpm branch <name>` | Create branch across root + all sub-repos (or `--only a,b`) |
| `pnpm switch <name>` | Checkout branch (tracking origin if local missing) across all |
| `pnpm pull` | `git pull --ff-only` per repo |
| `pnpm push` | Push changed sub-repos and open PRs via `gh` |
| `pnpm audit` | Playwright integration tests against the live stack |
| `pnpm audit:report` | Open the HTML report |
| `./health.sh` | Liveness check (HTTP curl each dev server) |

## Anti-patterns (load-bearing rules)

1. **MCP servers always at root.** Never run `claude mcp add` from a sub-repo. They must be scoped to the workspace root so they apply across all sub-repos. (`splito/.mcp.json` is the canonical example.)
2. **Always `cd` into the sub-repo before committing.** The workspace root is its own git repo; `git add` from root will not stage sub-repo files. Each sub-repo's changes commit independently.
3. **Never assume sub-repos are on the same branch.** They drift constantly. Run `pnpm status` before reasoning about branch state.
4. **Never run destructive git commands (`reset --hard`, `clean -fd`, `branch -D`) without first verifying which sub-repo you're in.** Easy to wipe the wrong working tree.
5. **PRs are not transactional across sub-repos.** A feature touching `app/` + `backend/` becomes two PRs that merge independently. Plan merge order deliberately (usually backend first if it adds an endpoint app calls).
6. **Sub-repo `.env.example` is the contract.** Never commit `.env` files. `pnpm doctor` checks for the existence of `.env` per sub-repo.

## Cross-stack discipline

When a change touches multiple sub-repos:
1. `pnpm branch feat/foo` — creates matching branches everywhere (root included)
2. Make changes in each sub-repo
3. `cd <sub-repo> && git add ... && git commit ...` per sub-repo
4. `pnpm push` — opens PRs across all changed sub-repos
5. Track the sibling PRs together (paste each PR URL into the others' descriptions if you want explicit linking)

Each PR lands independently. Don't expect atomicity.

## Setup in a new project

If asked to set up a meta-repo workspace in a new repo:

1. **Verify intent.** Does this project actually have N independently-deploying services? If not, stop and recommend Turborepo/single repo instead.
2. **Inventory sub-repos.** Confirm each sub-repo exists (or is about to be cloned in) as a sub-folder with its own `.git/`.
3. **Scaffold root:**
   - `package.json` with the script entries listed under "Operating commands" above
   - `pnpm-workspace.yaml` listing sub-repo folders as `packages`
   - `.gitignore` that excludes each sub-repo folder (each has its own git tree), `node_modules/`, `.env*` (with `!.env.example`), `logs/`
   - `scripts/` directory — copy the templates from `templates/` in this skill
   - `CLAUDE.md` at root with project context, sub-repo table, and the anti-patterns above
4. **Customize scripts.** Each template has a `REPOS` array near the top — set it to match your actual sub-repos and ports.
5. **Initialize:**
   - `pnpm install`
   - `chmod +x scripts/*.sh`
   - `pnpm doctor` to verify

Hand the user a list of what was created and what still needs configuring (e.g., `.env` files, MCP tokens, Prisma migration).

## Tradeoffs (state honestly when asked)

**Costs you'll pay:**
- Three git remotes multiply every PR, CI, and branch operation by N (the scripts here wrap that — without them, the friction is severe)
- Silent cross-stack contract breaks: backend changes a response shape, app discovers at runtime. Shared types would hedge this — not built by default.
- Custom tooling: no community ecosystem. You maintain it.

**Gains you get:**
- Independent deploy cadences without losing cross-product context
- AI agents get bounded file trees but full product visibility
- Parallel agent work across sub-repos doesn't merge-conflict (different git indexes)
- Workspace root is the single home for MCP config, audit harness, and shared scripts

If a user asks "should I migrate from meta-repo to Turborepo?" — the answer depends on whether their services *actually* deploy independently and whether the abstraction cost has been paid. Sunk cost is real; don't recommend migration unless they're hitting concrete pain.

## Skill location

This skill lives at `~/.claude/skills/meta-repo/`. Templates for the scripts referenced in "Operating commands" are at `~/.claude/skills/meta-repo/templates/`.
