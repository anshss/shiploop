# <workspace> (meta-repo)

A **meta-repo**: a workspace root holding N independent git repos as sub-folders, each with its own
remote, PR queue, and CI. The root is also its own git repo, holding workspace config, cross-cutting
scripts, the ticket queue, the governor, and shared AI context.

> This file is the workspace's **always-on context** — it auto-loads every session, so it is the home
> for the conventions below. Keep it current; it is the first thing a new session (human or agent) reads.
>
> **Keep this file the lean, always-loaded hard-rules core.** Because it is re-sent every turn, every
> line here has a standing per-turn cost — so it should hold only the load-bearing rules a session must
> never miss. As durable detail accumulates (deep provider notes, long gotcha writeups, historical
> context), don't let the core bloat: overflow it into a sibling **`CLAUDE-APPENDIX.md`** and reference
> that file from here. The core stays scannable; the appendix carries the depth, loaded on demand.

## How to operate (read first)

1. **Any task that will touch code → start with `npm run worktree:new -- <task-slug>` and `cd` into
   it.** The main checkout is read / plan / main-branch-ops only — never edit code there. A worktree is
   an isolated copy (own branches, own dev stack, own ports, own SessionEnd cleanup) so parallel
   sessions don't collide. Clean up with `npm run worktree:rm -- <slug>` after PRs merge. The only
   exception is purely read-only work (explain / "where is X").

2. **Default to the full local loop for non-trivial work** (`npm run dev`), and validate through the
   real UI/API path a user touches — not a shortcut that skips the layers where bugs hide.

3. **Offload context-heavy sub-tasks to subagents** (a diagnosis, a codebase sweep, a multi-file
   investigation) so this session's context stays flat — the subagent's logs stay in its context; only
   the conclusion returns to yours. Reserve the main session for orchestration + decisions.
   **When you delegate, also SIZE THE MODEL** — children do NOT need this session's model. Rough
   guide: `haiku` = mechanical/extract/lookup/URL-fetch · `sonnet` = search/investigation/multi-file
   reads/standard edits/verify votes · inherit (the session model / `GOVERN_WORKER_MODEL`) only for
   judgment-heavy synthesis / architecture / final review / hard tickets. A fan-out (N similar
   children) is almost never inherit-tier. Escalation valve: on a cheap-tier failure, retry once on
   the stronger tier — never the reverse. Same guide applies when filing a ticket that carries a
   `Model:` field (see `queue/tickets.md`).

4. **When an issue is reported conversationally, default to investigate → file → ask, not
   file-and-drop.** Confirm it's real and locate the root cause first (delegate if context-heavy), THEN
   file the ticket with that evidence, THEN ask whether to start fixing now. File a bare uninvestigated
   ticket only when explicitly told to just track it for later.

**Capture learnings at natural breakpoints — don't wait to be asked.** Route findings by **stability**,
not topic:

| Where | Use when |
|---|---|
| **`queue/tickets.md`** (root) | **Work items only** — bugs, gaps, missing capabilities, follow-ups; anything to fix/build later. Each is its own numbered `## #N` block. **Isolation** — the queue admits exactly TWO scopes: the current project's sub-repos and the harness itself. Any tool/skill/product EXTERNAL to those two must NEVER file a ticket here, even when invoked from this workspace's terminal; its follow-ups go to its own tracker. |
| **`CLAUDE.md`** (root or sub-repo) | Stable, reusable patterns — env vars, conventions, architecture, persistent gotchas. Home for the durable lesson from a fixed bug. |
| **`learnings.md`** (root or sub-repo) | Only transient/evolving operational knowledge not yet stable enough for `CLAUDE.md` ("X provider flaky this week"). **Never** a work item (→ tickets) and **never** a fixed-bug writeup (→ promote or delete). |
| **Project memory** (`~/.claude/projects/<encoded-workspace-path>/memory/`) | Strategic cross-session context — product direction, durable preferences. The memory dir is fronted by a `MEMORY.md` index — a list of one-line `[title](file.md) — gist` links pointing at per-topic note files; add the link when you add a note so it stays discoverable. |

Bar: would knowing this save a future session 5+ min? If yes, propose the edit and ask before ending
the session. **At session start, skim `learnings.md` (root + the sub-repo you're in)** — the
SessionStart hook auto-prints only the **root** `learnings.md`, so when working inside a sub-repo you
must open that sub-repo's `learnings.md` yourself.

## The CLAUDE.md hierarchy

- **Root `CLAUDE.md`** (this file) — cross-repo orchestration only: how to operate, the ticket/learnings
  routing above, the sub-repo map, and the load-bearing anti-patterns.
- **Sub-repo `CLAUDE.md` wins in its scope.** Inside a sub-repo, that repo's `CLAUDE.md` is the source
  of truth for its own patterns. The root file is cross-repo only — don't duplicate sub-repo content
  here, and don't put cross-repo orchestration in a sub-repo file.
- The same split applies to `learnings.md` (a root one for cross-repo discoveries, a per-sub-repo one
  for repo-local transient knowledge).

## Sub-repos

The sub-repo list + dev commands + ports are a single source of truth: `scripts/lib/workspace.sh`.
Adding/removing a sub-repo is a one-file edit there.

| Folder | Remote | Stack | Port |
|--------|--------|-------|------|
| `<repo>/` | `<org>/<repo>` | `<stack>` | `<port>` |

## Operating commands

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos (`-- --only a,b` to scope); tee output to `logs/<name>.log` |
| `npm run dev:<name>` | Boot one sub-repo |
| `npm run status` | Branch / dirty / ahead / behind / PR# / CI per repo |
| `npm run doctor` | Health audit: tooling, env, ports, repo presence |
| `npm run branch -- <name>` | Create a branch across repos (`--only a,b` to scope) |
| `npm run switch -- <name>` | Checkout a branch across all (tracks origin if local missing) |
| `npm run pull` / `npm run push` | `git pull --ff-only` per repo / push changed repos + open PRs |
| `npm run health` | curl each dev server |
| `npm run worktree:new -- <slug>` | Allocate a slot; create isolated worktrees on branch `<slug>` |
| `npm run worktree:rm -- <slug>` | Clean up + remove a worktree, free its slot |
| `npm run govern` | Launch the autonomous ticket loop (or `/govern`) |

**Pass args/flags after the script with `--`** — `npm run worktree:new -- <slug>`, `npm run dev -- --only console`. (npm and pnpm need the `--`; yarn classic tolerates it. Commands here use `npm run` — substitute your root PM if it differs.)

## Anti-patterns (load-bearing)

1. **MCP servers always at workspace root.** Never `claude mcp add` from a sub-repo.
2. **`cd` into the sub-repo before committing.** `git add` from root won't stage sub-repo files; each
   commits independently.
3. **Never assume sub-repos share a branch.** They drift. Run `npm run status` first.
4. **Verify which sub-repo you're in before destructive git** (`reset --hard`, `clean -fd`, `branch -D`).
5. **PRs aren't transactional across sub-repos — merge backend-first.** When the backend adds a
   capability the frontend consumes (enum, endpoint, response field), the backend PR merges + deploys
   before the frontend PR. State the merge order in each sibling PR.
6. **`.env.example` is the contract.** Never commit `.env`. `doctor` checks each `.env` exists.
7. **One package manager at the root — never two.** The root PM is set in `scripts/lib/workspace.sh`
   (`ROOT_PM` = npm/pnpm/yarn/bun); the root scripts are PM-agnostic bash aliases. Don't mix two PMs at
   the root — a stray second root lockfile diverges (the `.gitignore` guards against this). Sub-repos
   keep their own package manager independently.
8. **Main checkout stays on `main`, every repo, always. Branch work only in worktrees.** Meta-repo
   coordination files (`CLAUDE.md`, `queue/tickets.md`, `learnings.md`, `scripts/`) commit directly to `main`
   in the main checkout — never branched/PR'd.
9. **PR opened → tear the local stack down.** Don't leave dev servers idling (zombies hold ports → next
   `dev` serves stale code on `EADDRINUSE`).
10. **The driver session neither READS nor edits product source — reading is the bigger sin.** Every
    `Read` of a source file becomes permanent driver-context cargo, re-sent to the model on every later
    turn for the rest of the session; a few "minor" inline fixes cost more in re-read context than
    they're worth. Triage review findings and tickets from their text alone; dispatch any fix — however
    small — to a fresh headless worker or subagent briefed with the finding + branch, and relay only its
    verdict (pass/fail + PR state). The driver's lane is: orchestrate, merge, verify via terse command
    output, and bookkeep coordination files (`queue/`, `governor/`, `CLAUDE.md`) — those it may read and
    edit freely.

> Replace the `<…>` placeholders and the Sub-repos table with your workspace's specifics, then append
> your own conventions, gotchas, and architecture notes below as you learn them.
