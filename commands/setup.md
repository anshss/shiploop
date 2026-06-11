---
model: opus
effort: medium
description: Scaffold OR upgrade a meta-repo workspace in the current folder. Fresh folder → full scaffold (npm root, worktrees, ticket queue, governor, hooks). Existing meta-repo → idempotent component-by-component bump: detect which capabilities are present vs missing/outdated and offer to add/upgrade each, refreshing mechanism scripts from latest templates without clobbering customization (which lives only in scripts/lib/workspace.sh).
---

You are the meta-repo setup command. You convert the current folder into — or upgrade an existing —
**meta-repo workspace**: an npm-rooted workspace that wraps N independent git sub-repos and provides
cross-cutting tooling, parallel worktrees, a ticket queue, a governor (autonomous ticket loop), and
the SessionStart/End/Stop hooks.

The full pattern is documented in `~/.claude/skills/meta-repo/SKILL.md` (read it if you need context).
All templates live under `~/.claude/skills/meta-repo/templates/`. Let `T=~/.claude/skills/meta-repo/templates`.

## Architecture you are installing (read once)
Every mechanism script sources the ONE config file `scripts/lib/workspace.sh`. That file holds all
per-workspace specifics (repo names, dev commands, ports, GitHub org, worktree base, governor
merge-allowlist). The mechanism scripts are therefore identical across every install — which is what
makes a bump safe: you refresh mechanism scripts from `T` and only ever (re)generate `workspace.sh`
for customization. **Never hand-edit a mechanism script during setup; put the value in workspace.sh.**

Workspace layout this command produces:
```
<root>/
  package.json            scripts/lib/workspace.sh        tickets.md
  .gitignore              scripts/lib/*.sh.example        tickets-parked.md
  .mcp.json (if any)      scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health}.sh
  .worktrees/.gitkeep     scripts/{check-main-on-main,ticket-sweep-reminder}.sh
  governor/*.md           scripts/worktree/*  + worktree/lib/registry.sh + session-end-cleanup.sh
  .claude/settings.json   scripts/govern/*    + govern/lib/common.sh
  learnings.md
```

---

## Phase 0 — Detect fresh vs existing

Print `── meta-repo setup ──`, then `pwd` and `ls -la`.

Determine the mode:
- If `scripts/lib/workspace.sh` exists → **BUMP MODE** (jump to "Phase B").
- Else if `package.json` exists and grep finds `"status": "bash scripts/status.sh"` (legacy marker) →
  this is an OLDER meta-repo (pre-workspace.sh). Treat as **BUMP MODE** but note in Phase B that the
  core scripts predate the config-file architecture and must be re-parameterized.
- Else → **FRESH MODE** (continue to Phase 1).

---

## Phase 0.5 — Branch guard (the tooling MUST live on the root's default branch)

**Load-bearing — do this before generating or bumping anything.** The workspace tooling
(`scripts/`, `governor/`, `package.json`, `.gitignore`, hooks) is versioned in the ROOT git repo.
Whatever branch you commit it on is where the harness lives — and the doctrine + the
`check-main-on-main` SessionStart hook both assume the root stays on its **default branch** (`main`).
If setup runs while the root is on a feature branch and the tooling gets committed there, the entire
governor strands off-main: `bash scripts/govern/run-loop.sh` is "file not found" from main, and the
hook nags forever about drift it can't fix. This has actually happened — guard against it.

```bash
def=$(git -C . symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
def="${def:-main}"; cur=$(git -C . rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "root default branch: $def   currently on: $cur"
```
- If `cur` == `def` → good, continue.
- If `cur` != `def` → **STOP and warn:** "The meta-repo tooling is versioned on the root's default
  branch (`$def`), but the root is on `$cur`. Committing the tooling here would strand the governor
  off `$def`. Switch the root to `$def` first? (switch / proceed-anyway / cancel)". On *switch*, run
  `git switch "$def"` (commit/stash any unrelated dirty work first) and re-confirm before generating.
  Only *proceed-anyway* if the operator explicitly accepts an off-default install.

---

## Phase 1 — Inventory sub-repos (fresh)

Find sub-folders that are their own git repos:
```bash
for d in */; do [ -d "$d/.git" ] && echo "${d%/}"; done
```
If zero, stop: "No sub-folders with their own .git found. Clone your sub-repos into this folder first,
then re-run `/meta-repo:setup`." Otherwise list them numbered and ask: "Detected N sub-repos: [list].
Use these? (yes / pick subset / cancel)".

## Phase 2 — Detect ports + dev commands (fresh)

For each confirmed sub-repo:
- **Port:** read `<repo>/package.json` `dev` script; grep for `-p (\d{4})` (Next.js) or `PORT=(\d+)`
  (Express). Record, or mark "unknown" and ask. **Resolve collisions:** if several default to 3000,
  assign distinct stable ports (3000, 3001, 3002, …) — record the assignment; the generated `dev.sh`
  binds each repo to its assigned port regardless of what the sub-repo pins.
- **Dev command (do NOT assume one PM):** lockfile signal — `package-lock.json`→`npm run dev`,
  `pnpm-lock.yaml`→`pnpm dev`, `yarn.lock`→`yarn dev`, `bun.lockb`→`bun run dev`; else `Makefile` w/
  a run target→`make run`, `Cargo.toml`→`cargo run`, `go.mod`→`go run ./...` (or ask). Flag any
  sub-repo with multiple JS lockfiles (mixed-PM bug) — ask which is real. Re-check `package.json`
  actually defines `dev` before assuming.

Print a table (repo / port / lockfile / dev command) and ask "Correct? (yes / fix)".

## Phase 3 — Detect org + worktree base (fresh)

- **GitHub org:** `git -C <first-repo> remote get-url origin` → parse `<org>/<repo>`. Confirm.
- **Worktree base:** default `$(dirname "$(pwd)")/<folder-name>.wt` (a sibling of the workspace).
  Confirm or let the user override.
- **Governor merge-allowlist:** ask which sub-repos may be **auto-merged** by the governor on
  green-or-no-checks CI (typically backends whose CI runs post-merge). The rest are PR-only. Default:
  none (safest) — the operator opts repos in.

## Phase 4 — Generate `scripts/lib/workspace.sh` (fresh)

Copy `$T/lib/workspace.sh` to `scripts/lib/workspace.sh`, then fill the placeholders. `REPOS`,
`REPO_CMDS`, and `REPO_PORTS` are **three index-aligned plain arrays** (NOT associative — macOS bash
3.2 has no `declare -A`), so each fill is a single space-separated list, in the SAME order, same
length:
- `__META_NAME__` → `basename "$(pwd)"`
- `__GITHUB_ORG__` → detected org
- `__REPOS__` → folder names, e.g. `backend console website`
- `__REPO_CMDS__` → quoted dev command per repo, same order: `"npm run dev" "pnpm dev" "npm run dev"`
- `__REPO_PORTS__` → base port per repo, same order; `""` for a repo with no HTTP port: `3080 3000 ""`
- `__WORKTREE_BASE__` → the worktree base path (keep the `$HOME` form if under home)
- `__GOVERN_MERGE_REPOS__` → space-separated allowlist (may be empty)
Leave `ROOT_PM="npm"`. After writing, verify with the user's env bash AND the system bash:
`bash -n scripts/lib/workspace.sh` and
`bash -c 'source scripts/lib/workspace.sh && echo "${REPOS[@]}" && echo "$(wsp_repo_port <some-repo> 1)"'`
to prove it parses and the helpers resolve (run it once with `/bin/bash` too, since the harness must
work on macOS's bash 3.2).

Also copy the example hooks for reference (user renames to enable):
`cp $T/lib/worktree-bootstrap.sh.example $T/lib/session-cleanup.sh.example $T/lib/doctor-extra.sh.example scripts/lib/`.

## Phase 5 — Copy mechanism scripts (fresh)

```bash
mkdir -p scripts/worktree/lib scripts/govern/lib governor .worktrees .claude
cp $T/{status,doctor,branch,switch,dev,pull-all,push-prs,health}.sh scripts/
cp $T/hooks/check-main-on-main.sh scripts/
cp $T/hooks/ticket-sweep-reminder.sh scripts/
cp $T/worktree/{new,rm,status,exec,main,session-end-cleanup}.sh scripts/worktree/
cp $T/worktree/lib/registry.sh scripts/worktree/lib/
cp $T/govern/*.sh scripts/govern/
cp $T/govern/lib/common.sh scripts/govern/lib/
cp $T/governor/*.md governor/
touch .worktrees/.gitkeep
chmod +x scripts/*.sh scripts/worktree/*.sh scripts/govern/*.sh
```
These are copied **verbatim** — they read everything from `workspace.sh`. Run `bash -n` over all of
them to confirm. (Do NOT edit them.) The `$T/govern/*.sh` glob includes the **escalation lifecycle**
pair `escalations-emit-pending.sh` (run-end: writes `governor/pending-escalations.json`) and
`escalations-apply-answers.sh` (run-start: un-park / migrate-to-parked / grow `preferences.md`),
which `run-loop.sh` and the `/govern` relay drive (#62) — they scaffold automatically, no extra step.

## Phase 6 — Root files (fresh)

### `package.json` (overwrite-protected — ask if it exists)
```json
{
  "name": "<folder-name>-meta-repo",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "bash scripts/dev.sh",
    "<one dev:<name> per sub-repo>": "bash scripts/dev.sh --only <name>",
    "status": "bash scripts/status.sh",
    "doctor": "bash scripts/doctor.sh",
    "branch": "bash scripts/branch.sh",
    "switch": "bash scripts/switch.sh",
    "pull": "bash scripts/pull-all.sh",
    "push": "bash scripts/push-prs.sh",
    "health": "bash scripts/health.sh",
    "worktree": "bash scripts/worktree/main.sh",
    "worktree:new": "bash scripts/worktree/new.sh",
    "worktree:rm": "bash scripts/worktree/rm.sh",
    "worktree:status": "bash scripts/worktree/status.sh",
    "worktree:exec": "bash scripts/worktree/exec.sh",
    "govern": "bash scripts/govern/run-loop.sh"
  }
}
```

### `.gitignore`
Copy `$T/gitignore` to `.gitignore` and replace `__SUBREPO_IGNORES__` with one `/<repo>/` line per
sub-repo. If a `.gitignore` exists, merge (don't clobber) — append any missing lines.

### Seeds
Copy `$T/seed/tickets.md`, `$T/seed/tickets-parked.md`, `$T/seed/learnings.md` to the root **only if
absent** (never overwrite an existing queue).

## Phase 7 — Wire `.claude/settings.json` hooks (fresh)

Write (or merge into) `.claude/settings.json`. Use ABSOLUTE paths to this workspace's scripts. If the
file exists, merge the `hooks` keys rather than overwriting:
```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "if [ -f <ROOT>/learnings.md ]; then echo '── workspace learnings ──'; head -30 <ROOT>/learnings.md; echo '...'; fi", "timeout": 5 },
      { "type": "command", "command": "bash <ROOT>/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "Stop": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash <ROOT>/scripts/ticket-sweep-reminder.sh", "timeout": 15 }
    ]}],
    "SessionEnd": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash <ROOT>/scripts/worktree/session-end-cleanup.sh 2>/dev/null || true", "timeout": 90 }
    ]}]
  }
}
```
Tell the user they can add a project drift check (e.g. a deploy-behind-main probe) as a third
SessionStart hook later.

## Phase 8 — Initialize (fresh)

Ask: "Run `npm install` + `npm run doctor` now? (yes / skip)". If yes: `npm install` (background),
then `npm run doctor`; show output. Don't auto-fix missing `.env` files (they hold secrets the user
provides). Mention the optional next steps:
- rename `scripts/lib/worktree-bootstrap.sh.example` → `.sh` and fill in per-worktree setup (deps,
  codegen, DB wiring) if you want `worktree:new` to produce a runnable stack;
- rename `session-cleanup.sh.example` / `doctor-extra.sh.example` similarly;
- customize `governor/preferences.md` (the doctrine) and set `GOVERN_MERGE_REPOS` in `workspace.sh`;
- before the first `/govern`, from a **plain terminal** (not nested in a Claude session) run
  `claude -p "ping" --model sonnet --strict-mcp-config` to confirm worker auth (prints text, not a 401).

**Commit the tooling to the default branch (don't leave it uncommitted/stranded).** Setup only writes
files; nothing is versioned until you commit. On the root's default branch (verified in Phase 0.5),
stage and commit the workspace tooling as ONE commit so the harness actually lives on `main`:
```bash
git add scripts governor package.json .gitignore .worktrees/.gitkeep \
        tickets.md tickets-parked.md learnings.md .claude/settings.json .mcp.json 2>/dev/null
git commit -m "chore: scaffold meta-repo workspace tooling (governor, worktrees, tickets, hooks)"
```
Do NOT `git add .` (that would sweep `.env`/secrets); stage the tooling paths explicitly. Leave the
push to the operator. If this commit lands anywhere but the default branch, the governor is stranded.

Then jump to "Phase Z — Report".

---

## Phase B — BUMP an existing meta-repo (component-by-component)

This is the idempotent upgrade path. Print "This folder is already a meta-repo workspace — checking
what's present vs the latest templates." Then **detect each component** and present a status table,
then offer to upgrade/add each. NEVER overwrite `workspace.sh` blindly, the ticket queue, `.env`
files, or `governor/preferences.md` (the user's doctrine) without asking.

### B0 — Re-detect repos (for re-parameterization)
Re-run the Phase 1–3 detection (sub-repos, ports, dev commands, org) so you can regenerate
`workspace.sh` if needed. Compare against the current `workspace.sh` (`source` it). If repos/ports
drifted, note it.

### B1 — Component inventory
Check presence/freshness of each component and build a table `component | status` where status is
`present (current)` / `present (outdated)` / `missing`:
- **config** — `scripts/lib/workspace.sh` present? Does it have all current placeholders/vars (e.g.
  `GOVERN_MERGE_REPOS`, `WORKTREE_BASE`, `wsp_repo_port`)? If it's an OLDER core-only meta-repo with
  inline `REPOS=` arrays in each script (no workspace.sh), mark config `missing` — this is the big
  upgrade: you'll introduce workspace.sh and re-point the scripts.
- **core scripts** — `scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health}.sh`. Outdated
  if they still inline `REPOS=` instead of sourcing workspace.sh, or if they use a non-npm root.
- **worktrees** — `scripts/worktree/` present?
- **tickets** — `tickets.md` present? `/meta-repo:resolve` command available (it's a skill command,
  always available once installed)?
- **governor** — `scripts/govern/` + `governor/` present?
- **hooks** — `scripts/check-main-on-main.sh`, `scripts/ticket-sweep-reminder.sh`,
  `scripts/worktree/session-end-cleanup.sh`, and the `.claude/settings.json` wiring.

To judge "outdated" cheaply, `diff` an installed mechanism script against `$T/<same path>` — if they
differ and the installed one doesn't source workspace.sh, it's outdated.

### B2 — Offer upgrades
Present the table and ask which components to add/upgrade (default: all missing + all outdated). For
each chosen component:
- **config (introduce/refresh workspace.sh):** if missing, generate `scripts/lib/workspace.sh` from
  `$T/lib/workspace.sh` filled with the B0-detected values + ask the user for `GOVERN_MERGE_REPOS`
  and the worktree base. If present-but-stale (missing newer vars), ADD the missing vars/helpers
  while PRESERVING the user's existing values — show a diff and confirm before writing.
- **core scripts / worktrees / governor / hooks:** copy the latest templates from `$T` into place
  (same paths as Phase 5), `chmod +x`. Because they only read workspace.sh, this is safe — but still
  `diff` first and show the user what changes. Preserve `governor/preferences.md`, `escalations.md`,
  and `improvements.md` if present (those are the operator's data, not mechanism) — only refresh the
  prompt templates (`worker-prompt.md`, `supervisor-prompt.md`, `README.md`) and the seed structure.
- **package.json scripts:** add any missing script aliases (worktree:*, govern, health, …) without
  removing the user's own. Convert a legacy pnpm root to npm ONLY if the user confirms (anti-pattern
  #7) — otherwise leave `ROOT_PM` matching their current root.
- **tickets:** if `tickets.md` is missing, seed it from `$T/seed/`. NEVER overwrite an existing queue.
- **hooks wiring:** merge any missing hook entries into `.claude/settings.json` (don't drop existing
  ones).
- **example project hooks:** copy any missing `scripts/lib/*.sh.example` for reference.

### B3 — Verify the bump
After applying, `bash -n` every `.sh` under `scripts/`, `source scripts/lib/workspace.sh` to confirm
it parses, and run `npm run doctor`. Report what changed.

**Then commit the refreshed tooling to the default branch.** A bump that stays uncommitted (or gets
committed on a feature branch) drifts the harness off `main` exactly like a fresh install can. On the
root's default branch (verified in Phase 0.5), stage the changed tooling paths explicitly (never
`git add .`) and commit, e.g. `git commit -m "chore: bump meta-repo workspace tooling"`. Leave the
push to the operator. Call out in the Phase Z report whether the tooling is committed and on which
branch — if it's not on the default branch, that's a drift the operator must resolve.

---

## Phase Z — Report

Print a final summary: mode (fresh/bump), sub-repos + ports, which components are now installed/
upgraded, and what still needs the user:
```
── meta-repo workspace ready ──
Mode:        <fresh | bumped>
Sub-repos:   <name (port)> …
Installed:   core scripts · worktrees · tickets · governor · hooks
Try:
  npm run status
  npm run worktree:new -- try-it && cd <worktree-base>/try-it
  /govern --dry-run         # prove the autonomous loop, ship nothing
Still needs you:
  - per-sub-repo .env files (see <repo>/.env.example)
  - enable optional hooks: rename scripts/lib/*.sh.example → .sh
  - set GOVERN_MERGE_REPOS in scripts/lib/workspace.sh + customize governor/preferences.md
  - commit the tooling to the default branch if not done (governor must live on main)
  - confirm worker auth (plain terminal): claude -p "ping" --model sonnet --strict-mcp-config
```
Stop. Do not proactively build further features unless asked.
