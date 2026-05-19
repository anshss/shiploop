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

<!-- meta-repo:auto-start — managed by /meta-repo:setup and /meta-repo:refresh-claude. Do not edit between these markers; rerun the refresh command instead. -->

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
| `./health.sh` | Liveness check (HTTP curl each dev server) |

## Anti-patterns (load-bearing rules)

1. **MCP servers always at root.** Never run `claude mcp add` from a sub-repo. They must be scoped to the workspace root so they apply across all sub-repos.
2. **Always `cd` into the sub-repo before committing.** The workspace root is its own git repo; `git add` from root will not stage sub-repo files.
3. **Never assume sub-repos are on the same branch.** They drift constantly. Run `pnpm status` before reasoning about branch state.
4. **Never run destructive git commands without verifying which sub-repo you're in.** Easy to wipe the wrong working tree.
5. **PRs are not transactional across sub-repos.** A feature touching multiple sub-repos becomes multiple PRs that merge independently. Plan merge order deliberately.
6. **Sub-repo `.env.example` is the contract.** Never commit `.env` files.

## Refreshing this section

Run `/meta-repo:refresh-claude` to regenerate everything between the meta-repo markers from current repo state. Safe to run anytime — it preserves the user-written section below.

<!-- meta-repo:auto-end -->

---

## Project context (user-written, never auto-overwritten)

<!-- Add anything specific to this project here: purpose, ICP, product decisions, key facts you want every Claude session to know. The auto-refresh command never touches content below the `meta-repo:auto-end` marker. -->

(empty — fill in as you go)
```

Substitute `<workspace-name>` with `basename "$(pwd)"`, `<N>` with the sub-repo count, and the table rows with actual detected sub-repo / port / remote values. For each sub-repo's remote, run `git -C <sub-repo> remote get-url origin 2>/dev/null` and use the result; if empty, write `n/a`.

Make the file. Confirm it exists.

---

## Phase 4.6 — Write per-sub-repo CLAUDE.md files

For each confirmed sub-repo, write a thin CLAUDE.md inside it. This gives agents invoked from inside a sub-repo (`cd app && claude`) the context that they're operating in a meta-repo workspace.

**Per-sub-repo file path:** `<sub-repo>/CLAUDE.md`

**Existing-file handling:** If a sub-repo already has a CLAUDE.md, do not overwrite. Check for `<!-- meta-repo:auto-start -->` marker. If absent, ask: "`<sub-repo>/CLAUDE.md` exists. Prepend the meta-repo auto section, or skip this sub-repo?" If present, treat as already wired — skip.

**Role detection:** Determine each sub-repo's role from these signals (in priority order):
1. `<sub-repo>/package.json` → `description` field if non-empty.
2. Framework markers in `<sub-repo>/`: `next.config.*` → Next.js app, `prisma/schema.prisma` → Prisma backend, `express` in deps → Express API, `vite.config.*` → Vite app, etc.
3. If neither, write `(role: TBD — describe this sub-repo)`.

**Sibling list:** Construct a one-line role-summary per sibling sub-repo using the same detection logic.

**Template to write into each `<sub-repo>/CLAUDE.md`:**

```markdown
# <sub-repo-name>

<!-- meta-repo:auto-start — managed by /meta-repo:setup and /meta-repo:refresh-claude. Do not edit between these markers; rerun the refresh command from the workspace root instead. -->

## Part of a meta-repo workspace

This directory is a sub-repo inside the **<workspace-name>** meta-repo workspace at `../`. The parent is a pnpm workspace wrapping multiple independent git repos as sub-folders.

- **This sub-repo:** `<sub-repo-name>` — <role>
- **Dev port:** <port>
- **Remote:** `<remote>`
- **Workspace root:** `../` (see `../CLAUDE.md` for cross-cutting context and operating commands)

## Sibling sub-repos

| Sub-repo | Role |
|----------|------|
| `../<sibling1>/` | <role1> |
| `../<sibling2>/` | <role2> |
| ... |

## When working here

- This sub-repo is its own git repo. Commits here push to `<remote>`, not the workspace root.
- For cross-cutting commands (status, doctor, dev, branch, push), `cd ..` and use the workspace's pnpm scripts.
- For this sub-repo only: `cd .. && pnpm dev:<sub-repo-name>` boots this one with log tee.
- MCP servers configured at the workspace root (`../.mcp.json`) apply to sessions here as well — do not add MCPs in this sub-repo.
- See `../CLAUDE.md` § anti-patterns for cross-stack discipline rules.

<!-- meta-repo:auto-end -->

---

## Sub-repo-specific notes (user-written, never auto-overwritten)

<!-- Add quirks, gotchas, decisions specific to this sub-repo here. The auto-refresh command never touches content below the `meta-repo:auto-end` marker. -->

(empty — fill in as you go)
```

After writing all per-sub-repo CLAUDE.mds, print:

```
Wrote CLAUDE.md in <N> sub-repos:
  - <name1>/CLAUDE.md (<role1>)
  - <name2>/CLAUDE.md (<role2>)
  - ...
```

**Committing:** Do NOT commit these to each sub-repo's git automatically. Each sub-repo is its own repo with its own PR workflow — let the user decide whether to commit (typically yes, since CLAUDE.md helps any agent invoked there).

---

## Phase 5 — Copy + parameterize scripts

```bash
mkdir -p scripts
cp ~/.claude/skills/meta-repo/templates/{status,doctor,branch,switch,dev,pull-all,push-prs}.sh scripts/
chmod +x scripts/*.sh
```

The templates hardcode `app/backend/website` and the splito-specific port mapping. **You must update each script** to use the user's actual sub-repo names. Specifically:

In `status.sh`, `branch.sh`, `switch.sh`, `pull-all.sh`:
- Look at the bottom of each script for lines like:
  ```
  report "$ROOT"          "root"
  report "$ROOT/app"      "app"
  report "$ROOT/backend"  "backend"
  report "$ROOT/website"  "website"
  ```
- Replace with the user's actual sub-repos.

In `dev.sh`:
- Replace the three `run_one` lines with one per sub-repo.

In `doctor.sh`:
- Replace the `for sub in app backend website` loops with the user's actual sub-repos.
- Replace the hardcoded port list (`3000 3001 4000`) with the user's actual ports.
- Replace the `check_env` calls with one per sub-repo (using `.env` or `.env.local` as appropriate — for Next.js sub-repos use `.env.local`, otherwise `.env`).

In `push-prs.sh`:
- Replace the sub-repo list at the top.

After substitution, verify each script's syntax: `bash -n scripts/<name>.sh`.

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
