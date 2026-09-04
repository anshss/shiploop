# <workspace> (meta-repo)

> **Re-sent to the model every turn — hard rules only.** Rationale, command tables, and gotcha
> writeups go in `CLAUDE-APPENDIX.md`, read on demand. Before adding a line here, ask whether a rule
> that fires a few times a week is worth every future turn paying for it. If not, it's appendix.

## How to operate

1. **Code work → `npm run worktree:new -- <slug>`, then `cd` in.** The main checkout is
   read/plan/main-branch-ops only. `npm run worktree:rm -- <slug>` after PRs merge. Read-only work
   (explain / "where is X") is the only exception.

2. **Validate through the real path** (`npm run dev`) — the UI/API route a user actually touches, not a
   shortcut that skips the layers where bugs hide.

3. **The driver orchestrates; it does not read or edit product source.** Every inline `Read` is
   permanent context cargo, re-sent every later turn. Delegate and relay only the verdict.
   Coordination files (`queue/`, `governor/`, `CLAUDE.md`, `learnings.md`) are free to read and edit
   here. **Route by shape:**

   | shape | route |
   |---|---|
   | a `## #N` ticket exists, or the user names tickets | `Agent(subagent_type: "worker")`, one per ticket |
   | multi-ticket batch, cron, or no session open | `npm run govern -- <N...>` |
   | heavy but not ticket-shaped (investigation feeding an answer) | `Agent`, sized per the table below |
   | trivial | inline |
   | a worker failed once | retry once with `model: opus`, then stop and report |

   **Size the child:** `haiku` = mechanical/lookup · `sonnet` = search/investigate/standard edits ·
   inherit only for judgment-heavy synthesis or final review. Never size a ticket when filing one —
   the scout measures that.

   **The interactive lane ends at PR-open plus report.** Merge, CI await and queue bookkeeping
   always go through govern: `npm run govern -- <N>` on an open PR adopts that PR instead of redoing
   the work. A ticket's queue block is never deleted before merge.

4. **Issue reported in conversation → investigate → answer → file at the checkpoint** (Stop-hook sweep
   or an explicit "file this"). A discussion turn ends with the finding, not a new `## #N`.
   **Consolidate by default:** two tickets one worker would fix in one PR should have been one ticket.

## Where knowledge goes

Route by **stability**, not topic. `CLAUDE.md` is paid every turn; everything else only when read.

| Where | Use when |
|---|---|
| **`queue/tickets.md`** | Work items only, one `## #N` each. Scope: this workspace's sub-repos and the harness — nothing external. |
| **`CLAUDE.md`** | Stable hard rules a session must never miss. Sub-repo file wins in its scope; root is cross-repo only. |
| **`CLAUDE-APPENDIX.md`** | Durable but reference, not rule — command tables, provider notes, the *why*. |
| **`learnings.md`** | Transient only ("X provider flaky this week"). Never a work item, never a fixed-bug writeup. |
| **Project memory** | Strategic cross-session context. Add a line to its `MEMORY.md` index. |

Bar: would this save a future session 5+ min? Propose the edit before the session ends.

## Sub-repos

Single source of truth for repos, dev commands, and ports: `scripts/lib/workspace.sh`. Adding or
removing a sub-repo is a one-file edit there.

| Folder | Remote | Stack | Port |
|--------|--------|-------|------|
| `<repo>/` | `<org>/<repo>` | `<stack>` | `<port>` |

## Commands

`npm run dev` · `doctor` · `sync` · `tail` · `worktree:new -- <slug>` · `worktree:rm -- <slug>` ·
`govern -- <ticket> ...` (named dispatch only; a bare `govern` prints usage).
**Pass args after `--`.** Full table with flags: `CLAUDE-APPENDIX.md`, or `npm run` to list.

## Anti-patterns (load-bearing)

1. **`cd` into the sub-repo before committing.** `git add` from root won't stage sub-repo files, and
   `git status` at the root proves nothing about sub-repo state.
2. **Never assume sub-repos share a branch.** They drift — check each sub-repo's `git status` first.
3. **Verify which sub-repo you're in before destructive git** (`reset --hard`, `clean -fd`, `branch -D`).
4. **Never `git stash` to A/B a baseline** — the edits usually live in a nested sub-repo, so a
   root-level stash silently no-ops and the "baseline" run is worthless. Use a throwaway
   `git archive HEAD | tar -x -C "$(mktemp -d)"` export.
5. **PRs aren't transactional across sub-repos — merge backend-first**, and state the order in each
   sibling PR.
6. **`.env.example` is the contract.** Never commit `.env` — nothing enforces this mechanically.
7. **Coordination files commit directly to `main` in the main checkout** (`CLAUDE.md`, `queue/`,
   `learnings.md`, `scripts/`) — never branched or PR'd. Branch work belongs in worktrees.
8. **PR opened → tear the local stack down.** Zombie dev servers hold ports and serve stale code.

> Replace the `<…>` placeholders and the Sub-repos table with your specifics, then append your own hard
> rules here and reference material to `CLAUDE-APPENDIX.md`. Also in the appendix: MCP servers always
> at workspace root · one root package manager, never two · why the driver doesn't read source.
