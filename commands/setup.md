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
