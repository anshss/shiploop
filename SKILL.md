---
name: shiploop
description: Self-improving multi-agent harness: wraps N git sub-repos as one workspace, dispatches named tickets to cheap-floor subagents that escalate once on failure, promoting lessons into CLAUDE.md. Use when working in or scaffolding a meta-repo workspace (sub-folders each own .git; root has scripts/ + queue/tickets.md + governor/). Scaffold via /shiploop:setup.
---

# shiploop — self-improving multi-agent harness

## What it is

A workspace root holding N independent git repos as sub-folders — each its own remote, PR queue, CI
— where the root is *also* its own git repo holding config, cross-cutting scripts, the ticket queue,
the governor, and shared AI context. A self-improving multi-agent harness sits on top (worktrees +
tickets + governor + hooks): a worker is a trim, single-ticket session, one per ticket, dispatched
as a `worker` subagent at a cheap model floor and escalated once on a classified failure; every
resolved ticket promotes a durable lesson into the git-tracked `CLAUDE.md`.

Example shape: `your-workspace/{backend,console,website}/` — three sub-folders, each its own git
repo, a script launcher at the root.

**The root uses ONE package manager** — npm/pnpm/yarn/bun (`ROOT_PM` in `scripts/lib/workspace.sh`,
default `npm`). Root `package.json` holds only thin `bash scripts/<x>.sh` aliases, so `npm run dev`
/ `pnpm dev` / `yarn dev` all run the same PM-agnostic bash — `ROOT_PM` only picks the CLI you type
and what `doctor` checks. Each sub-repo keeps its own PM independently. Rule: never mix two PMs at
the root (a stray second lockfile diverges from the real one); root `.gitignore` ignores the
off-PM lockfiles.

## When to use this pattern

Use when: services deploy on independent cadences · you want to scope contractor access to one
sub-repo · you want full product context while editing one slice, with an agent working the tickets
you name semi-autonomously · you want cross-stack QA without coupling code.

Don't use when: all services deploy together (Turborepo / single repo) · sub-repos share code daily
(N git remotes make sharing painful) · too early for the abstraction cost.

If unsure, default to a single repo or Turborepo — meta-repo is a deliberate, opinionated choice.

**N=1 is fine** — ticket queue, governor, worktrees, and lesson-accretion pay for themselves on one
repo. Fastest first taste: `/shiploop:flows extract` on an existing repo — inventories every
user-facing path that might break, staged for approval, nothing deployed.

## Operating commands (once installed)

Examples use `npm run` (default `ROOT_PM`); substitute `pnpm <script>` / `yarn <script>` /
`bun run <script>`.

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos; tee output to `logs/<name>.log`. `-- --only a,b` to scope |
| `npm run dev:<name>` | Boot one sub-repo |
| `npm run doctor` | Health audit: tooling, env files, ports, sub-repo presence (+ project `doctor-extra.sh`) |
| `npm run sync` | Pull/rebase every sub-repo onto its origin `main`, pruning dead branches |
| `npm run tail` | Tail sub-repo dev logs, interleaved and prefixed by name |
| `npm run worktree:new -- <slug>` | Allocate a slot; create isolated worktrees on branch `<slug>` |
| `npm run worktree:rm -- <slug>` | Clean up + remove a worktree, free its slot |
| `npm run worktree:status` | Slot table (`-- --gc` prunes orphans) |
| `npm run worktree:exec -- <slug> [-- <cmd>]` | Run a command with that slot's env |
| `npm run worktree` | Worktree dispatcher (`new` / `rm` / `status` / `exec`) |
| `npm run govern:pre-dispatch -- <N>` | Every pre-spawn gate for ticket N, one verdict line: `proceed` / `skip: <reason>` / `refuse: <reason>` |
| *(say "work on \<tickets\>")* | Dispatch a `worker` subagent for ticket N and pipe its JSON report onward (see Dispatch below) |
| `npm run govern:resolve -- <N>` | Fed a worker's JSON report on stdin: awaits CI, merges, and lands the resolution |
| `npm run govern:health` | Governor health audit |
| `npm run govern:dry-run -- <N>` | Rehearse one ticket end to end, nothing merged or committed |
| `npm run govern:audit` | Manual run audit, zero model spend unless invoked |
| `npm run govern:context-budgets` | Report context budgets (lesson-cap and total-budget overage, learnings TTL archiving) outside a dispatch; never edits `CLAUDE.md` |
| `npm run govern:trim` | Evidence-based CLAUDE.md compression detector alone: classifies every over-budget block, never edits the file |
| `npm run govern:externalize` | File open low-severity tickets as public good-first-issues and drop them from the queue (no-op until `GOVERN_EXTERNALIZE_REPO` is set) |
| `npm run govern:validations` | Run the governor validation suite |
| `/shiploop:flows extract` | Inventory every user-facing path that might break (staged, no billing) |
| `/shiploop:compress` | Move mechanically-triggered `CLAUDE.md` rules into just-in-time rule packs (no rule is deleted) |

**Pass args/flags after the script with `--`** — npm/pnpm need it or they swallow the flags; yarn
classic tolerates it either way. Bare verbs are fine without it.

## Parallel worktrees (the isolation primitive)

**Any task that will touch code starts with `npm run worktree:new -- <slug>` and `cd` into it.** The
main checkout is read/plan/main-branch-ops only — never edit code there. Each worktree is isolated:
own branches, dev stack, ports, SessionEnd cleanup.

- Worktrees live at `$WORKTREE_BASE/<slug>/` (sibling of the main checkout, so editors/watchers don't index them).
- A slot **registry** (`.worktrees/registry.json`, mkdir-locked) assigns each worktree a slot number.
  **Ports offset by `slot × 10`** (set in `worktree.env`, consumed by `dev.sh`/`doctor.sh`/hooks) — N
  stacks run at once without collisions.
- The **meta-repo worktree is detached at `main`** — coordination files (CLAUDE.md, queue/tickets.md,
  learnings.md, scripts/) commit directly to main in the main checkout, never branched. Only sub-repo
  code gets a feature branch.
- Per-worktree project setup (deps, codegen, DB pointer, per-slot namespace) lives in the optional
  `scripts/lib/worktree-bootstrap.sh` hook — `new.sh` calls it; the mechanism stays project-agnostic.
- Clean up with `npm run worktree:rm -- <slug>` after PRs merge (runs the project's
  `session-cleanup.sh` first, then removes trees and frees the slot).

**Main checkout stays on `main`, every repo, always.** `check-main-on-main.sh` (SessionStart hook)
warns on drift.

## Ticket queue

A durable, file-based backlog the whole harness reads.

- **`queue/tickets.md`** — work items only. Each is its own numbered `## #N — Title` block (Severity
  / Where / Observed / Fix direction / Done when / Ref). **Numbers are stable IDs while open** — never
  renumber an open ticket (in-flight PRs reference it). Gaps from deleted tickets are expected.
- **Scope-isolated to two things: the PROJECT + the HARNESS** (this workspace's sub-repos, and
  meta-repo mechanism — `scripts/`, `governor/`, `queue/`, hooks, config). Anything external (a
  bolt-on tool/skill invoked from this terminal) must never file here — its own tracker instead. A
  ticket that turns out to be external tooling is deleted, not worked.
- **`tickets-parked.md`** — defer a ticket by moving it here; the governor ignores it. Independent
  serial numbering (renumber to destination max+1 when moving).
- **Resolved = a fix PR is OPENED** (not merged). DELETE the entry the same session the PR opens,
  referencing the PR# in the deletion commit. Promote any durable lesson first — root-worthy via
  `lessonPatch`, sub-repo-scoped by editing that sub-repo's own `CLAUDE.md` inside the PR.
- **Close-out discipline** — when the PR opens: promote the durable lesson, delete the entry, then
  sweep the session diff for newly-discovered gaps (fold into open tickets by default; mint a new
  number only for independently dispatchable work).
- **Placement gate on `lessonPatch`** — root `CLAUDE.md` is re-sent every turn of every
  session, so a lesson that is really one sub-repo's internals permanently taxes sessions that never
  touch that sub-repo. `land-resolution.sh` doesn't trust the reporting worker's placement claim: it
  re-derives scope from the lesson text itself (`govern::lesson_placement` in `lib/common.sh`) and
  redirects — committing straight into `<sub-repo>/CLAUDE.md` — ONLY when exactly one sub-repo is
  referenced as a path, no second sub-repo is named anywhere in the text, and no cross-cutting signal
  (governor / workspace.sh / meta-repo / …) is present. Any less clear-cut case stays at root; either
  outcome is logged for audit.
- The **Stop hook** (`ticket-sweep-reminder.sh`) fires once at the end of a code-touching session
  (marker-gated on session_id, honors `stop_hook_active`) reminding you to file/delete tickets.
  Read-only sessions stop silently.

Learnings routing (queue vs CLAUDE.md vs learnings.md vs project memory) follows the workspace's own
root `CLAUDE.md` — that file auto-loads every session; this skill doesn't restate its table. Bar
either way: would knowing this save a future session 5+ min?

## Dispatch, natural language onto the session lane

There is no `/govern` command, and there is no always-on loop behind it either. Dispatch runs
inside YOUR session, one ticket at a time, near-zero Claude context throughout:

1. `scripts/govern/pre-dispatch-check.sh <N>` (or `npm run govern:pre-dispatch -- <N>`), every
   pre-spawn gate, one verdict line on stdout: `proceed` / `skip: <reason>` / `refuse: <reason>`.
2. On `proceed`, dispatch `Agent(subagent_type: "worker")` for that ticket. The worker runs the
   doctrine in `governor/worker-prompt.md`, self-services its own worktree, implements the ticket's
   proposed solution, and returns a JSON report: it never merges and never touches
   `queue/tickets.md`.
3. `scripts/govern/resolve-ticket.sh <N>`, fed the worker's report on stdin, awaits CI, merges, and
   lands the resolution.

Named dispatch is the only front door: you name the ticket, the pipeline works exactly that one, at
the least spend, with every gate on. There is no backlog sweep and no grind-until-empty loop.

| You say | Run |
|---|---|
| "work on 414" | `pre-dispatch-check.sh 414` → dispatch a `worker` subagent → pipe its report into `resolve-ticket.sh 414` |
| "work on 414 156 234 235" | the same three steps, once per ticket, in severity order, sequential, there is no fan-out |
| "dry-run 414" | `scripts/govern/dry-run.sh 414`, previews the merge decision and the queue-bookkeeping diff, nothing committed |

These differ **only in selection and count**, there is no concurrency knob left to reach for.
**Do not re-implement the pipeline in-context**, driving a worker by hand instead of through the
gate/dispatch/land steps is the anti-pattern this design replaces; if `pre-dispatch-check.sh`
returns `skip`/`refuse`, or `resolve-ticket.sh` exits non-zero, report why, don't take over.

Dispatch requires a live session: a worker is a subagent, not a separate process, so there is no
headless or unattended path any more. `claude -p "ping" --model sonnet --strict-mcp-config` should
print text, not a 401 (`claude login` once if it 401s), if you need to sanity-check the CLI itself.

**Autonomy is a ladder — observe → pr-only → auto**, set by `GOVERN_AUTONOMY` in
`scripts/lib/workspace.sh`. A new workspace starts on **pr-only**: workers open normal PRs but
`resolve-ticket.sh` never merges them. In **observe**, workers push a `ticket-<N>` branch but open
the PR as **draft**. **auto** needs both `GOVERN_AUTONOMY=auto` (global rung) *and* the repo listed
in `GOVERN_MERGE_REPOS` (per-repo allowlist, empty by default), only then does that repo's tickets
auto-merge on green CI. Graduate one repo at a time. (Absent/empty `GOVERN_AUTONOMY` resolves to
`auto` for backward compat.)

- **Per ticket:** `pre-dispatch-check.sh` gates it → a worker runs in a fresh `ticket-<N>` worktree →
  it implements + validates + opens a PR and returns a JSON report → `resolve-ticket.sh`, for an
  auto-merge repo, awaits CI and merges on **green-or-no-checks** → deterministic `queue/tickets.md`
  bookkeeping via `land-resolution.sh` (the worker never writes it). Frontend/PR-only repos stop at
  the open PR.
- **Locality batching (folding two co-located tickets into one worker session) has no dispatcher
  any more**: it lived in the headless launcher's multi-ticket invocation, retired along with it.
  `pre-dispatch-check.sh` still prints a non-blocking `[overlap]`/`[overlap-dir]` nudge when an OTHER
  open ticket shares a measured file (or, weaker, a directory) with the one you named; there is no
  action to take on it beyond working both tickets, one at a time, through the normal dispatch.
- **Escalation reconcile runs at SessionStart, not at dispatch time.** `session-reconcile.sh` applies
  any answered escalations and regenerates `governor/pending-escalations.json` the moment a plain
  session starts, so `pre-dispatch-check.sh` never has to. Run it by hand with
  `npm run govern:escalations-apply` / `npm run govern:escalations-emit` if you don't want to wait
  for the next session.
- **Worker autonomy:** `--permission-mode bypassPermissions` scoped to throwaway worktrees, with
  `--setting-sources user` (drops the project's own hooks). `governor/preferences.md` defines the
  **hard-stops** (destructive git; prod data / destructive schema / secrets) that make a worker
  **park + escalate** instead of acting.
- **Always ends:** `GOVERN_WORKER_TIMEOUT` (1h) and `GOVERN_WORKER_MAX_TOKENS` (0 = unlimited by
  default; killed on cross as `budget-exceeded`) bound one worker. Across attempts,
  `GOVERN_MAX_TICKET_FAILS` (default 2 consecutive failed/timed-out/budget-exceeded dispatches) makes
  `pre-dispatch-check.sh` file an escalation and skip re-spawning instead of retrying forever.
- **Progress-preserving:** only a cleanly-landed worktree is torn down (by `resolve-ticket.sh`);
  failed/parked/timed-out worktrees are kept and an existing `ticket-<N>` PR is reused on re-run.
- **Manual audit** (`npm run govern:audit`, zero model spend unless invoked) reviews recent dispatch
  state for duplicates/dependency-ordering/failure-patterns and can return a `halt` verdict.
  `governor/improvements.md` is operator-maintained notes on harness friction; nothing proposes or
  applies a fix to it automatically.

**Escalations, surface and answer them whenever `pending-escalations.json` is non-empty.**
1. Read `governor/pending-escalations.json` (kept current by `session-reconcile.sh` at every
   SessionStart). `count: 0` → nothing needed, just summarize.
2. Present **ALL** pending escalations in a **single batched `AskUserQuestion` call** (4 questions per
   prompt limit → one entry per question; `count > 4` → chunk into `ceil(count/4)` calls). For each
   entry use its `question` + `options`, and always include: **Do the work** (un-park → the ticket is
   dispatchable again), **Defer / keep-manual** (moves to `tickets-parked.md`), **Keep open** (decide
   later). Batch every escalation from one sweep into one ask, don't fragment it across turns.
3. Write the answer into `governor/escalations.md` under that `### #N` entry via
   `scripts/govern/record-escalation-answer.sh <N> --answer "<their words>" --disposition <token>
   [--rule "<rule text>"]` (`<token>` = `do-the-work` | `defer` | `mitigated` | `keep-open`). The next
   SessionStart applies it automatically, or run `npm run govern:escalations-apply` yourself to apply
   it immediately.

## Hooks (deterministic session scaffolding)

Wired into `.claude/settings.json` by setup:
- **SessionStart:** `learnings-digest.sh` (inject newest `learnings.md` entries, nothing if none) ·
  `check-main-on-main.sh` (warn on drift) · optional project drift check.
- **UserPromptSubmit:** `router-posture-reminder.sh` (prime delegate-heavy-work-to-a-child posture
  once per session).
- **PreToolUse (Read|Bash|Agent):** `router-posture-guard.sh` (catch a router-posture violation in
  the moment; on `Agent` it DENIES a ticket-shaped call that is not
  `subagent_type: "worker"`, kill switch `GOVERN_TICKET_ROUTE_GUARD=0`).
- **PreToolUse (Write|Edit|Bash):** `rules-on-touch.sh` (deliver the rule pack for the surface being
  touched, so a rule that only matters while editing a shell script is not resident in `CLAUDE.md`
  for every session that never opens one; advisory only, at most 2 packs per call, kill switch
  `GOVERN_RULES_ON_TOUCH=0`). It deliberately fires in workers too: a delegate never loads the root
  `CLAUDE.md`. A workspace adds its own packs in `scripts/rules-on-touch.local.sh` without editing the
  template.
- **Stop:** `ticket-sweep-reminder.sh` (reconcile tickets once per code-touching session).
- **SessionEnd:** `worktree/session-end-cleanup.sh` (project cleanup, then kill this worktree's
  stack ports).

## CLIs and MCPs — built for autonomy

- **External tools are CLIs, not MCP servers, wherever possible** — Claude shells out (`gh`, `git`,
  cloud CLIs, `scripts/*.sh`); those auth CLI-side once and never prompt mid-session. Reserve MCP
  (registered only in the root `.mcp.json`) for things with no good CLI, authed via env-var expansion
  (`${TOKEN}`) so headless/governor runs inherit them.
- **MCP servers always at the workspace root.** Never `claude mcp add` from a sub-repo.
- Governor workers run as `bypassPermissions` subagents in throwaway worktrees: safety comes from
  doctrine hard-stops + the merge allowlist, not interactive prompts.

## Anti-patterns

The scaffolded workspace `CLAUDE.md` (auto-loaded every session) carries the enforced list: MCP-at-
root, `cd`-before-commit, no shared-branch assumption, verify-repo-before-destructive-git,
merge-backend-first, `.env.example`-is-the-contract, one-PM-at-root, main-only-in-main-checkout,
tear-down-stack-on-PR, workers-never-write-tickets, driver-never-reads-source. This skill doesn't
restate it — see that file.

## Cross-stack discipline

1. `npm run worktree:new -- feat/foo`
2. Make changes per sub-repo
3. `cd <sub-repo> && git add … && git commit … && git push -u origin HEAD`
4. `gh pr create` per changed sub-repo
5. Track sibling PRs together; merge backend-first, state the order in each PR.

PRs land independently — don't expect atomicity.

## Setup / upgrade a workspace

Invoke **`/shiploop:setup`**. Detects the mode (`wrap.sh --detect`), idempotent:
- **Inside an existing repo (wrap-in-place):** `cd your-project && /shiploop:setup`. Offers to move
  the repo into a subfolder and scaffold the workspace root where it used to be, so the `cd` path is
  unchanged. One guarded script (`templates/lib/wrap.sh`): fail-closed preflight → rename-only move →
  byte-identical verify → scaffold with the repo pre-registered → final verify, with a `trap` rollback
  and a manifest-based `.wrap-undo.sh` removed only once verified.
- **Fresh folder:** detects sub-repos (`.git/` folders), ports, dev commands; asks the root PM; writes
  `package.json`, `.gitignore`, `scripts/lib/workspace.sh`, copies mechanism scripts/hooks/governor
  scaffold/seed `queue/tickets.md`/`learnings.md`; wires `.claude/settings.json`; optionally installs +
  runs doctor.
- **Existing meta-repo (bump):** detects which capabilities are present vs missing/outdated, offers to
  add/upgrade each. Customization lives in `scripts/lib/workspace.sh`, so mechanism scripts refresh
  from latest templates without clobbering tweaks.

## Tradeoffs

**Costs:** N git remotes multiply every PR/CI/branch op; silent cross-stack contract breaks (no
shared-types hedge by default); custom tooling with no community ecosystem; the governor consumes
real tokens and can open billable resources — bounded but not free.

**Gains:** independent deploy cadences without losing cross-product context; bounded file trees with
full product visibility; parallel agent work without merge conflicts; one home for MCP config +
shared scripts; tickets a session can dispatch semi-autonomously.

Migrating meta-repo → Turborepo is only worth recommending once independent-deploy pain is concrete.

## Baseline vs. production reference harness (intentional omissions)

These templates are a deliberately-minimal baseline tracking the governor's core pipeline (named
dispatch → spawn worker in a worktree → open PR → green-or-none auto-merge → deterministic
bookkeeping → escalations, plus a manual audit you can run on demand). The production harness this
skill was extracted from
has accreted hardening refinements that only matter at *large, long, fleet-concurrent* scale — omitted
here on purpose (each easy to port the day you hit its failure mode):

| Feature | Reference harness has | The baseline does instead | Why safe to omit at first |
|---|---|---|---|
| **Monotonic ticket numbering** | `land-resolution.sh` allocates new numbers above a persisted high-water mark — deleting the top ticket then filing a new one leaves a gap | `this-file max + 1` — reuses a number if the previous top ticket was just deleted | Id reuse only bites when an in-flight PR references a now-recycled number; rare below high churn |
| **Tolerant PR-head matching + same-run adoption** | `find_pr` tries exact `ticket-N` head, falls back to a tolerant regex, adopts a PR opened earlier in the same run | exact-head only (`--head "ticket-N"`) | A worker naming its branch exactly `ticket-<N>` (required) is always found by exact match |
| **Tolerant worker-report extraction** | pulls the last balanced `{…}` object carrying `status` out of arbitrary text | whole final message must `jq`-parse as one object | A compliant worker emits only the JSON object; tolerance only rescues a drifting worker |
| **Run-start preflight-main reconcile** | `preflight-main.sh` reconciles every repo onto clean `main` before a run | no preflight; trusts the checkout is on `main` | main-on-main SessionStart hook already warns on drift |
| **Run-scoped worker logs** | `GOVERN_RUN_DIR` isolates each run's worker logs | flat per-ticket log paths | Stale-log confusion only appears across many re-runs of the same ticket |

The self-improvement lane (`govern-improve.sh` / `govern-self-apply.sh`) was retired outright rather
than kept leaner: `governor/improvements.md` in this baseline is operator-maintained notes on harness
friction, with no automated observe→propose→apply pipeline behind it. Port rows above as their own
template PRs to track the full harness; otherwise this table is the record of what's deliberately
left out.

## Skill location

`~/.claude/skills/shiploop/`. Templates for everything above are under `templates/` — `lib/workspace.sh`
(config contract), core workspace scripts, `worktree/`, `govern/`, `governor/` (prompt scaffolds),
`hooks/`, `seed/`.
