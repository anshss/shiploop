---
# sonnet on purpose: every judgment-heavy step is delegated to a deterministic script
# (detect-inputs.sh, wrap.sh --preflight/--yes, scaffold.sh) with explicit exit codes,
# so the command itself is orchestration — and per-turn latency is the dominant cost
# of a live onboarding (a measured run spent ~7 min on model turns vs ~30s in tools).
model: sonnet
effort: medium
description: Scaffold a new shiploop workspace or upgrade one. Routine bumps -> /update; push fixes upstream -> /push.
---

You are the meta-repo setup command. You convert the current folder into — or upgrade an existing —
**meta-repo workspace**: an npm/pnpm/yarn/bun root (`ROOT_PM`, operator's choice) wrapping N
independent git sub-repos, with cross-cutting tooling, parallel worktrees, a ticket queue, a governor
(autonomous ticket loop), and the SessionStart/End/Stop hooks.

The full pattern is documented in the plugin's `SKILL.md` (read if you need context). All mechanical
file writes are executed by `scaffold.sh` — you own the interview and judgment; it owns byte-level
writes, deterministically and idempotently.

## Locate the plugin

Templates and `scaffold.sh` live together. Resolve `PLUGIN_ROOT` in priority order:
1. `${CLAUDE_PLUGIN_ROOT}` (plugin run)
2. `~/.claude/skills/shiploop/` (legacy clone-into-skills)
3. `~/.claude/plugins/**` cache lookup by plugin name

`SCAFFOLD=$PLUGIN_ROOT/scaffold.sh`.

## Architecture (read once)

Every mechanism script sources ONE config file, `scripts/lib/workspace.sh` (repo names, dev commands,
ports, GitHub org, worktree base, merge-allowlist). Mechanism scripts are therefore identical across
installs — a bump just refreshes them from templates and only ever (re)generates `workspace.sh`.
**Never hand-edit a mechanism script; put the value in `workspace.sh`.**

## Interview doctrine — ONE pause

1. **Detect first, ask second.** Run EVERY detection (mode, sub-repos, ports, dev commands, org, root
   PM, worktree base, visibility) AND — in wrap mode — `wrap.sh --preflight` BEFORE the first
   question. Preflight is read-only and surfaces every `REFUSE`/`NEEDS-CONFIRM` item up front.
2. **One batched interview.** Ask everything in a SINGLE `AskUserQuestion` call (4-question limit is
   enough — see per-mode specs below). Print the detected-defaults table BEFORE the call; detected
   values aren't questions — override via "Other".
3. **Then run to completion without pausing.** Legitimate post-interview stops are ONLY: wrap.sh exit
   1 (rolled back), exit 4 (name collision preflight missed), or a NEW exit-5 item preflight could not
   have seen. Never re-ask something the interview covered.

Workspace layout scaffold.sh produces:
```
<root>/
  package.json            scripts/lib/workspace.sh        queue/tickets.md
  .gitignore              scripts/lib/{workspace,session-state,preflight,githooks}.sh
  .worktrees/.gitkeep     scripts/{doctor,dev,sync,tail}.sh   queue/tickets-parked.md
  governor/*.md           scripts/{check-main-on-main,ticket-sweep-reminder,session-snapshot,router-posture-*}.sh
  .claude/settings.json   scripts/worktree/*  + worktree/lib/registry.sh
  .claude/commands/*.md   scripts/govern/*    + govern/lib/common.sh
  CLAUDE.md               learnings.md                    .githooks/{pre-push,prepare-commit-msg}
  README.md               (workspace landing page — "<name> on Shiploop"; never overwritten)
```

---

## Phase 0 — Detect the mode

Print `── meta-repo setup ──`, then `pwd` and `ls -la`.

```bash
WRAP="$PLUGIN_ROOT/templates/lib/wrap.sh"
MODE="$(bash "$WRAP" --detect --workspace-dir "$(pwd)")"
echo "mode: $MODE"
```

| `$MODE` | Context | Do |
|---|---|---|
| `upgrade` | `scripts/lib/workspace.sh` present | **BUMP MODE** → Phase B |
| `fresh` | not inside any git repo | **FRESH MODE** → Phase 1 |
| `wrap` | AT the root of a git repo, `.git` is a directory | **WRAP OFFER** → Phase W |
| `refuse:gitfile` | `.git` is a FILE (linked worktree/submodule) | STOP — wrapping corrupts the main repo's back-pointers; out of scope for v1 |
| `refuse:below-root` | inside a git repo, below its root | STOP — "cd to the repo root and re-run" (print root path) |
| `refuse:bare` | bare repository | STOP — nothing to wrap |

Back-compat: an older meta-repo predating `scripts/lib/workspace.sh` but with a `package.json` whose
`"doctor"` script is `"bash scripts/doctor.sh"` is still **upgrade** even though `--detect` returns
`fresh` — treat as BUMP MODE (scaffold.sh re-parameterizes the core scripts). Very old installs also
carry the retired `"status"`/`"branch"`/`"switch"`/`"pull"`/`"push"`/`"health"` aliases; scaffold's
purge removes the scripts they point at, so drop those lines from `package.json` in the same pass.

## Phase W — Wrap-in-place (`$MODE == wrap`)

Gather everything first (W0), then run the single interview (W1). Do NOT ask anything before W1.

### W0 — Detect + preflight (ONE combined bash call)

Chain detection and preflight in a SINGLE call — don't hand-run per-value probes or split turns:

```bash
DET="$(bash "$PLUGIN_ROOT/templates/lib/detect-inputs.sh" --workspace-dir "$(pwd)" --mode wrap)"
printf '%s\n' "$DET"     # root_pm= / worktree_base= / org= / repo=<NAME>|<port>|<cmd>|<visibility> / repos_spec=
NAME="$(printf '%s\n' "$DET" | sed -n 's/^repo=\([^|]*\).*/\1/p' | head -1)"
bash "$WRAP" --preflight --workspace-dir "$(pwd)" --name "$NAME"   # read-only; surfaces every REFUSE / NEEDS-CONFIRM
```

`repo=` carries the wrap subfolder name (`NAME`, from `origin` else folder name — where the repo
lands: `<path>/<NAME>/`), its port + dev command, and visibility (`PUBLIC` unlocks
auto-externalization; `unknown` = no `gh`, treat as private). Only override a detected value you can
SEE is wrong.

Preflight is fail-closed; a single **prunable** worktree no longer refuses (auto-pruned), only LIVE
linked worktrees do.

- **exit 5** → collect each `NEEDS-CONFIRM[--confirm-x]: <why>` line; each becomes a Q4 option (the
  live-writer item always fires — it's always in the batch).
- **exit 4** (name collision) → pick the next default (`<name>-app`), re-run preflight. Don't pause.
- **exit 3** (hard refusal) → if the cause is plainly trivial uncommitted changes (a `.gitignore`
  line, editor config), fold "commit these first: <files>" into Q4, re-run preflight after commit is
  approved + made. Any other `REFUSE` → print verbatim and STOP.
- **exit 0** → clean (confirm flags already passed).

### W1 — The single interview (the ONLY pause)

Print in one message: (a) the wrap explanation below, (b) the detected-defaults table (subfolder
name, port, dev command, org, root PM, worktree base) with *"these apply as shown — pick Other to
override, or name extra repo clone URLs to add them"*, then (c) ONE `AskUserQuestion` call.

> Wrap-in-place moves this repo's contents into a subfolder (`<name>/`) of this same path and
> scaffolds the shiploop workspace root where the repo used to be. The path you `cd` into stays the
> same; your repo, its full history, and every untracked file move as a unit — verified
> byte-identical afterwards. A `.wrap-undo.sh` is written first and only removed once everything
> verifies; on any failure it rolls back automatically. One guarded script (`wrap.sh`) — never a
> sequence of moves driven by hand.

Four questions:
1. **Proceed?** — `wrap-in-place (recommended)` / `fresh-folder instead` (empty parent:
   `mkdir myproduct && cd myproduct && mv ~/code/this-repo . && /shiploop:setup` → Phase 1) / `cancel`.
2. **Autonomy rung** (`GOVERN_AUTONOMY`) — trust ladder, one honest sentence each (see shared
   interview-content section). `auto` allowlists THIS repo for auto-merge.
3. **Root remote** — `create private GitHub repo (<org>/<meta-name>)` / `skip for now`. The skip
   description must say plainly: without a root remote the governor's CAS ticket pushes and
   cross-driver ticket sync stay DISABLED.
4. **Confirmations & extras** (multiSelect) — one option per W0 `NEEDS-CONFIRM` item (e.g. *"live
   writer: dev servers and IDE indexers are stopped"*), plus `run <ROOT_PM> install + doctor at the
   end (recommended)`, plus `file a starter ticket if a small tractable one surfaces (recommended)`,
   plus — only when a registered repo is PUBLIC — `enable auto-externalization of Low tickets`.

`cancel` → stop. `fresh-folder` → print the mkdir/mv flow and stop. Any unselected `NEEDS-CONFIRM`
option = decline → STOP (wrap refuses without it). Extra repos named via Other are cloned after wrap
(W4).

Build `REPOS_SPEC` with the wrapped repo pre-registered FIRST: `"$NAME:$PORT:$CMD"` (plus any extra
repos). Everything after this point runs WITHOUT pausing.

### W2 — Invoke wrap.sh (single guarded call)

Pass the exact `--confirm-*` flag for every NEEDS-CONFIRM item approved in Q4:

```bash
bash "$WRAP" \
  --workspace-dir "$(pwd)" \
  --name "$NAME" \
  --pm "$ROOT_PM" --org "$ORG" \
  --repos "$REPOS_SPEC" \
  --merge-allowlist "$GOVERN_MERGE_REPOS" \
  --worktree-base "$WORKTREE_BASE" \
  --confirm-live-writer <other approved --confirm-* flags> \
  --yes
# exit 0 = wrapped+scaffolded; 3 = hard refusal; 4 = name collision; 5 = needs-confirm; 1 = rolled back
```

Do NOT move anything yourself — wrap.sh owns every filesystem step:
- **0** → continue to W3.
- **3** (hard refusal, fail-closed: dirty tree, in-progress op, `.git`-as-file, linked worktree,
  absolute `core.worktree`/`hooksPath`, `includeIf` gitdir abs, pre-existing `.wrap-undo.sh`,
  below-root, bare) → print the `REFUSE:` message verbatim and STOP. Do not override.
- **4** (name collision, case-insensitive on macOS/APFS) → ask a different subfolder name, re-invoke.
- **5** (needs-confirm — should not happen; W0 already covered every item) → if a NEW item appears
  (environment changed between preflight and invoke), relay it, get explicit yes, re-invoke with the
  flag added. Decline → STOP.
- **1** (rolled back) → a step failed mid-flight; wrap.sh already restored the original layout,
  keeping `.wrap-undo.sh`. Print the failure reason and STOP — don't retry blindly.

### W3 — Root remote (already answered — do not re-ask)

Apply the interview's Q3 answer:
- **create** → `gh repo create <org>/<meta-name> --private --source=. --remote=origin`.
- **skip** → note in the Phase Z report: **without a root remote the governor's CAS ticket pushes and
  cross-driver ticket sync are DISABLED**; `doctor`/`config-check` will keep surfacing it.

### W4 — Extra repos, hooks, verify

- Clone any operator-named extra repos into the root (`git clone`), then re-run the config component
  so `workspace.sh` lists them.
- Install sub-repo commit hooks now (wrapped repo + extras). Wrap mode deferred these — scaffold ran
  with `--skip-subrepo-hooks` so it never touched the moved sub-repo's `.git/hooks` while rollback was
  armed. Fold into ONE finalization bash block with the other post-wrap steps:

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$META_ROOT/$repo/.git" ] || [ -f "$META_ROOT/$repo/.git" ] || continue
  install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$repo"
  install_subrepo_pre_commit_hook  "$META_ROOT" "$META_ROOT/$repo"
done
bash scripts/govern/config-check.sh          # no-auth smoke, same turn
```
- If the interview's extras included install + doctor, run `<ROOT_PM> install` + `<ROOT_PM> run
  doctor` now.
- Verify: `bash scripts/govern/config-check.sh`, consider the starter-ticket block (Phase 4 — consent
  already collected in Q4), then continue to Phase Z.

The wrapped repo is already gitignored at root (`/<NAME>/`) and was NOT swept into the root commit —
wrap.sh asserts both before removing the undo script.

## Phase 0.5 — Branch guard (root must be on its default branch)

The doctrine + the `check-main-on-main` SessionStart hook assume the root stays on its default branch
(`main`). If setup runs on a feature branch, the governor strands off-main.

```bash
def=$(git -C . symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
def="${def:-main}"; cur=$(git -C . rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "root default branch: $def   currently on: $cur"
```
`cur == def` → continue. `cur != def` → STOP and warn; offer `git switch "$def"` (commit/stash
unrelated dirty work first) and re-confirm before generating.

---

## Phase 1 (fresh) — Detect, then the single interview

```bash
bash "$PLUGIN_ROOT/templates/lib/detect-inputs.sh" --workspace-dir "$(pwd)" --mode fresh
# → root_pm= / worktree_base= / org= / repo=<name>|<port>|<cmd>|<visibility> per sub-repo / repos_spec=
```

It scans every `*/` with its own `.git`; detects port + dev command (package.json script / lockfile /
`Makefile` / `Cargo.toml` / `go.mod`); resolves port collisions to distinct stable ports (3000, 3001,
…); detects root PM from a root lockfile (default `npm`); parses org from the first repo's `origin`;
marks visibility (`PUBLIC` enables auto-externalization; `unknown` = no `gh`, treat as private). Only
override a value you can SEE is wrong.

**Zero `repo=` lines** → stop, tell the operator to add at least one sub-repo (its own `.git`). **One
sub-repo is enough** — a single-repo workspace is fully valid; don't nudge toward a multi-repo split.

**The single interview:** print the detected table (repos, ports, dev commands, org, root PM,
worktree base) with *"these apply as shown — pick Other to override, or name extra repo clone URLs to
add them"*, then ONE `AskUserQuestion` call:

1. **Proceed?** — `scaffold with these detected values (recommended)` / `cancel`.
2. **Autonomy rung** (`GOVERN_AUTONOMY`) — trust ladder (shared interview-content section below).
3. **Governor merge-allowlist** (multiSelect) — which sub-repos may be auto-merged on
   green-or-no-checks CI: one option per repo plus `none (default, safest)`. Only matters on the
   `auto` rung — say so.
4. **Extras** (multiSelect) — `run <ROOT_PM> install + doctor at the end (recommended)`, `file a
   starter ticket if a small tractable one surfaces (recommended)`, and — only when a repo is PUBLIC
   — `enable auto-externalization of Low tickets`.

Everything after this runs WITHOUT pausing.

## Interview content shared by BOTH modes

These live INSIDE the single interview (W1 / Phase 1) — never as separate later questions:

1. **More repos** — invited via the defaults-table note. For each: `git clone <url>` into the root,
   add to `REPOS` (fresh: before scaffold; wrap: after W2, then re-run
   `--component workspace-sh --yes`). One repo is a fine workspace.
2. **Autonomy rung (`GOVERN_AUTONOMY`)**:
   - **observe** — workers do the work and open a DRAFT PR; nothing merges. Watch-only.
   - **pr-only** (default) — normal ready-for-review PRs; governor never auto-merges. You review.
   - **auto** — allowlisted repos auto-merge on green-or-no-checks CI (three-factor guard still gates).
   Scaffold seeds `pr-only`. To set another rung AFTER scaffold:
   `sed -i.bak -E 's/(GOVERN_AUTONOMY=.\$\{GOVERN_AUTONOMY:-)[a-z-]+/\1<rung>/' scripts/lib/workspace.sh && rm -f scripts/lib/workspace.sh.bak`.
3. **Auto-externalization** — only offered when a registered repo is PUBLIC. Enables
   `externalize-low-tickets.sh` (moves Low-severity tickets to public GitHub issues). **Off by
   default.**

## Phase 2 (fresh) — Invoke scaffold.sh

`--repos` = `name:port:cmd,name:port:cmd,…` (empty port allowed: `name::cmd`).

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

Handles: templates copy, placeholder fills, chmod +x, `.gitignore` synth, package.json scripts block,
`.claude/settings.json` wiring, seed files (only if absent), `.githooks` activation, initial commit.
`--verify` runs `bash -n` over every installed script + sources `workspace.sh`.

## Phase 3 (fresh) — Sub-repo commit hooks (automatic)

`scaffold.sh` propagates `.githooks/prepare-commit-msg` (attribution) and the optional
`.githooks/pre-commit` (lint-fix) into every sub-repo at the end of Phase 2 — no hand-run loop; the
scaffold output shows `✓ <repo>: attribution hook` / `✓ <repo>: pre-commit hook`.

Pre-commit is a no-op until `WSP_LINT_FIX_CMD` is set in `workspace.sh`. Sub-repos with an existing
pre-commit hook (husky, lefthook, hand-rolled) are left untouched. `worktree/new.sh` re-runs both
installers per worktree. Only re-run by hand if `doctor.sh` warns (Phase B2b).

## Phase 4 (fresh) — Initialize + report

If the interview's extras included it, run `<ROOT_PM> install` + `<ROOT_PM> run doctor` now and show
the output; else note it skipped in the Phase Z report.

Mention optional next steps: hand-write `scripts/lib/worktree-bootstrap.sh` for per-worktree setup
(`worktree/new.sh` sources it when present; same for `session-cleanup.sh` and `doctor-extra.sh`);
customize `governor/preferences.md`; before the first named dispatch, from a
**plain terminal** run `claude -p "ping" --model sonnet --strict-mcp-config` to confirm worker auth.

### Starter ticket

After verification passes, look for ONE small guaranteed-tractable item surfaced during scaffold to
become ticket #1, so the first named dispatch has a real target instead of an empty queue. Priority
order:
1. A `doctor`/`config-check` warning the governor can fix (missing `.env.example` key, script alias
   gap, lint nit).
2. A missing `.env.example` entry for a referenced env var.
3. A genuinely small, self-contained `README`/`CLAUDE.md` `TODO`.

The interview's extras question already collected consent. If selected, file the best candidate now
and describe it in one line of the Phase Z report; if deselected, put the proposal + exact command in
the report instead — don't pause either way. File via `file-ticket.sh`:

```bash
printf 'Where: <sub-repo>/<path>\nObserved: <the small gap>\nFix direction: <the obvious fix>\nDone when: <observable check>\n' \
  | scripts/govern/file-ticket.sh "<short starter title>" Low
```

Do NOT pin a model — the scout measures scope against real code before dispatch. If nothing
tractable surfaced, skip — don't invent busywork; tell the operator the queue is empty.

---

## Phase B — BUMP an existing meta-repo (component-by-component)

> For routine hub→workspace bumps after the workspace exists, prefer `/shiploop:update` (a wrapper
> around this flow). Setup's bump mode is for the first-run case (workspace predates
> `.harness-version`, unusual component surgery) and is the doctrine `/update` follows.

Print "This folder is already a meta-repo workspace — checking what's present vs the latest templates."

### B-pre — Safety: reclaim stale run lock, cheap version check

```bash
# If a cron/loop schedules this workspace's governor, take the run lock FIRST (a bump overwriting
# govern/lib/common.sh while a governor run is live is a real hazard). Safe to reclaim a dead-holder lock:
bash scripts/govern/lock-release.sh                # inspect + reclaim iff safe
bash scripts/govern/lock-release.sh --status       # holder info only

bash "$SCAFFOLD" --version                          # hub VERSION (e.g. 1.2.0)
cat scripts/lib/.harness-version 2>/dev/null       # this workspace's stamp

bash "$SCAFFOLD" --workspace-dir "$(pwd)" --diff-only     # per-component drift, no writes; exit 3 = drift, 0 = clean
```

### B0 — Re-detect

Re-run Phase 1 detection (sub-repos, ports, dev commands, org). Source `scripts/lib/workspace.sh` and
compare; note drift.

### B1 — Component inventory

Build a `component | status` table (`present (current)` / `present (outdated)` / `missing`); judge
"outdated" by `diff` against the bundled template:

| Component | Probe |
|---|---|
| config | `scripts/lib/workspace.sh` has all current vars (`GOVERN_MERGE_REPOS`, `WORKTREE_BASE`, `wsp_repo_port`) |
| core-scripts | `scripts/{doctor,dev,sync,tail}.sh` |
| worktrees | `scripts/worktree/{new,rm,status,exec,main,session-end-cleanup}.sh` + `lib/registry.sh` |
| tickets | `queue/tickets.md` present (old workspaces: root-level `tickets.md` — migrate) |
| commands | `.claude/commands/flows.md` present |
| agents | `.claude/agents/{lookup,investigator}.md` present (tracked by `--diff-only`) |
| workflows | `.claude/workflows/*.js` + bundled `.claude/skills/*/SKILL.md` (tracked by `--diff-only`) |
| govern | `scripts/govern/` + `governor/` present |
| hooks | `scripts/{check-main-on-main,ticket-sweep-reminder,session-snapshot,router-posture-*}.sh` + `.claude/settings.json` wiring |
| githooks | `.githooks/{pre-push,prepare-commit-msg}` + `core.hooksPath == .githooks` |

### B2 — Offer upgrades

```bash
# Safe to refresh — mechanism scripts only read workspace.sh:
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component worktrees    --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component govern       --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component githooks     --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component commands     --yes
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component agents       --yes   # shipped lookup/investigator agents
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component workflows    --yes   # workflows + bundled skills
bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component seeds        --yes   # only fills absent seeds
```

Cover every component `--diff-only` tracks (`core-scripts worktrees govern githooks commands agents
workflows`), or an untracked one loops "behind" forever. `.gitignore` is deliberately excluded — it's
placeholder-filled + merge-only (never overwritten), not byte-comparable.

Component notes:
- **config (workspace.sh):** scaffold.sh refuses to overwrite unless `--yes`. For a stale
  workspace.sh missing newer vars, DIFF first, then manually edit or (with confirmation)
  `--component workspace-sh --yes`.
  - **v1.1.0 → v1.2.0 knob-type migration:** `GOVERN_MERGE_REPOS` and `GOVERN_LOCAL_FIRST_REPOS`
    changed from bash arrays to space-separated strings (single-element arrays coincidentally still
    work; multi-element BREAK silently). scaffold.sh detects the legacy shape and prints the
    mechanical migration:
    ```bash
    # Old: GOVERN_MERGE_REPOS=(foo bar)          # New: GOVERN_MERGE_REPOS="foo bar"
    # Old: GOVERN_LOCAL_FIRST_REPOS=(baz)         # New: GOVERN_LOCAL_FIRST_REPOS="baz"
    ```
- **govern:** preserves `governor/preferences.md`, `escalations.md`, `improvements.md`,
  `decisions-log.md` (operator data). Refreshes prompt templates only.
- **package.json:** refuses to overwrite existing. Merge missing script aliases by hand, or overwrite
  with `--yes` after saving custom scripts.
- **tickets migration:** legacy root-level `tickets.md` → `git mv tickets.md queue/` yourself
  (scaffold only seeds `queue/tickets.md` when absent).
- **CLAUDE.md:** never overwritten — if it predates the current template, append missing sections
  yourself.
- **.claude/settings.json:** if it exists, left alone. Use `--component settings-merge` to
  idempotently insert harness hook stanzas via jq without touching the rest of the file; a no-op once
  present.
- **stale relocated files:** `--verify` reads `templates/lib/relocations.txt` and warns if the
  workspace still carries a file the hub moved. Delete the old path to clear the warning.
- **`--component all` caveat:** does NOT overwrite `workspace.sh`, `package.json`, or
  `.claude/settings.json` without `--yes` — you get everything except the config knobs. Run
  components explicitly for a real refresh, or pass `--yes` after saving customizations.

### B2b — Re-assert sub-repo commit hooks

The `githooks` bump above only refreshes the harness root's `.githooks/`. Each sub-repo is an
INDEPENDENT git repo not inheriting `core.hooksPath`, and a framework reinstall (husky's `prepare`)
silently WIPES the attribution/pre-commit hooks dropped there — so re-run the installers across every
sub-repo on a bump too:

```bash
source scripts/lib/workspace.sh
source scripts/lib/githooks.sh
for repo in "${REPOS[@]}"; do
  [ -d "$META_ROOT/$repo/.git" ] || [ -f "$META_ROOT/$repo/.git" ] || continue
  install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$repo"
  install_subrepo_pre_commit_hook "$META_ROOT" "$META_ROOT/$repo"
done
```

`doctor.sh`'s "sub-repo commit hooks" section flags any sub-repo whose resolved hook differs — run
this whenever it warns.

### B3 — Verify + commit

```bash
bash scripts/govern/config-check.sh              # human summary — cheap no-auth smoke, run FIRST
bash scripts/govern/config-check.sh --json       # machine-readable

bash "$SCAFFOLD" --workspace-dir "$(pwd)" --component core-scripts --yes --verify   # bash -n + stale-relocation check
```

The govern test suite is hub-only — it is not installed into a workspace and there is nothing to run
here. Harness regressions are caught by the hub's own CI, which scaffolds a throwaway workspace.

**`dry-run.sh` spawns a live authenticated Claude worker** — inside a nested Claude session or a
headless env with no worker auth it will fail at "no valid report from worker." That's the auth
caveat, not a bump regression; run it from a plain terminal.

Commit refreshed tooling to the default branch, staging tooling paths explicitly (never `git add .`):

```bash
git add scripts .githooks governor package.json .gitignore .claude/settings.json .claude/commands
git commit -m "$(cat <<'EOF'
chore(harness): converge to shiploop v1.2.0

- refreshed <components …>
- <knob decisions: what was migrated / added>
- <stale relocations removed; retired files purged>
EOF
)"
```

---

## Phase Z — Report

```
── meta-repo workspace ready ──
Mode:        <fresh | wrapped | bumped>
Sub-repos:   <name (port)> …
Installed:   core scripts · worktrees · tickets · governor · /flows command · hooks · README
Decisions:   autonomy=<rung> · allowlist=<repos|none> · remote=<created|skipped> ·
             starter ticket=<filed #N|proposed below|none> · externalization=<on|off>
             (everything above came from the single interview — one recap, no re-asks)
Try:
  <ROOT_PM> run worktree:new -- try-it && cd <worktree-base>/try-it
  scripts/govern/run-loop.sh --dry-run <N>   # or just say "dry-run ticket <N>"
Still needs you:
  - per-sub-repo .env files (see <repo>/.env.example)
  - enable optional hooks: write scripts/lib/{worktree-bootstrap,session-cleanup,doctor-extra}.sh
  - set GOVERN_MERGE_REPOS in scripts/lib/workspace.sh + customize governor/preferences.md
  - confirm worker auth (plain terminal): claude -p "ping" --model sonnet --strict-mcp-config
```
Stop. Do not proactively build further features unless asked.
