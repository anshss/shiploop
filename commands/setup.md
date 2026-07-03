---
model: opus
effort: medium
description: Scaffold OR upgrade a meta-repo workspace in the current folder. Fresh folder → full scaffold (root PM of your choice — npm/pnpm/yarn — plus worktrees, ticket queue, governor, hooks). Existing meta-repo → idempotent component-by-component bump: detect which capabilities are present vs missing/outdated and offer to add/upgrade each, refreshing mechanism scripts from latest templates without clobbering customization (which lives only in scripts/lib/workspace.sh).
---

You are the meta-repo setup command. You convert the current folder into — or upgrade an existing —
**meta-repo workspace**: a workspace (npm, pnpm, or yarn at the root — your choice via `ROOT_PM`) that wraps N independent git sub-repos and provides
cross-cutting tooling, parallel worktrees, a ticket queue, a governor (autonomous ticket loop), and
the SessionStart/End/Stop hooks.

The full pattern is documented in `~/.claude/skills/meta-repo-harness/SKILL.md` (read it if you need context).
All templates live under `~/.claude/skills/meta-repo-harness/templates/`. Let `T=~/.claude/skills/meta-repo-harness/templates`.

## Architecture you are installing (read once)
Every mechanism script sources the ONE config file `scripts/lib/workspace.sh`. That file holds all
per-workspace specifics (repo names, dev commands, ports, GitHub org, worktree base, governor
merge-allowlist). The mechanism scripts are therefore identical across every install — which is what
makes a bump safe: you refresh mechanism scripts from `T` and only ever (re)generate `workspace.sh`
for customization. **Never hand-edit a mechanism script during setup; put the value in workspace.sh.**

Workspace layout this command produces:
```
<root>/
  package.json            scripts/lib/workspace.sh        queue/tickets.md
  .gitignore              scripts/lib/*.sh.example        queue/tickets-parked.md
  .mcp.json (if any)      scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health}.sh
  .worktrees/.gitkeep     scripts/{check-main-on-main,ticket-sweep-reminder}.sh
  governor/*.md           scripts/worktree/*  + worktree/lib/registry.sh + session-end-cleanup.sh
  .claude/settings.json   scripts/govern/*    + govern/lib/common.sh
  CLAUDE.md               learnings.md
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
then re-run `/meta-repo-harness:setup`." Otherwise list them numbered and ask: "Detected N sub-repos: [list].
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

## Phase 3 — Detect org + worktree base + root PM (fresh)

- **Root package manager (`ROOT_PM`):** the root scripts are PM-agnostic bash aliases, so this only
  sets which CLI the operator types (`npm run <x>` / `pnpm <x>` / `yarn <x>` / `bun run <x>`) and what
  `doctor` checks for. If a root lockfile already exists, detect from it (`package-lock.json`→`npm`,
  `pnpm-lock.yaml`→`pnpm`, `yarn.lock`→`yarn`, `bun.lockb`→`bun`); otherwise ask, default `npm`. This
  value fills `ROOT_PM` in Phase 4 and drives the off-PM lockfile ignores in Phase 6.
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
Set `ROOT_PM` to the package manager chosen/detected in Phase 3 (`npm` | `pnpm` | `yarn` | `bun`;
default `npm`). After writing, verify with the user's env bash AND the system bash:
`bash -n scripts/lib/workspace.sh` and
`bash -c 'source scripts/lib/workspace.sh && echo "${REPOS[@]}" && echo "$(wsp_repo_port <some-repo> 1)"'`
to prove it parses and the helpers resolve (run it once with `/bin/bash` too, since the harness must
work on macOS's bash 3.2).

Also copy the example hooks for reference (user renames to enable):
`cp $T/lib/worktree-bootstrap.sh.example $T/lib/session-cleanup.sh.example $T/lib/doctor-extra.sh.example scripts/lib/`.

## Phase 5 — Copy mechanism scripts (fresh)

```bash
mkdir -p scripts/worktree/lib scripts/govern/lib scripts/govern/test governor .worktrees .claude/commands .githooks
cp $T/{status,doctor,branch,switch,dev,pull-all,push-prs,health,sync,tail,investigate}.sh scripts/
cp $T/hooks/check-main-on-main.sh scripts/
cp $T/hooks/ticket-sweep-reminder.sh scripts/
cp $T/hooks/session-snapshot.sh scripts/
cp $T/hooks/router-posture-reminder.sh scripts/
cp $T/hooks/router-posture-guard.sh scripts/
cp $T/lib/session-state.sh scripts/lib/
cp $T/lib/preflight.sh scripts/lib/
cp $T/lib/githooks.sh scripts/lib/
cp $T/githooks/{pre-push,prepare-commit-msg} .githooks/
cp $T/worktree/{new,rm,status,exec,main,session-end-cleanup}.sh scripts/worktree/
cp $T/worktree/lib/registry.sh scripts/worktree/lib/
cp $T/govern/*.sh scripts/govern/
cp $T/govern/lib/common.sh scripts/govern/lib/
cp $T/govern/test/*.sh scripts/govern/test/
cp $T/governor/*.md governor/
cp $T/.claude/commands/*.md .claude/commands/
touch .worktrees/.gitkeep
chmod +x scripts/*.sh scripts/worktree/*.sh scripts/govern/*.sh scripts/govern/test/*.sh .githooks/*
```
These are copied **verbatim** — they read everything from `workspace.sh`. Run `bash -n` over all of
them to confirm. (Do NOT edit them.) New in this set: `sync.sh` (session-hygiene multi-repo sync) and
`tail.sh` (interleaved dev-log tail) are top-level scripts; `hooks/session-snapshot.sh` is the
SessionStart baseline hook (installs to `scripts/`) that pairs with the `ticket-sweep-reminder.sh` Stop
hook; `lib/session-state.sh` (the code-work fingerprint the baseline + Stop hook share) and
`lib/preflight.sh` (the node_modules-vs-package.json drift probe `doctor.sh` calls) are sourced libs in
`scripts/lib/` — they need no `+x`. The `$T/govern/*.sh` glob includes the **escalation lifecycle**
pair `escalations-emit-pending.sh` (run-end: writes `governor/pending-escalations.json`) and
`escalations-apply-answers.sh` (run-start: un-park / migrate-to-parked / grow `preferences.md`),
which `run-loop.sh` and the `/govern` relay drive (#62) — they scaffold automatically, no extra step.
The `$T/govern/test/*.sh` copy ships the governor's smoke tests (`assert.sh`; `test-no-force-push.sh`,
the ff-only/no-force-push invariant guard; and `test-improvements-commit.sh`, the #111 regression that
the self-improvement step commits its own `governor/improvements.md` so it never lingers uncommitted)
so a fresh workspace can `bash scripts/govern/test/<name>.sh` to prove the governor never force-pushes
the shared `main` and never self-blocks on an uncommitted runtime artifact. They read only the
scaffolded scripts — no extra wiring.

The `$T/.claude/commands/*.md` copy installs the **project-local** `/govern` and `/resolve` slash
commands into the workspace's own `.claude/commands/`. This is what makes the autonomous loop usable
in the scaffolded repo **without depending on the meta-repo skill being globally installed** on that
machine: a fresh workspace gets a working `/govern` (and `/resolve`) on its own. (Where the meta-repo
skill IS installed globally, the namespaced `meta-repo-harness:govern` / `meta-repo-harness:resolve` also exist —
harmless duplication; the project commands are the self-contained ones the Phase Z message points to.)
Without this step the headline `/govern` in the final "Try" block would be a dead command. The
`npm run govern` alias (Phase 6 `package.json`) is the equivalent CLI entry point either way.

Also new in this set:
- **Router-posture hooks** — `scripts/router-posture-reminder.sh` (a UserPromptSubmit hook that primes
  "the driver delegates heavy work to child Agents/Workflows, keep context thin" once per session) and
  `scripts/router-posture-guard.sh` (a PreToolUse `Read|Bash` hook that nudges, rate-limited, when the
  driver itself does a >1000-line Read or a verbose build). Wired in Phase 7.
- **`scripts/investigate.sh`** + the project-local `/investigate` command — a thin generic bug-triage
  loop (seed a notes file under `logs/investigations/` → collect evidence → hypothesis → fix). Its
  evidence-collection guts are workspace-specific: it calls an optional `scripts/logs.sh` if present,
  else leaves `# workspace-specific` placeholders for the operator to wire in their own log/DB probes.
- **Git-hooks enforcement** — `.githooks/pre-push` + `.githooks/prepare-commit-msg` and the
  `scripts/lib/githooks.sh` propagation helper. Wired below.

### Git-hooks enforcement (fresh)

The two `.githooks/` files enforce the harness's git conventions mechanically instead of by prose:
- **`pre-push`** rejects pushing any non-`main` feature branch to the HARNESS repo unless the push is a
  sanctioned governor run (`GOVERN_RUN=1`) whose branch is exactly `ticket-<N>` — this makes
  anti-pattern #9 ("meta-repo files commit directly to `main`; only the governor opens harness PRs")
  physically enforced. Pushes to `main` always pass.
- **`prepare-commit-msg`** auto-appends the `Co-Authored-By` attribution trailer on AGENT commits
  (`CLAUDECODE=1` / `GOVERN_RUN=1`), idempotently, so attribution can't be forgotten on a raw
  `git commit`.

Activate them in the harness root and propagate ONLY the attribution hook into each cloned sub-repo
(the `pre-push` guard is harness-only — sub-repos legitimately receive feature-branch PRs):
```bash
git config core.hooksPath .githooks   # in the harness root — activates .githooks/pre-push + prepare-commit-msg
# propagate JUST the attribution hook into each sub-repo (honors husky's core.hooksPath):
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$META_ROOT/$repo/.git" ] || [ -f "$META_ROOT/$repo/.git" ] || continue
  install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$repo"
done
```
`worktree/new.sh` re-runs `install_subrepo_attribution_hook` for each sub-repo worktree it creates, so
worktrees inherit attribution too. The Phase-8 `doctor` run asserts `core.hooksPath == .githooks`.

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
    "sync": "bash scripts/sync.sh",
    "tail": "bash scripts/tail.sh",
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
Copy `$T/gitignore` to `.gitignore`, then:
- Replace `__SUBREPO_IGNORES__` with one `/<repo>/` line per sub-repo.
- Replace `__ROOT_LOCKFILE_IGNORES__` with the root lockfiles to ignore, keyed to `ROOT_PM` — list the
  **other** PMs' root lockfiles so a stray install can't commit a divergent one. A pnpm root also
  ignores its OWN (pnpm v11 rewrites it every run). Each line is root-anchored (`/`):
  - `npm` → `/pnpm-lock.yaml` `/yarn.lock` `/bun.lockb`
  - `pnpm` → `/pnpm-lock.yaml` `/package-lock.json` `/yarn.lock` `/bun.lockb` (all four)
  - `yarn` → `/package-lock.json` `/pnpm-lock.yaml` `/bun.lockb`
  - `bun` → `/package-lock.json` `/pnpm-lock.yaml` `/yarn.lock`

If a `.gitignore` exists, merge (don't clobber) — append any missing lines.

### Seeds
Create the `queue/` folder and copy `$T/seed/tickets.md` → `queue/tickets.md` and
`$T/seed/tickets-parked.md` → `queue/tickets-parked.md` (the live + parked queues live together in
`queue/`). Copy `$T/seed/learnings.md` and `$T/seed/CLAUDE.md` to the root. All **only if absent**
(never overwrite an existing queue or CLAUDE.md).
The seed `CLAUDE.md` is the workspace's **always-on context** — it carries the operate-first guidance,
the stability-routing table (tickets / CLAUDE.md / learnings / project memory), the root-vs-sub-repo
`CLAUDE.md` hierarchy, and the anti-patterns, with `<…>` placeholders for the sub-repo map. After
copying, fill the `<workspace>` / `<org>` / sub-repo table placeholders from the Phase 1–3 detection.
If `ROOT_PM` is not `npm`, also replace the literal `npm run` in its command examples with the chosen
PM form (`pnpm run` / `yarn run` / `bun run`). Mention the operator should also create a per-sub-repo `CLAUDE.md` (and optional `learnings.md`) as
each sub-repo accrues its own patterns — "sub-repo CLAUDE.md wins in its scope".

## Phase 7 — Wire `.claude/settings.json` hooks (fresh)

Write (or merge into) `.claude/settings.json`. Use ABSOLUTE paths to this workspace's scripts. If the
file exists, merge the `hooks` keys rather than overwriting:
```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash <ROOT>/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 },
      { "type": "command", "command": "if [ -f <ROOT>/learnings.md ]; then echo '── workspace learnings ──'; head -30 <ROOT>/learnings.md; echo '...'; fi", "timeout": 5 },
      { "type": "command", "command": "bash <ROOT>/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "UserPromptSubmit": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash <ROOT>/scripts/router-posture-reminder.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "PreToolUse": [{ "matcher": "Read|Bash", "hooks": [
      { "type": "command", "command": "bash <ROOT>/scripts/router-posture-guard.sh 2>/dev/null || true", "timeout": 10 }
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
The `UserPromptSubmit` (router-posture-reminder) + `PreToolUse` matching `Read|Bash`
(router-posture-guard) entries prime and enforce the delegate-heavy-work posture; both never block
(exit 0, advisory only) and are rate-limited so they add near-zero per-turn cost.
`session-snapshot.sh` MUST be the first SessionStart hook — it writes the per-session code-work
baseline that the `ticket-sweep-reminder.sh` Stop hook reads to fire its reminder only when work
happened THIS session (without the baseline the Stop hook falls back to a cruder always-fires check).
Tell the user they can add a project drift check (e.g. a deploy-behind-main probe) as a later
SessionStart hook.

## Phase 8 — Initialize (fresh)

Ask: "Run `<ROOT_PM> install` + `<ROOT_PM> run doctor` now? (yes / skip)" (substitute the chosen PM —
`npm install`, `pnpm install`, `yarn`, or `bun install`). If yes: run the install (background), then
`<ROOT_PM> run doctor`; show output. Don't auto-fix missing `.env` files (they hold secrets the user
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
git add scripts .githooks governor package.json .gitignore .worktrees/.gitkeep \
        queue learnings.md CLAUDE.md \
        .claude/settings.json .claude/commands .mcp.json 2>/dev/null
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
- **core scripts** — `scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health,sync,tail}.sh`.
  Outdated if they still inline `REPOS=` instead of sourcing workspace.sh, or if they hard-code a
  package manager instead of using `$ROOT_PM` (a non-npm root is valid — the scripts must honor
  `ROOT_PM`). `sync.sh` (multi-repo session-hygiene sync) and `tail.sh` (interleaved dev-log tail) are
  newer additions — mark `missing` if absent.
- **worktrees** — `scripts/worktree/` present?
- **tickets** — `queue/tickets.md` present? An older workspace keeps `tickets.md` + `tickets-parked.md`
  at the ROOT (pre-`queue/` layout) — mark `outdated` so the bump migrates them into `queue/` (below).
- **commands** — project-local `.claude/commands/govern.md` + `.claude/commands/resolve.md` present?
  An older workspace that predates this step has NEITHER — it relied on the global `meta-repo-harness:govern`
  skill, so a bare `/govern` / `/resolve` never worked there (and the Phase Z "Try" message advertised
  a dead command). Mark `missing` so the bump installs them.
- **governor** — `scripts/govern/` + `governor/` present?
- **hooks** — `scripts/check-main-on-main.sh`, `scripts/ticket-sweep-reminder.sh`,
  `scripts/session-snapshot.sh` (the SessionStart code-work baseline hook — newer; an older workspace
  lacks it, so its Stop reminder falls back to the cruder always-fires check) plus its
  `scripts/lib/session-state.sh` lib, `scripts/lib/preflight.sh` (the deps-drift probe doctor.sh
  calls), `scripts/worktree/session-end-cleanup.sh`, and the `.claude/settings.json` wiring (the
  SessionStart `session-snapshot.sh` entry is newer — mark `missing` if absent). Also NEWER:
  `scripts/router-posture-reminder.sh` (UserPromptSubmit) + `scripts/router-posture-guard.sh`
  (PreToolUse `Read|Bash`) — mark `missing` if either the script OR its settings.json entry is absent.
- **git-hooks enforcement** — `.githooks/pre-push` + `.githooks/prepare-commit-msg`,
  `scripts/lib/githooks.sh`, and the repo's `core.hooksPath == .githooks` config. Mark `missing` if the
  `.githooks/` files are absent OR `git config core.hooksPath` is unset.
- **investigate** — `scripts/investigate.sh` + `.claude/commands/investigate.md`. Mark `missing` if absent.

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
  `diff` first and show the user what changes. This set now also installs `sync.sh`/`tail.sh`,
  `hooks/session-snapshot.sh`, and the `lib/session-state.sh` + `lib/preflight.sh` libs (libs need no
  `+x`) — copy any that are missing on an older workspace. Preserve `governor/preferences.md`, `escalations.md`,
  and `improvements.md` if present (those are the operator's data, not mechanism) — only refresh the
  prompt templates (`worker-prompt.md`, `supervisor-prompt.md`, `README.md`) and the seed structure.
- **commands (project-local `/govern` + `/resolve`):** `mkdir -p .claude/commands` and copy
  `$T/.claude/commands/*.md` into it (`diff` first if present). These are the self-contained slash
  commands a scaffolded workspace needs so `/govern` / `/resolve` work without the meta-repo skill
  being globally installed — the most common missing component on a workspace scaffolded before this
  step existed. Safe to refresh: they carry no workspace-specific values (they read `scripts/govern/*`
  and `workspace.sh` at runtime).
- **package.json scripts:** add any missing script aliases (worktree:*, govern, health, sync, tail, …)
  without removing the user's own. Keep `ROOT_PM` matching the operator's existing root lockfile — npm,
  pnpm, and yarn roots are all valid (the scripts are PM-agnostic bash aliases). Only change the root PM
  if the operator explicitly asks. If the existing root has a stray off-PM lockfile (e.g. a
  `package-lock.json` in a pnpm root), flag it and offer to remove it + add it to the `.gitignore`
  off-PM ignores (anti-pattern #7) rather than switching PMs.
- **tickets:** the live + parked queues live in `queue/`. Three cases:
  - Neither `queue/tickets.md` nor a root `tickets.md` → seed `queue/tickets.md` + `queue/tickets-parked.md`
    from `$T/seed/` (create `queue/` first). NEVER overwrite an existing queue.
  - Root-level `tickets.md` / `tickets-parked.md` present (pre-`queue/` layout) → **migrate**: `mkdir -p queue`
    then `git mv tickets.md queue/tickets.md` and `git mv tickets-parked.md queue/tickets-parked.md` (preserve
    history; create `queue/tickets-parked.md` from the seed if the root one is absent). Confirm first. The
    refreshed mechanism scripts already read `queue/` (the `QUEUE_DIR` default in `common.sh`), so the move
    is all that's needed. If the root also has a `governor/externalized.md` (externalization-lane installs),
    `git mv` it to `queue/externalized.md` too.
  - `queue/tickets.md` already present → up to date; leave it.
- **root CLAUDE.md:** if `CLAUDE.md` is missing, offer to seed it from `$T/seed/CLAUDE.md` (then fill
  the placeholders). If it's present, NEVER overwrite it — instead check whether it documents the
  stability-routing table (tickets / CLAUDE.md / learnings / project memory) and the root-vs-sub-repo
  hierarchy; if not, offer to append just those convention sections (show a diff, confirm first).
- **hooks wiring:** merge any missing hook entries into `.claude/settings.json` (don't drop existing
  ones) — in particular add the SessionStart `session-snapshot.sh` entry FIRST (before the
  learnings-skim + check-main-on-main entries) if it's absent, so the Stop reminder gets its baseline.
  Also add the `UserPromptSubmit` (router-posture-reminder) and `PreToolUse` matching `Read|Bash`
  (router-posture-guard) entries if absent (copy their scripts to `scripts/` too).
- **git-hooks enforcement:** copy `$T/githooks/{pre-push,prepare-commit-msg}` → `.githooks/` (chmod +x)
  and `$T/lib/githooks.sh` → `scripts/lib/`, then run `git config core.hooksPath .githooks` in the
  harness root (idempotent) and `install_subrepo_attribution_hook` for each sub-repo (see the fresh
  Git-hooks step). Preserve any existing hooks the user added under `.githooks/`; only refresh the two
  harness files. If `core.hooksPath` is already a non-`.githooks` value the user set intentionally,
  ask before changing it.
- **investigate:** copy `$T/investigate.sh` → `scripts/` (chmod +x) and `$T/.claude/commands/investigate.md`
  → `.claude/commands/` (`diff` first if present; it carries no workspace-specific values).
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
Installed:   core scripts · worktrees · tickets · governor · /govern + /resolve commands · hooks
Try:
  npm run status
  npm run worktree:new -- try-it && cd <worktree-base>/try-it
  /govern --dry-run         # prove the autonomous loop, ship nothing (or: npm run govern -- --dry-run)
Still needs you:
  - per-sub-repo .env files (see <repo>/.env.example)
  - enable optional hooks: rename scripts/lib/*.sh.example → .sh
  - set GOVERN_MERGE_REPOS in scripts/lib/workspace.sh + customize governor/preferences.md
  - commit the tooling to the default branch if not done (governor must live on main)
  - confirm worker auth (plain terminal): claude -p "ping" --model sonnet --strict-mcp-config
```
Stop. Do not proactively build further features unless asked.
