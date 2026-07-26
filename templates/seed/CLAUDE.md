# <workspace> (meta-repo)

A **meta-repo**: a workspace root holding N independent git repos as sub-folders, each with its own
remote, PR queue, and CI. The root is also its own git repo, holding workspace config, cross-cutting
scripts, the ticket queue, the governor, and shared AI context.

> **This file is re-sent to the model on every turn.** It holds hard rules only — the things a session
> must never miss. Rationale, reference tables, and long gotcha writeups go in `CLAUDE-APPENDIX.md`,
> which is read on demand. When you add something here, ask whether every future turn should pay for
> it; if not, it belongs in the appendix.

## How to operate

1. **Code work → `npm run worktree:new -- <slug>`, then `cd` into it.** The main checkout is
   read/plan/main-branch-ops only. Clean up with `npm run worktree:rm -- <slug>` after PRs merge.
   Read-only work (explain / "where is X") is the only exception.

2. **Validate through the real path** (`npm run dev`) — the UI/API route a user actually touches, not a
   shortcut that skips the layers where bugs hide.

3. **The driver session orchestrates; it does not read or edit product source.** Every inline `Read`
   becomes permanent context cargo, re-sent every later turn. Delegate any investigation, sweep,
   diagnosis, build, or fix — however small — to an `Agent`, and relay only its verdict. The driver may
   freely read and edit coordination files (`queue/`, `governor/`, `CLAUDE.md`, `learnings.md`).
   **Size the child:** `haiku` = mechanical/extract/lookup · `sonnet` = search/investigate/standard
   edits · inherit only for judgment-heavy synthesis, architecture, or final review. A fan-out of N
   similar children is almost never inherit-tier. On a cheap-tier failure retry once higher — never the
   reverse. Same guide applies to a ticket's `Model:` field.

4. **Issue reported in conversation → investigate → answer → file at the checkpoint.** Confirm it's
   real and locate the root cause first; a discussion turn ends with the finding, not a new `## #N`.
   File at the session's bookkeeping checkpoint (Stop-hook sweep, `/resolve`, or an explicit "file
   this"). **Consolidate by default** — fold the finding into an open ticket unless it is independently
   dispatchable; two tickets one worker would fix in one PR should have been one ticket. A filing
   correction from the operator is a standing constraint for the rest of the session, not a one-off.

## Where knowledge goes

Route by **stability**, not topic. Each destination has a different cost: `CLAUDE.md` is paid every
turn, the rest are paid only when read.

| Where | Use when |
|---|---|
| **`queue/tickets.md`** | **Work items only** — anything to fix or build later, one `## #N` block each. Admits exactly two scopes: this workspace's sub-repos and the harness. Anything external files in its own tracker. |
| **`CLAUDE.md`** (root or sub-repo) | Stable hard rules a session must never miss. Sub-repo file wins in its own scope; root is cross-repo only. |
| **`CLAUDE-APPENDIX.md`** | The same durable knowledge when it's reference rather than rule — command tables, deep provider notes, the *why* behind a rule. |
| **`learnings.md`** (root or sub-repo) | Transient/evolving knowledge only ("X provider flaky this week"). Never a work item, never a fixed-bug writeup. |
| **Project memory** (`~/.claude/projects/<encoded-path>/memory/`) | Strategic cross-session context — product direction, durable preferences. Add a line to its `MEMORY.md` index. |

Bar: would knowing this save a future session 5+ min? Propose the edit before ending the session. The
SessionStart digest surfaces only the **root** `learnings.md` — open a sub-repo's own file yourself.

## Sub-repos

Single source of truth for the repo list, dev commands, and ports: `scripts/lib/workspace.sh`.
Adding or removing a sub-repo is a one-file edit there.

| Folder | Remote | Stack | Port |
|--------|--------|-------|------|
| `<repo>/` | `<org>/<repo>` | `<stack>` | `<port>` |

## Commands

`npm run dev` · `status` · `doctor` · `worktree:new -- <slug>` · `worktree:rm -- <slug>` · `govern`.
Full table with flags: `CLAUDE-APPENDIX.md`, or `npm run` to list. **Pass args after `--`.**

## Anti-patterns (load-bearing)

1. **MCP servers always at workspace root.** Never `claude mcp add` from a sub-repo.
2. **`cd` into the sub-repo before committing.** `git add` from root won't stage sub-repo files.
   Corollary: `git status` at the root proves nothing about sub-repo state.
3. **Never assume sub-repos share a branch.** They drift — run `npm run status` first.
4. **Verify which sub-repo you're in before destructive git** (`reset --hard`, `clean -fd`, `branch -D`).
5. **Never `git stash` to A/B a baseline** — the edits usually live in a nested sub-repo, so a
   root-level stash is a silent no-op that yields a worthless "baseline". Use a throwaway
   `git archive HEAD | tar -x -C "$(mktemp -d)"` export instead.
6. **PRs aren't transactional across sub-repos — merge backend-first**, and state the merge order in
   each sibling PR.
7. **`.env.example` is the contract.** Never commit `.env`.
8. **One package manager at the root — never two.** Set via `ROOT_PM` in `scripts/lib/workspace.sh`.
9. **Main checkout stays on `main`, every repo, always.** Branch work only in worktrees; coordination
   files (`CLAUDE.md`, `queue/`, `learnings.md`, `scripts/`) commit directly to `main` there.
10. **PR opened → tear the local stack down.** Zombie dev servers hold ports and serve stale code.

> Replace the `<…>` placeholders and the Sub-repos table with your workspace's specifics, then append
> your own hard rules here and your reference material to `CLAUDE-APPENDIX.md` as you learn them.
