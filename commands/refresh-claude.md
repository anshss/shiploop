---
model: sonnet
effort: low
description: Regenerate the auto-managed section of CLAUDE.md from current repo state. Preserves all user-written content below the `meta-repo:auto-end` marker. Run this after adding/removing sub-repos, changing ports, or updating the operating commands. Idempotent — safe to run anytime.
---

You are the meta-repo CLAUDE.md refresher. Your job is to rewrite only the content between `<!-- meta-repo:auto-start -->` and `<!-- meta-repo:auto-end -->` in the workspace root's CLAUDE.md. Everything outside those markers — including any project-specific context the user has written — must be preserved exactly.

---

## Step 1 — Locate CLAUDE.md

Working dir = `pwd`. Check that `CLAUDE.md` exists at the workspace root.

- If missing: ask the user "No CLAUDE.md found here. Create one fresh? (yes / no)" If yes, write the full template from `/meta-repo:setup` Phase 4.5 and stop. If no, exit.
- If present: continue.

## Step 2 — Verify this is a meta-repo workspace

Check for the marker files:
- `package.json` exists and contains `"status": "bash scripts/status.sh"` (the canonical meta-repo signature)
- `pnpm-workspace.yaml` exists

If either is missing, tell the user: "This folder doesn't look like a meta-repo workspace (no pnpm-workspace.yaml or no `status` script in package.json). Run `/meta-repo:setup` first, or cd into a meta-repo workspace." Exit.

## Step 3 — Detect current state

Collect:

1. **Sub-repos** — list all top-level folders containing a `.git/` directory:
   ```bash
   for d in */; do [ -d "$d/.git" ] && echo "${d%/}"; done
   ```

2. **Per sub-repo: port and remote.**
   - Port: read `<sub>/package.json` → look at the `dev` script for `-p (\d{4})` or `PORT=(\d+)`. If absent, mark `?`.
   - Remote: `git -C <sub> remote get-url origin 2>/dev/null` → output or `n/a`.

3. **Available pnpm scripts** — read root `package.json` and list `scripts.*` keys.

4. **Workspace name** — `basename "$(pwd)"`.

## Step 4 — Build the new auto section

Construct exactly this markdown block (substituting the detected values):

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

(Use the descriptions from the meta-repo skill SKILL.md for canonical commands; for any custom user-added scripts, write a brief inferred purpose or `(custom)`.)

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
```

## Step 5 — Write back

Read the current `CLAUDE.md` content into memory. Find the substring between `<!-- meta-repo:auto-start -->` and `<!-- meta-repo:auto-end -->` (inclusive). Replace it with the newly constructed block from Step 4.

**Edge cases:**
- If the markers are not present in the current CLAUDE.md, ask the user: "No meta-repo markers found in CLAUDE.md. Prepend the auto section to the top of the file? (yes / no)" If yes, prepend. If no, exit without changes.
- If only one marker is present (corrupted state), warn the user and exit without changes. Tell them to manually fix the markers, then re-run.

Write the result back to `CLAUDE.md`.

## Step 6 — Report

Print a diff-summary:

```
── CLAUDE.md refreshed ──
Sub-repos:       <count> (<list>)
Ports:           <list>
Commands:       <count> wired in package.json
Anti-patterns:   6 (canonical)

User-written section preserved below the meta-repo:auto-end marker.
```

Do not commit or push. The user decides when.
