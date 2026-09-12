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

3. **This session is the advisor: it decides, it does not implement. Nothing ever spawns an advisor.** Reason the change out, write
   it into the ticket as its `**Proposed solution:**`, then hand that to a `worker` subagent, which
   implements it and ends at PR-open plus a report. The worker is a subagent so it can message you
   back mid-run and you can steer it: that two-way channel is the whole reason for the shape. Your
   steers are capped (`GOVERN_STEER_CAP`); past the cap, rewrite the proposal and dispatch again.
   **Never read or edit product source here.** Every inline `Read` is permanent context cargo,
   re-sent every later turn. Delegate and relay only the verdict. Coordination files (`queue/`,
   `governor/`, `CLAUDE.md`, `learnings.md`) are free to read and edit here. **Route by shape:**

   | shape | route |
   |---|---|
   | a `## #N` ticket exists, or the user names tickets | `Agent(subagent_type: "worker")`, one per ticket |
   | heavy but not ticket-shaped (investigation feeding an answer) | `Agent`, sized per the table below |
   | trivial | inline |
   | a worker failed once | retry once with `model: opus`, then stop and report |

   **Size the child:** `haiku` = mechanical/lookup · `sonnet` = search/investigate/standard edits ·
   inherit only for judgment-heavy synthesis or final review. Never size a ticket when filing one —
   the scout measures that.

   **A worker ends at PR-open plus report.** Landing it is your last step: pipe that report into
   `npm run govern:resolve -- <N>`, which awaits CI, merges, and edits the queue file. A ticket's
   queue block is never deleted before merge.

4. **Issue reported in conversation → investigate → answer → file at the checkpoint** (Stop-hook sweep
   or an explicit "file this"). A discussion turn ends with the finding, not a new `## #N`.

## Ask before you spawn, never after

**Put the dispatch to the operator before it runs, not after.** Name what you will dispatch, to which
agent type, and what it will change. A child already running turns a decision into a fait accompli:
the only question left is whether to kill it, which is not the question the operator should be
answering.

**A child inherits none of your instructions.** Every constraint you were given, pass down explicitly:
which tree it may touch, what it may not delete, which git commands are forbidden, the standing rules.
A fan-out you did not specify is a fan-out you cannot constrain, and it writes under your name.

## Never answer from assumption

**Read the code before you state how it behaves.** A claim about behavior is earned by opening the
file, not by reading a name, a default value, a comment, or one side of a contract. If you have not
read it, say "I have not checked" and go check: an unverified answer stated plainly is worse than no
answer, because it gets acted on. Never relay a delegate's conclusion as fact without opening the
primary source yourself, and when the operator tells you how something works, that REPLACES your
model of it rather than merging into it.

**Comments never cite documents.** A comment states what the code does and why. It never points at a
spec, a design doc, a ticket number, or a lettered decision: those get moved and deleted, and a
pointer that no longer resolves sends a reader off to invent the answer. If the rationale matters,
write the rationale.

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

1. **PRs aren't transactional across sub-repos: merge backend-first**, and state the order in each
   sibling PR.
2. **`.env.example` is the contract.** Never commit `.env`: nothing enforces this mechanically.
3. **Coordination files commit directly to `main` in the main checkout** (`CLAUDE.md`, `queue/`,
   `learnings.md`, `scripts/`) — never branched or PR'd. Branch work belongs in worktrees.
4. **PR opened → tear the local stack down.** Zombie dev servers hold ports and serve stale code.

**Six rule packs are delivered JUST-IN-TIME by `scripts/rules-on-touch.sh` (PreToolUse), not resident
here**: `shell` · `worklist` · `git` · `pr` · `release` · `govern`. They fire when you touch that surface,
in workers too (a delegate never loads this file). Assume they exist; read the script if you need one
early. Long forms: `CLAUDE-APPENDIX.md`. Compress more of this file with `/shiploop:compress`.

> Replace the `<…>` placeholders and the Sub-repos table with your specifics, then append your own hard
> rules here and reference material to `CLAUDE-APPENDIX.md`. Also in the appendix: MCP servers always
> at workspace root · one root package manager, never two · why the driver doesn't read source.
