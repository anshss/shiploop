---
model: opus
effort: medium
description: Scaffold OR upgrade a meta-repo workspace in the current folder. Fresh folder → full scaffold via scaffold.sh (interview → invoke → verify). Existing meta-repo → component-by-component bump using scaffold.sh --component <name>. All mechanical file operations live in scaffold.sh; this command owns detection + judgment only.
---

You are the meta-repo setup command. You convert the current folder into — or upgrade an existing —
**meta-repo workspace**: a workspace (npm, pnpm, yarn, or bun at the root — your choice via `ROOT_PM`) that
wraps N independent git sub-repos and provides cross-cutting tooling, parallel worktrees, a ticket
queue, a governor (autonomous ticket loop), and the SessionStart/End/Stop hooks.

The full pattern is documented in the plugin's `SKILL.md` (read it if you need context). All mechanical
file operations are executed by `scaffold.sh` — you own the interview and the judgment; scaffold.sh
owns the byte-level file writes and is deterministic + idempotent.

## Locate the plugin (both install modes)

Templates and scaffold.sh live in the same directory. Resolve it in this priority order:
1. `${CLAUDE_PLUGIN_ROOT}` — set when this command runs as a plugin.
2. `~/.claude/skills/meta-repo-harness/` — legacy clone-into-skills install.
3. `~/.claude/plugins/**` cache lookup by plugin name — fallback.

Let `PLUGIN_ROOT` = that path and `SCAFFOLD=$PLUGIN_ROOT/scaffold.sh`.

## Architecture you are installing (read once)

Every mechanism script sources ONE config file: `scripts/lib/workspace.sh`. That file holds all
per-workspace specifics (repo names, dev commands, ports, GitHub org, worktree base, governor
merge-allowlist). Mechanism scripts are therefore identical across every install — which is what
makes a bump safe: scaffold.sh refreshes mechanism scripts from templates and only ever (re)generates
`workspace.sh` for customization. **Never hand-edit a mechanism script during setup; put the value in
`workspace.sh`.**

Workspace layout scaffold.sh produces:
```
<root>/
  package.json            scripts/lib/workspace.sh        queue/tickets.md
  .gitignore              scripts/lib/*.sh.example        queue/tickets-parked.md
  .worktrees/.gitkeep     scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health,sync,tail,investigate}.sh
  governor/*.md           scripts/{check-main-on-main,ticket-sweep-reminder,session-snapshot,router-posture-*}.sh
  .claude/settings.json   scripts/worktree/*  + worktree/lib/registry.sh
  .claude/commands/*.md   scripts/govern/*    + govern/lib/common.sh  + govern/test/*
  CLAUDE.md               learnings.md                    .githooks/{pre-push,prepare-commit-msg}
```

---

## Phase 0 — Detect fresh vs existing

Print `── meta-repo setup ──`, then `pwd` and `ls -la`.

Determine the mode:
- If `scripts/lib/workspace.sh` exists → **BUMP MODE** (jump to Phase B).
- Else if `package.json` exists and grep finds `"status": "bash scripts/status.sh"` (legacy marker) →
  OLDER meta-repo (pre-workspace.sh). Treat as **BUMP MODE** but note the core scripts predate the
  config-file architecture and must be re-parameterized (scaffold.sh handles that).
- Else → **FRESH MODE**.

## Phase 0.5 — Branch guard (root must be on its default branch)

The workspace tooling is versioned in the ROOT git repo. Whatever branch you commit it on is where
the harness lives — and the doctrine + the `check-main-on-main` SessionStart hook both assume the
root stays on its **default branch** (`main`). If setup runs while the root is on a feature branch
and the tooling gets committed there, the governor strands off-main.

```bash
def=$(git -C . symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
def="${def:-main}"; cur=$(git -C . rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "root default branch: $def   currently on: $cur"
```
- `cur == def` → good, continue.
- `cur != def` → STOP and warn. Offer to `git switch "$def"` (commit/stash any unrelated dirty work
  first) and re-confirm before generating.

---

## Phase 1 (fresh) — Interview

You are gathering the inputs scaffold.sh needs:

- **Sub-repos:** `for d in */; do [ -d "$d/.git" ] && echo "${d%/}"; done`. If zero, stop and tell the
  operator to clone their sub-repos first. Otherwise confirm the list.
- **Ports + dev commands per sub-repo:** read each `<repo>/package.json` `dev` script; grep for `-p (\d{4})`
  (Next.js) or `PORT=(\d+)` (Express). **Resolve collisions:** if several default to 3000, assign
  distinct stable ports (3000, 3001, …). **Dev command (do NOT assume one PM):** lockfile signal —
  `package-lock.json`→`npm run dev`, `pnpm-lock.yaml`→`pnpm dev`, `yarn.lock`→`yarn dev`,
  `bun.lockb`→`bun run dev`; else `Makefile` w/ a run target→`make run`, `Cargo.toml`→`cargo run`,
  `go.mod`→`go run ./...`. Print a table; ask to confirm.
- **Root package manager (`ROOT_PM`):** if a root lockfile exists, detect from it; else ask (default `npm`).
- **GitHub org:** `git -C <first-repo> remote get-url origin` → parse `<org>/<repo>`. Confirm.
- **Worktree base:** default `$(dirname "$(pwd)")/<folder-name>.wt`. Confirm or override.
- **Governor merge-allowlist:** ask which sub-repos may be **auto-merged** by the governor on
  green-or-no-checks CI. Default: **none** (safest) — the operator opts repos in.

## Phase 2 (fresh) — Invoke scaffold.sh

Build the `--repos` argument as `name:port:cmd,name:port:cmd,…`. Empty port allowed (write `name::cmd`).

```bash
bash "$SCAFFOLD" \
  --workspace-dir "$(pwd)" \
  --pm "$ROOT_PM" \
  --org "$GITHUB_ORG" \
  --repos "$REPOS_SPEC" \
  --merge-allowlist "$GOVERN_MERGE_REPOS" \
  --worktree-base "$WORKTREE_BASE" \
  --git-init \
  --verify \
  --yes
```

scaffold.sh handles: templates copy, placeholder fills, chmod +x, .gitignore synth, package.json
scripts block, .claude/settings.json wiring, seed files (queue/tickets.md, CLAUDE.md — only if
absent), .githooks activation (`core.hooksPath = .githooks`), and initial commit. `--verify` runs
`bash -n` over every installed script + sources workspace.sh.

## Phase 3 (fresh) — Propagate attribution + pre-commit hooks into sub-repos

The `.githooks/prepare-commit-msg` attribution hook and the optional `.githooks/pre-commit` lint-fix
hook need to be propagated into each sub-repo (only these two — the pre-push guard is harness-only):

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$META_ROOT/$repo/.git" ] || [ -f "$META_ROOT/$repo/.git" ] || continue
  install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$repo"
  install_subrepo_pre_commit_hook "$META_ROOT" "$META_ROOT/$repo"
done
```

The pre-commit hook is a no-op until the operator sets `WSP_LINT_FIX_CMD` in `workspace.sh` — see
the "Optional pre-commit lint-fix hook" block there. Sub-repos that already have a pre-commit hook
(husky, lefthook, hand-rolled) are left untouched by the pre-commit installer.

`worktree/new.sh` re-runs both installers for each sub-repo worktree it creates.

## Phase 4 (fresh) — Initialize + report

Ask: "Run `<ROOT_PM> install` + `<ROOT_PM> run doctor` now? (yes / skip)". Show output.

Mention optional next steps:
- rename `scripts/lib/worktree-bootstrap.sh.example` → `.sh` and fill per-worktree setup;
- rename `session-cleanup.sh.example` / `doctor-extra.sh.example` similarly;
- customize `governor/preferences.md` (the doctrine);
- before the first `/govern`, from a **plain terminal** (not nested in a Claude session) run
  `claude -p "ping" --model sonnet --strict-mcp-config` to confirm worker auth.

---

## Phase B — BUMP an existing meta-repo (component-by-component)

Print "This folder is already a meta-repo workspace — checking what's present vs the latest templates."

### B0 — Re-detect
Re-run Phase 1 detection (sub-repos, ports, dev commands, org). Source the existing
`scripts/lib/workspace.sh` and compare. Note any drift.

### B1 — Component inventory
Build a `component | status` table (`present (current)` / `present (outdated)` / `missing`):

| Component | Probe |
|---|---|
| config | `scripts/lib/workspace.sh` has all current vars (`GOVERN_MERGE_REPOS`, `WORKTREE_BASE`, `wsp_repo_port`) |
| core-scripts | `scripts/{status,doctor,branch,switch,dev,pull-all,push-prs,health,sync,tail,investigate}.sh` |
| worktrees | `scripts/worktree/{new,rm,status,exec,main,session-end-cleanup}.sh` + `lib/registry.sh` |
| tickets | `queue/tickets.md` present (old workspaces have `tickets.md` at ROOT — migrate) |
| commands | `.claude/commands/{govern,resolve,investigate}.md` present |
| govern | `scripts/govern/` + `governor/` present |
| hooks | `scripts/{check-main-on-main,ticket-sweep-reminder,session-snapshot,router-posture-*}.sh` + `.claude/settings.json` wiring |
| githooks | `.githooks/{pre-push,prepare-commit-msg}` + `git config core.hooksPath == .githooks` |
| investigate | `scripts/investigate.sh` + `.claude/commands/investigate.md` |

To judge "outdated" cheaply: `diff` the installed file against the bundled template.

### B2 — Offer upgrades

For each chosen component, dispatch to scaffold.sh:

```bash
# Refresh mechanism scripts (safe — they only read workspace.sh):
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component worktrees    --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component govern       --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component githooks     --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component commands     --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component seeds        --yes   # only fills absent seeds
```

Component notes:
- **config (workspace.sh):** scaffold.sh refuses to overwrite an existing workspace.sh unless `--yes`.
  For a stale workspace.sh with missing NEWER vars, DIFF first, then either manually edit or (if the
  operator confirms) `--component workspace-sh --yes`.
- **govern:** preserves `governor/preferences.md`, `escalations.md`, `improvements.md`,
  `decisions-log.md` if present (operator data). Refreshes prompt templates only.
- **package.json:** scaffold.sh refuses to overwrite an existing one. For missing script aliases,
  merge them by hand (or overwrite with `--yes` after saving custom scripts).
- **tickets migration:** if a legacy root-level `tickets.md` exists, `git mv tickets.md queue/`
  yourself (scaffold.sh only seeds `queue/tickets.md` when absent).
- **CLAUDE.md:** scaffold.sh never overwrites — if the file predates the current template, append
  the missing sections yourself.
- **.claude/settings.json:** if it exists, scaffold.sh leaves it alone — merge missing hook entries
  yourself.

### B3 — Verify + commit

After applying:

```bash
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes --verify
```

Then commit refreshed tooling to the default branch (verified in Phase 0.5), staging tooling paths
explicitly (never `git add .`):

```bash
git add scripts .githooks governor package.json .gitignore .claude/settings.json .claude/commands
git commit -m "chore: bump meta-repo workspace tooling"
```

---

## Phase Z — Report

Print:
```
── meta-repo workspace ready ──
Mode:        <fresh | bumped>
Sub-repos:   <name (port)> …
Installed:   core scripts · worktrees · tickets · governor · /govern + /resolve commands · hooks
Try:
  <ROOT_PM> run status
  <ROOT_PM> run worktree:new -- try-it && cd <worktree-base>/try-it
  /govern --dry-run
Still needs you:
  - per-sub-repo .env files (see <repo>/.env.example)
  - enable optional hooks: rename scripts/lib/*.sh.example → .sh
  - set GOVERN_MERGE_REPOS in scripts/lib/workspace.sh + customize governor/preferences.md
  - confirm worker auth (plain terminal): claude -p "ping" --model sonnet --strict-mcp-config
```
Stop. Do not proactively build further features unless asked.
