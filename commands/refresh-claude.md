---
model: sonnet
effort: low
description: Regenerate the auto-managed section of every meta-repo CLAUDE.md from current repo state — the workspace-root CLAUDE.md AND each sub-repo's CLAUDE.md. Preserves all user-written content below each `meta-repo:auto-end` marker. Run after adding/removing sub-repos, changing ports, updating operating commands, or editing role descriptions. Idempotent — safe to run anytime.
---

You are the meta-repo CLAUDE.md refresher. Your job is to rewrite **only** the content between `<!-- meta-repo:auto-start -->` and `<!-- meta-repo:auto-end -->` in:

1. The workspace-root `CLAUDE.md`
2. Each sub-repo's `<sub-repo>/CLAUDE.md`

Everything outside those markers — including any project-specific or sub-repo-specific context the user has written — must be preserved exactly.

---

## Step 1 — Verify this is a meta-repo workspace

Working dir = `pwd`. Check the marker files:
- `package.json` exists and contains `"status": "bash scripts/status.sh"` (the canonical meta-repo signature)
- `pnpm-workspace.yaml` exists

If either is missing, tell the user: "This folder doesn't look like a meta-repo workspace. Run `/meta-repo:setup` first, or cd into a meta-repo workspace." Exit.

## Step 2 — Detect current state

Collect:

1. **Sub-repos** — top-level folders containing a `.git/`:
   ```bash
   for d in */; do [ -d "$d/.git" ] && echo "${d%/}"; done
   ```

2. **Per sub-repo: port, remote, role.**
   - **Port:** read `<sub>/package.json` → grep `dev` script for `-p (\d{4})` or `PORT=(\d+)`. If absent, mark `?` (and note for the report).
   - **Remote:** `git -C <sub> remote get-url origin 2>/dev/null` → output or `n/a`.
   - **Role:** `<sub>/package.json` `description` field if non-empty. Otherwise infer from framework markers (`next.config.*` → Next.js, `prisma/` → Prisma backend, `express` in deps → Express API, `vite.config.*` → Vite app). Otherwise `(role: TBD)`.

3. **Available pnpm scripts** — read root `package.json`, list `scripts.*` keys.

4. **Workspace name** — `basename "$(pwd)"`.

## Step 3 — Refresh the workspace-root CLAUDE.md

Locate `./CLAUDE.md`.

- If missing: ask "No CLAUDE.md at workspace root. Create one fresh? (yes / no)" → if yes, write the full root template from `/meta-repo:setup` Phase 4.5.
- If present and contains both markers: replace the substring between (and including) `<!-- meta-repo:auto-start -->` and `<!-- meta-repo:auto-end -->` with the regenerated root auto section (template below).
- If present but missing markers: ask "No meta-repo markers found in root CLAUDE.md. Prepend the auto section? (yes / no)" → if yes, prepend.
- If only one marker (corrupted): warn and skip this file.

**Root auto section template** (substitute detected values):

```markdown
<!-- meta-repo:auto-start — managed by /meta-repo:setup and /meta-repo:refresh-claude. Do not edit between these markers; rerun the refresh command instead. -->

## Workspace shape

This is a pnpm workspace wrapping <N> independent git repos as sub-folders (the meta-repo pattern). Each sub-repo deploys on its own cadence with its own PR queue and CI; the workspace root provides cross-cutting tooling.

| Sub-repo | Port | Remote |
|----------|------|--------|
| `<name1>/` | <port1> | `<remote1>` |
| ... |

## Operating commands

| Command | Purpose |
|---------|---------|
| `pnpm <name>` | <one-line purpose for each script in package.json> |
| ... |
| `./health.sh` | Liveness check (HTTP curl each dev server) |

(Use descriptions from the canonical meta-repo set for known scripts; for any user-added scripts, write a brief inferred purpose or `(custom)`.)

## Anti-patterns (load-bearing rules)

1. **MCP servers always at root.** Never run `claude mcp add` from a sub-repo. They must be scoped to the workspace root so they apply across all sub-repos.
2. **Always `cd` into the sub-repo before committing.** The workspace root is its own git repo; `git add` from root will not stage sub-repo files.
3. **Never assume sub-repos are on the same branch.** They drift constantly. Run `pnpm status` before reasoning about branch state.
4. **Never run destructive git commands without verifying which sub-repo you're in.** Easy to wipe the wrong working tree.
5. **PRs are not transactional across sub-repos.** A feature touching multiple sub-repos becomes multiple PRs that merge independently. Plan merge order deliberately.
6. **Sub-repo `.env.example` is the contract.** Never commit `.env` files.

## Refreshing this section

Run `/meta-repo:refresh-claude` to regenerate every meta-repo-managed section (root + each sub-repo) from current state. Safe to run anytime — preserves user-written content.

<!-- meta-repo:auto-end -->
```

Write the result back to `./CLAUDE.md`.

## Step 4 — Refresh each sub-repo's CLAUDE.md

For each detected sub-repo, repeat the same marker-aware update inside `<sub-repo>/CLAUDE.md`.

- If `<sub-repo>/CLAUDE.md` is missing: ask "Create CLAUDE.md in `<sub-repo>/`? (yes / no — skip this one)" → if yes, write the full sub-repo template.
- If present with both markers: replace the section between markers with the regenerated sub-repo auto section (template below).
- If present but missing markers: ask "No meta-repo markers in `<sub-repo>/CLAUDE.md`. Prepend? (yes / no)" → if yes, prepend.
- If only one marker (corrupted): warn for this sub-repo and skip.

**Sub-repo auto section template** (substitute detected values for THIS sub-repo and its siblings):

```markdown
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
- MCP servers configured at the workspace root (`../.mcp.json`) apply to sessions here too — do not add MCPs in this sub-repo.
- See `../CLAUDE.md` § anti-patterns for cross-stack discipline rules.

<!-- meta-repo:auto-end -->
```

Substitute carefully — `<sub-repo-name>`, `<role>`, `<port>`, `<remote>` change per iteration. The sibling list excludes the current sub-repo and lists the others with their detected roles.

## Step 5 — Report

Print a summary of what changed:

```
── CLAUDE.md refresh complete ──

Root CLAUDE.md:
  - <action: refreshed | prepended | created | skipped>

Sub-repo CLAUDE.mds:
  - <name1>/CLAUDE.md  →  <action>  (port <p>, role: <role>)
  - <name2>/CLAUDE.md  →  <action>  (port <p>, role: <role>)
  - ...

Warnings:
  - <list any sub-repos where ports were missing, remotes were n/a, or markers were corrupted>

User-written sections preserved below each meta-repo:auto-end marker.
```

Do not commit or push to any repo. Each sub-repo is its own git repo with its own PR workflow — the user decides what to commit and when.
