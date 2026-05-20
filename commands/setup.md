---
model: opus
effort: medium
description: Scaffold a meta-repo workspace in the current folder. Detects sub-repos (folders with their own .git), confirms with the user, then writes package.json, pnpm-workspace.yaml, .gitignore, and parameterized scripts copied from the meta-repo skill templates. Idempotent — re-running on an existing meta-repo will report what's already present and offer to update.
---

You are the meta-repo setup command. Your job is to convert the current folder into a meta-repo workspace: a pnpm workspace root that wraps N independent git sub-repos and provides cross-cutting tooling (status, doctor, branch, switch, dev with per-sub-repo logs, pull-all, push-prs).

The full pattern, anti-patterns, and operating commands are documented in `~/.claude/skills/meta-repo/SKILL.md`. Read that file first if you need context on what you're scaffolding. Templates live at `~/.claude/skills/meta-repo/templates/`.

---

## Phase 1 — Verify intent + detect existing setup

Print: `── meta-repo setup ──`

Run these checks in the current working directory (root of the would-be workspace):

1. `pwd` — confirm where we are.
2. `ls -la` — show the user what's here.
3. Check if `package.json` exists. If yes, grep for `"status": "bash scripts/status.sh"` or similar meta-repo markers. If found, this is already a meta-repo workspace.

**If already a meta-repo:** print "This folder is already a meta-repo workspace." Show `pnpm doctor` output to confirm health. Ask: "Want to (a) update scripts from latest templates, (b) re-run doctor only, or (c) abort?" Wait for answer.

**If not a meta-repo:** continue.

---

## Phase 2 — Inventory sub-repos

Find sub-folders that are independent git repos:

```bash
for d in */; do
  [ -d "$d/.git" ] && echo "$d"
done
```

If zero sub-repos found, stop and tell the user: "No sub-folders with their own .git found. Meta-repo wraps independent git repos as sub-folders. Clone your sub-repos into this folder first (e.g., `git clone https://github.com/.../<name>.git`), then re-run `/meta-repo:setup`."

If sub-repos found, print them in a numbered list. Ask: "Detected N sub-repos: [list]. Use these? (yes / pick subset / cancel)"

---

## Phase 3 — Detect ports

For each confirmed sub-repo, try to detect its dev port:

1. Read `<sub-repo>/package.json`. Look for `"dev"` script.
2. Grep for `-p (\d{4})` (Next.js style) or `PORT=(\d+)` (Express style).
3. If found, record port. If not found, mark as "unknown" and ask the user.

Print a table:

```
sub-repo   detected port
--------   --------------
app        3001
backend    4000
website    3000
```

Ask: "Are these ports correct? (yes / fix manually)"

If the user wants to fix, accept their correction. These ports go into `health.sh` and `doctor.sh`.

---

## Phase 4 — Scaffold root files

Write the following files. **Do not overwrite existing files without asking** — for each, check if it exists, and if so ask "Overwrite / merge / skip?"

### `package.json`

```json
{
  "name": "<folder-name>-meta-repo",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "bash scripts/dev.sh",
    "dev:raw": "pnpm --parallel -r dev",
    <!-- one dev:<name> line per sub-repo, using pnpm --filter -->
    "build": "pnpm --parallel -r build",
    "lint": "pnpm --parallel -r lint",
    "install:all": "pnpm install -r",
    "pull": "bash scripts/pull-all.sh",
    "push": "bash scripts/push-prs.sh",
    "status": "bash scripts/status.sh",
    "doctor": "bash scripts/doctor.sh",
    "branch": "bash scripts/branch.sh",
    "switch": "bash scripts/switch.sh"
  }
}
```

Folder name = `basename "$(pwd)"`. The `dev:<name>` lines should use `pnpm --filter <package-name>` where `<package-name>` is the `name` field from each sub-repo's `package.json`.

### `pnpm-workspace.yaml`

```yaml
packages:
  - "<sub-repo-1>"
  - "<sub-repo-2>"
  - ...
```

### `.gitignore`

```
# sub-repos — each has its own git
<sub-repo-1>/
<sub-repo-2>/
...

# deps & generated
node_modules/
.pnpm-store/

# secrets
.env
.env.*
!.env.example

# dev server logs (per-sub-repo, written by scripts/dev.sh)
logs/

# local tooling
.DS_Store
.claude/settings.local.json
```

### `health.sh` at root

Copy `~/.claude/skills/meta-repo/templates/health.sh` and update the `check` lines for the user's actual sub-repos + ports. Make executable.

---

## Phase 4.5 — Write CLAUDE.md (initial)

If `CLAUDE.md` already exists at the workspace root, **do not overwrite it**. Instead, check whether it contains the `<!-- meta-repo:auto-start -->` delimiter. If not, ask the user: "An existing CLAUDE.md is here. Add the meta-repo auto-managed section to the top, or skip and refresh manually later?" If they say add, prepend the auto section with delimiters above their existing content. If skip, move on.

If `CLAUDE.md` does not exist, write a new one with this structure:

```markdown
# <workspace-name>

<!-- meta-repo:auto-start — managed by /meta-repo:setup; regenerable. Don't edit between these markers by hand; ask Claude to refresh this section from current state and it will rewrite only what's inside. -->

## Workspace shape

This is a pnpm workspace wrapping <N> independent git repos as sub-folders (the meta-repo pattern). Each sub-repo deploys on its own cadence with its own PR queue and CI; the workspace root provides cross-cutting tooling.

| Sub-repo | Port | Remote |
|----------|------|--------|
| `<name1>/` | <port1> | `<github-remote-1>` |
| `<name2>/` | <port2> | `<github-remote-2>` |
| ...        |        |                       |

(If a sub-repo's remote can't be detected via `git -C <sub> remote get-url origin`, write `n/a`.)

## Operating commands

| Command | Purpose |
|---------|---------|
| `pnpm dev` | Boot all sub-repos in parallel; tee output to `logs/<name>.log` |
| `pnpm dev:raw` | Original `pnpm --parallel -r dev` (no log tee) |
| `pnpm status` | One-read state table: branch / dirty / ahead / behind / PR# / CI per sub-repo |
| `pnpm doctor` | Tooling + env + ports + workspace health audit |
| `pnpm branch <name>` | Create branch across root + sub-repos (or `--only a,b`) |
| `pnpm switch <name>` | Checkout branch (tracking origin if local missing) across all |
| `pnpm pull` | `git pull --ff-only` per repo |
| `pnpm push` | Push changed sub-repos and open PRs via `gh` |
| `./health.sh` | Liveness check (HTTP curl each dev server — web projects only) |

## Anti-patterns (load-bearing rules)

1. **MCP servers always at root.** Never run `claude mcp add` from a sub-repo. They must be scoped to the workspace root so they apply across all sub-repos.
2. **Always `cd` into the sub-repo before committing.** The workspace root is its own git repo; `git add` from root will not stage sub-repo files.
3. **Never assume sub-repos are on the same branch.** They drift constantly. Run `pnpm status` before reasoning about branch state.
4. **Never run destructive git commands without verifying which sub-repo you're in.** Easy to wipe the wrong working tree.
5. **PRs are not transactional across sub-repos.** A feature touching multiple sub-repos becomes multiple PRs that merge independently. Plan merge order deliberately.
6. **Sub-repo `.env.example` is the contract.** Never commit `.env` files.

## Refreshing this section

When the workspace structure changes (new/removed sub-repo, port change, new pnpm script), ask Claude to refresh this section from current repo state. Claude rewrites only the content between the `meta-repo:auto-start/end` markers; the user-written section below is preserved.

<!-- meta-repo:auto-end -->

---

## Project context (user-written, never auto-overwritten)

<!-- Add anything specific to this project here: purpose, ICP, product decisions, key facts you want every Claude session to know. The auto-refresh command never touches content below the `meta-repo:auto-end` marker. -->

(empty — fill in as you go)

## Sub-repo notes

Per-sub-repo learnings — accumulated over time, never auto-overwritten. Append quirks, gotchas, and decisions as you discover them. Agents working inside a sub-repo auto-load this file via Claude Code's parent-directory walk, so anything you write here is visible from sub-repo sessions too.

### `<name1>/` — <role1>

(empty — fill in as you go)

### `<name2>/` — <role2>

(empty — fill in as you go)
```

Substitute `<workspace-name>` with `basename "$(pwd)"`, `<N>` with the sub-repo count, the table rows with actual detected sub-repo / port / remote values, and the `### <name>/ — <role>` sub-headings (one per detected sub-repo) under `## Sub-repo notes` with detected names + roles. For each sub-repo's remote, run `git -C <sub-repo> remote get-url origin 2>/dev/null` and use the result; if empty, write `n/a`. For role detection, prefer `<sub>/package.json`'s `description` field, fall back to framework markers (`next.config.*` → Next.js, `prisma/` → Prisma backend, `express` in deps → Express API, `vite.config.*` → Vite app), else `(role: TBD)`.

Make the file. Confirm it exists.

**Why no per-sub-repo CLAUDE.md files?** Git treats sub-repos with their own `.git/` as embedded repos and refuses to track files inside them from the meta-repo root. Sub-repo learnings would either need 3 separate PRs to each sub-repo's git, or a symlink workaround, or stay untracked. The accepted trade-off is to keep all learnings in the workspace-root CLAUDE.md — agents working from inside a sub-repo still see this file via Claude Code's automatic parent-directory walk.

---

## Phase 5 — Copy + parameterize scripts

```bash
mkdir -p scripts
cp ~/.claude/skills/meta-repo/templates/{status,doctor,branch,switch,dev,pull-all,push-prs}.sh scripts/
chmod +x scripts/*.sh
```

Each template has a `# ── customize:` block near the top defining a `REPOS=(...)` array (and `PORTS=(...)` / `REPOS_PORTS=(...)` where ports matter). **Update those arrays in every script to match the user's actual sub-repo folder names and ports.**

Files to edit:
- `status.sh`, `branch.sh`, `switch.sh`, `pull-all.sh`, `dev.sh`, `push-prs.sh` — set `REPOS=(...)` to the detected sub-repo names
- `doctor.sh` — set `REPOS=(...)` AND `PORTS=(...)` (same order, one port per repo)
- `health.sh` — set `REPOS_PORTS=("name:port" ...)`

After substitution, verify each script's syntax: `bash -n scripts/<name>.sh`. The scripts loop over the arrays, so no other edits are needed.

`push-prs.sh` auto-derives each sub-repo's `<org>/<repo>` from its `git remote get-url origin` — you don't need to set a separate GitHub-org list.

---

## Phase 6 — Initialize

Ask the user: "Ready to run `pnpm install` and `pnpm doctor`? This installs deps (may take 30-60s) and verifies the setup. (yes / skip)"

If yes:
1. Run `pnpm install` (use Bash with run_in_background for the install).
2. Once install completes, run `pnpm doctor`.
3. Show the doctor output to the user.

If doctor reports failures (e.g., missing `.env` files), tell the user which sub-repos need attention but don't try to fix automatically — env files contain secrets the user must provide.

---

## Phase 7 — Initialize root git (optional)

Ask: "Initialize git at the root so the workspace itself is versioned? (yes / no — I'll do it myself later)"

If yes:
```bash
git init
git add package.json pnpm-workspace.yaml .gitignore scripts/ health.sh
git commit -m "init: meta-repo workspace"
```

Do not push. The user adds the remote and pushes themselves.

---

## Phase 8 — Report

Print a final summary:

```
── meta-repo workspace ready ──

Sub-repos:    <name1> (port <p1>), <name2> (port <p2>), ...
Scripts:      scripts/{status,doctor,branch,switch,dev,pull-all,push-prs}.sh
Health:       ./health.sh

Try:
  pnpm status     # live state across all sub-repos
  pnpm dev        # boot all sub-repos with per-repo log tee
  pnpm branch feat/foo  # create matching branches everywhere

What still needs you:
  - Per-sub-repo .env files (see <sub-repo>/.env.example)
  - Root CLAUDE.md if you want project context loaded for AI sessions
  - MCP servers via .mcp.json at root (never inside a sub-repo)
```

Stop. Do not proactively suggest building further features unless asked.
