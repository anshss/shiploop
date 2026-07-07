---
model: opus
effort: medium
description: Scaffold OR upgrade a shiploop workspace in the current folder — wraps N sub-repos into one workspace and installs the self-improving multi-agent harness (worktrees + ticket queue + governor + hooks; every resolved ticket writes a lesson into your git-tracked CLAUDE.md) that ships your backlog. Fresh folder → full scaffold via scaffold.sh (interview → invoke → verify). Existing workspace → component-by-component bump using scaffold.sh --component <name>. All mechanical file operations live in scaffold.sh; this command owns detection + judgment only. For ongoing maintenance (routine hub-to-workspace bumps), use /shiploop:update; for pushing local mechanism improvements back to the hub, use /shiploop:push.
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
2. `~/.claude/skills/shiploop/` — legacy clone-into-skills install.
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

## Phase 0 — Detect the mode (fresh / upgrade / wrap-in-place / refuse)

Print `── meta-repo setup ──`, then `pwd` and `ls -la`.

Let `WRAP="$PLUGIN_ROOT/templates/lib/wrap.sh"`. Ask it what this folder is — it is the single
tested source of truth for the entry decision (the six-row table below):

```bash
MODE="$(bash "$WRAP" --detect --workspace-dir "$(pwd)")"
echo "mode: $MODE"
```

| `$MODE` | Context | Do |
|---|---|---|
| `upgrade` | already a shiploop workspace (`scripts/lib/workspace.sh` present) | **BUMP MODE** — jump to Phase B |
| `fresh` | not inside any git repo (empty parent / sub-repos as children) | **FRESH MODE** — Phase 1 |
| `wrap` | you are AT the root of a git repo whose `.git` is a directory | **WRAP OFFER** — Phase W |
| `refuse:gitfile` | `.git` is a FILE (linked worktree / submodule checkout) | **STOP** — wrapping it corrupts the main repo's back-pointers. Tell the operator; out of scope for v1 |
| `refuse:below-root` | inside a git repo but below its root | **STOP** — "cd to the repo root and re-run" (print the root path) |
| `refuse:bare` | bare repository | **STOP** — nothing to wrap |

Back-compat note: an OLDER meta-repo that predates `scripts/lib/workspace.sh` but has a
`package.json` whose scripts include `"status": "bash scripts/status.sh"` is still an **upgrade** —
`--detect` returns `fresh` for it (no `.git` at root typical), so if you see that legacy marker,
treat it as **BUMP MODE** and note the core scripts must be re-parameterized (scaffold.sh handles it).

## Phase W — Wrap-in-place offer (only when `$MODE == wrap`)

You are standing inside the operator's existing project repo. Offer to **wrap it in place** — the
quickstart path — and explain it in ONE paragraph before touching anything:

> Wrap-in-place moves this repo's contents into a subfolder (`<name>/`) of this same path and
> scaffolds the shiploop workspace root where the repo used to be. The path you `cd` into stays the
> same (shell history, IDE recents, and Claude Code's session identity all survive); your repo, its
> full history, and every untracked file move as a unit — verified byte-identical afterwards. A
> `.wrap-undo.sh` is written first and only removed once the whole thing verifies; if anything fails
> it rolls back automatically. It is one guarded script (`wrap.sh`) — never a sequence of moves I
> drive by hand.

Also offer the **fresh-folder alternative** for anyone who prefers it or wants a multi-repo workspace
from the start: "or make an empty parent folder, move this repo into it, and run setup there" (that is
the classic `mkdir myproduct && cd myproduct && mv ~/code/this-repo . && /shiploop:setup` flow → Phase 1).

If the operator declines both, stop. If they pick wrap-in-place, continue in this phase:

### W1 — Interview (what wrap.sh needs)

Gather, confirming each:
- **Subfolder name** (`NAME`): default = repo name from `git remote get-url origin` (`<org>/<repo>` →
  `<repo>`), else the current folder name. This is where the repo will live (`<path>/<NAME>/`).
- **Port + dev command** for the wrapped repo: same detection as Phase 1 (read its `package.json`
  `dev` script / lockfile / `Makefile` / `Cargo.toml` / `go.mod`).
- **GitHub org** (`ORG`): parse from the wrapped repo's `origin`. Confirm.
- **Root package manager** (`ROOT_PM`), **worktree base**, **governor merge-allowlist**: as Phase 1.
- Then the shared **Interview additions** (autonomy rung, more repos, auto-externalization) below.

Build `REPOS_SPEC` with the wrapped repo pre-registered FIRST: `"$NAME:$PORT:$CMD"` (plus any extra
repos the operator named — those are cloned AFTER the wrap, W4).

### W2 — Invoke wrap.sh (single guarded call)

```bash
bash "$WRAP" \
  --workspace-dir "$(pwd)" \
  --name "$NAME" \
  --pm "$ROOT_PM" --org "$ORG" \
  --repos "$REPOS_SPEC" \
  --merge-allowlist "$GOVERN_MERGE_REPOS" \
  --worktree-base "$WORKTREE_BASE" \
  --yes
# exit 0 = wrapped + scaffolded; 3 = hard refusal; 4 = name collision; 5 = needs-confirm; 1 = rolled back
```

Handle the exit code — **do NOT try to move anything yourself; wrap.sh owns every filesystem step**:
- **0** → wrapped + scaffolded. Continue to W3.
- **3** (hard refusal) → print wrap.sh's `REFUSE:` message verbatim and STOP. These are fail-closed
  (dirty tree, in-progress op, `.git`-as-file, linked worktree, absolute `core.worktree`/`hooksPath`,
  `includeIf` gitdir abs, pre-existing `.wrap-undo.sh`, below-root, bare). Do not override.
- **4** (name collision) → the chosen `NAME` clashes (case-insensitively on macOS/APFS) with an
  existing entry. Ask for a different subfolder name and re-invoke.
- **5** (needs-confirm) → wrap.sh printed one or more `NEEDS-CONFIRM[--confirm-x]: <why>` lines
  (escaping symlink, cloud-synced folder, nested-in-another-repo, live dev servers, `git maintenance`
  registration). Relay each `<why>` to the operator, get an explicit yes for each, then re-invoke
  ADDING the exact `--confirm-*` flags they approved. If they decline any, STOP.
- **1** (rolled back) → a step failed mid-flight; wrap.sh already restored the original layout and
  kept `.wrap-undo.sh`. Print the failure reason and STOP — do not retry blindly.

### W3 — Root remote

The scaffold left the root as a fresh local git repo with no remote. Offer:
- **`gh repo create`** (private by default): `gh repo create <org>/<meta-name> --private --source=. --remote=origin` (confirm the name).
- **skip for now** — fine, but tell the operator plainly: **without a root remote the governor's CAS
  ticket pushes and cross-driver ticket sync are DISABLED**; `doctor` and `config-check` will keep
  surfacing it as a first-class status line until they add one.

### W4 — Extra repos, hooks, verify

- If the operator named additional repos in the interview, clone each into the root now (`git clone`)
  and re-run `bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component workspace-sh --yes` is NOT needed —
  instead add them to `REPOS` before W2, or clone + re-scaffold config. Simplest: clone them, then
  re-run the config component so `workspace.sh` lists them.
- Propagate sub-repo commit hooks (Phase 3 block) for the wrapped repo and any extras.
- Verify: `bash scripts/govern/config-check.sh` (no-auth smoke) then continue to Phase Z's report.

The wrapped repo is already gitignored at the root (`/<NAME>/`) and was NOT swept into the root
commit — wrap.sh asserts both before removing the undo script, so you do not need to re-check.

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
  operator to put at least one repo here first (as a sub-folder with its own `.git`). **One sub-repo is
  enough** — a single-repo workspace is fully valid; the ticket queue, governor, worktrees, and
  lesson-accretion all pay off at N=1, and the operator adds more sub-repos later. Don't nudge toward a
  multi-repo split or assume microservices. Confirm the detected list.
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

Then also run the shared **Interview additions** below.

## Interview additions (BOTH modes — fresh and wrap)

Ask these in both Phase 1 and Phase W (in wrap mode, ask them AFTER the wrap so the first repo is
already registered):

1. **More repos** — "what else belongs to this product?" For each, clone it into the root
   (`git clone <url>`) so it becomes a sub-folder with its own `.git`, and add it to `REPOS` (fresh:
   include in `REPOS_SPEC` before scaffold; wrap: clone after W2, then re-run
   `--component workspace-sh --yes` so `workspace.sh` lists it). One repo is a fine workspace — don't push a split.
2. **Autonomy rung (`GOVERN_AUTONOMY`)** — surface the trust ladder explicitly, one honest sentence each:
   - **observe** — workers do the work and open a DRAFT PR; nothing is ever marked ready or merged. Watch-only.
   - **pr-only** (default) — workers open normal ready-for-review PRs; the governor still never auto-merges. You review + merge.
   - **auto** — allowlisted repos auto-merge on green-or-no-checks CI (still guarded by the three-factor check).
   Scaffold seeds `pr-only`. If the operator picks another rung, set it AFTER scaffold:
   `sed -i.bak -E 's/(GOVERN_AUTONOMY=.\$\{GOVERN_AUTONOMY:-)[a-z-]+/\1<rung>/' scripts/lib/workspace.sh && rm -f scripts/lib/workspace.sh.bak`.
3. **Externalization review gate** — if any registered repo is PUBLIC (`gh repo view <org>/<repo> --json visibility`
   → `PUBLIC`; silently skip if `gh` is absent), offer the `externalize-low-tickets.sh` review gate: each
   run STAGES Low-severity OSS-repo tickets into `queue/tickets-externalize-review.md` and files one
   questionnaire; a public GitHub Issue is filed ONLY after the operator answers `approve-all` (never
   auto-published). **Off by default** — only enable on an explicit yes.

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

### Starter ticket — make the first `/govern` run land a green PR

A fresh adopter's first `/govern` is far more convincing if it is short, cheap, and ends in a visible
merged (or mergeable) PR. **After verification has passed**, look for ONE small, guaranteed-tractable
item you already surfaced during scaffold and offer to file it as ticket #1 — the operator's first run
then has a real, tiny target instead of an empty queue. In priority order, pick the best available:

1. **A `doctor` warning the governor can fix** — e.g. a sub-repo missing a `.env.example` key that
   `doctor`/`config-check` flagged, a `package.json` script alias gap, a lint nit.
2. **A missing `.env.example` entry** — a referenced env var with no `.env.example` line (a safe,
   single-file add).
3. **A `README`/`CLAUDE.md` `TODO`** you can see is genuinely small and self-contained.

Propose it to the operator in one line and **only file on their confirmation** (this is their repo's
first ticket). File it with `file-ticket.sh` — reuse the existing mechanics, no new script — pinning a
cheap model so the first run is fast and inexpensive:

```bash
# Model: haiku for a truly mechanical one-file fix, sonnet for a small search+edit.
printf 'Where: <sub-repo>/<path>\nObserved: <the small gap>\nFix direction: <the obvious fix>\nDone when: <observable check>\n' \
  | scripts/govern/file-ticket.sh --model haiku "<short starter title>" Low
```

If scaffold surfaced nothing tractable, skip this — do NOT invent busywork. Tell the operator their
queue is empty and they can file their first real ticket with `/shiploop:investigate` or `file-ticket.sh`.

---

## Phase B — BUMP an existing meta-repo (component-by-component)

> **Ongoing maintenance:** for routine hub→workspace bumps after the workspace already exists,
> operators should reach for `/shiploop:update` — a one-command wrapper around the flow
> below. Setup's bump mode remains here for the first-run case (older workspace that predates the
> `.harness-version` stamp, unusual component surgery) and as the source of doctrine `/update`
> follows.

Print "This folder is already a meta-repo workspace — checking what's present vs the latest templates."

### B-pre — Safety: reclaim any stale run lock, cheap version check

Before touching anything, verify the governor isn't holding a lock and the version delta:

```bash
# If a cron/loop schedules this workspace's governor, take the run lock FIRST so it can't
# fire mid-bump: mkdir governor/.govern.lock  (a bump that overwrites govern/lib/common.sh
# while a governor run is live is a real hazard).
# If a prior worker crashed and left a lock behind, reclaim it — safe: it checks
# the holder pid liveness and only removes a dead-holder lock:
bash scripts/govern/lock-release.sh                # inspect + reclaim iff safe
bash scripts/govern/lock-release.sh --status       # holder info only

# Hub version + workspace stamp (both surface via scaffold --version and doctor.sh):
bash "$SCAFFOLD" --version                          # prints the hub VERSION (e.g. 1.2.0)
cat scripts/lib/.harness-version 2>/dev/null       # the version this workspace was stamped at

# Per-component sync report — see which components already match the templates (skip re-run)
# and which are behind, WITHOUT writing:
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --diff-only     # exit 3 = drift, 0 = clean
```

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
| workflows | `.claude/workflows/*.js` + bundled `.claude/skills/*/SKILL.md` present (tracked by `--diff-only`) |
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
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component workflows    --yes   # workflows + bundled skills
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component seeds        --yes   # only fills absent seeds
```

The refresh loop MUST cover every component `--diff-only` tracks (`core-scripts worktrees govern
githooks commands workflows`), or an untracked component loops "behind" forever (N5). `.gitignore` is
deliberately excluded — it is placeholder-filled + merge-only (never overwritten), so it is not a
byte-comparable bump target.

Component notes:
- **config (workspace.sh):** scaffold.sh refuses to overwrite an existing workspace.sh unless `--yes`.
  For a stale workspace.sh with missing NEWER vars, DIFF first, then either manually edit or (if the
  operator confirms) `--component workspace-sh --yes`.
  - **v1.1.0 → v1.2.0 knob-type migration.** `GOVERN_MERGE_REPOS` and `GOVERN_LOCAL_FIRST_REPOS`
    changed from bash arrays to **space-separated strings**. Single-element arrays coincidentally
    keep working (`$VAR` yields the first token); multi-element arrays BREAK silently. scaffold.sh
    detects the legacy shape at `--component workspace-sh` and prints the mechanical migration:
    ```bash
    # Old (array):
    GOVERN_MERGE_REPOS=(foo bar)
    GOVERN_LOCAL_FIRST_REPOS=(baz)
    # New (string):
    GOVERN_MERGE_REPOS="foo bar"
    GOVERN_LOCAL_FIRST_REPOS="baz"
    ```
- **govern:** preserves `governor/preferences.md`, `escalations.md`, `improvements.md`,
  `decisions-log.md` if present (operator data). Refreshes prompt templates only.
- **package.json:** scaffold.sh refuses to overwrite an existing one. For missing script aliases,
  merge them by hand (or overwrite with `--yes` after saving custom scripts).
- **tickets migration:** if a legacy root-level `tickets.md` exists, `git mv tickets.md queue/`
  yourself (scaffold.sh only seeds `queue/tickets.md` when absent).
- **CLAUDE.md:** scaffold.sh never overwrites — if the file predates the current template, append
  the missing sections yourself.
- **.claude/settings.json:** if it exists, scaffold.sh leaves it alone. Use
  `--component settings-merge` to idempotently insert the harness hook stanzas via jq without
  touching anything else in the file (safer than the old "merge missing hook entries yourself"
  path). Re-running it is a no-op once the stanzas are present.
- **stale relocated files:** scaffold.sh's `--verify` reads `templates/lib/relocations.txt` and
  warns if the workspace still carries a file the hub moved (e.g. a test that lived in
  `scripts/worktree/test/` but relocated to `scripts/govern/test/`). Delete the old path to clear
  the warning; nothing else is affected.
- **`--component all` bump caveat:** `--component all` (invoked as a whole-refresh) does NOT
  overwrite `workspace.sh`, `package.json`, or `.claude/settings.json` without `--yes` — it warns
  and continues, so you get everything EXCEPT the config knobs. For a real refresh, run the
  components explicitly (as shown above) OR pass `--yes` on `all` after saving customizations.

### B2b — Re-assert sub-repo commit hooks

The `githooks` bump above only refreshes the harness root's `.githooks/`. Each sub-repo is an
INDEPENDENT git repo that does NOT inherit the root's `core.hooksPath`, and a framework reinstall in
a sub-repo (husky's `prepare` on `npm install`) silently regenerates its hooks dir, WIPING the
attribution/pre-commit hooks the harness dropped there. So re-run the installers across every
sub-repo on a bump too — not just at fresh setup (Phase 3):

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$META_ROOT/$repo/.git" ] || [ -f "$META_ROOT/$repo/.git" ] || continue
  install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$repo"
  install_subrepo_pre_commit_hook "$META_ROOT" "$META_ROOT/$repo"
done
```

`doctor.sh`'s "sub-repo commit hooks" section flags any sub-repo whose resolved hook still differs
from `.githooks/`; run this step whenever it warns.

### B3 — Verify + commit

Cheap no-auth smoke FIRST — resolves every knob + helper, prints them, exits nonzero on any
missing required. This is what to run in a headless env that has no worker OAuth:

```bash
bash scripts/govern/config-check.sh              # human summary
bash scripts/govern/config-check.sh --json       # machine-readable
```

Then the full `bash -n` verify + stale-relocation check:

```bash
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes --verify
```

Optionally run the full govern test suite. **Pipe-stall caveat for headless environments**:
`timeout --foreground T bash test.sh 2>&1 | tail -N` blocks/hangs in some headless shells (the
same command run with a file redirect completes fine). Use this instead:

```bash
for t in scripts/govern/test/test-*.sh; do
  name=$(basename "$t" .sh)
  timeout --foreground 45 bash "$t" </dev/null > "/tmp/$name.log" 2>&1 & wait
  rc=$?
  # Exit 77 = well-known SKIP (test-update-channel.sh from a non-hub checkout,
  # test-sync-port.sh with the porter prompt absent). Treat it as skip, not fail.
  if [ "$rc" -eq 77 ]; then printf '%s\tskip\n' "$name"
  else printf '%s\t%d\n' "$name" "$rc"; fi
done
```

Or use scaffold's own runner: `bash "$SCAFFOLD" --workspace-dir . --component core-scripts --yes --verify --run-tests`.

**dry-run.sh spawns a live authenticated Claude worker** — from inside a nested Claude session
or a headless env with no worker auth, it will fail at "no valid report from worker". That's not
a bump regression; it's the auth caveat. Use config-check + the test suite for boot verification;
run dry-run.sh from a plain terminal.

Then commit refreshed tooling to the default branch (verified in Phase 0.5), staging tooling paths
explicitly (never `git add .`):

```bash
git add scripts .githooks governor package.json .gitignore .claude/settings.json .claude/commands
git commit -m "$(cat <<'EOF'
chore(harness): converge to shiploop v1.2.0

- refreshed <components …>
- <knob decisions: what was migrated / added>
- <stale relocations removed>
- suite: N/N pass
EOF
)"
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
