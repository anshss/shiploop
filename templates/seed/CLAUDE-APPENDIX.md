# <workspace> — appendix

Reference material and rationale for the hard rules in `CLAUDE.md`.

**This file is NOT auto-loaded.** `CLAUDE.md` is re-sent to the model on every turn, so anything parked
here costs nothing until a session actually opens it. That is the whole point of the split: the core
stays scannable and cheap, the depth lives here. When a `CLAUDE.md` rule grows a paragraph of
justification, the rule stays there and the paragraph moves here.

Read this file when you need the *why* behind a rule, the full command reference, or a deep gotcha
writeup. Append freely — there is no length budget on this file.

---

## Operating commands (full)

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos (`-- --only a,b` to scope); tee output to `logs/<name>.log` |
| `npm run dev:<name>` | Boot one sub-repo |
| `npm run doctor` | Health audit: tooling, env, ports, repo presence |
| `npm run worktree:new -- <slug>` | Allocate a slot; create isolated worktrees on branch `<slug>` |
| `npm run worktree:rm -- <slug>` | Clean up + remove a worktree, free its slot |
| `npm run worktree:status` | List allocated worktree slots |
| `npm run govern` | Launch the autonomous ticket loop (or `/govern`) |
| `npm run govern:health` | Governor health audit |
| `npm run govern:dry-run` | Governor dispatch plan without spawning workers |

**Pass args and flags after the script with `--`** — `npm run worktree:new -- <slug>`,
`npm run dev -- --only console`. npm and pnpm require the `--`; yarn classic tolerates it. Substitute
your root package manager if it isn't npm.

---

## Why the driver session doesn't read product source

Per-turn cost is proportional to the session's context size, which is re-sent **in full on every
turn**. A file read on turn 3 is still being paid for on turn 40. That makes an inline `Read` of a
large source file one of the most expensive things a driver can do — a few "quick" inline fixes can
cost more in re-sent context than the fixes were worth.

A subagent inverts this: its reads live in *its* context and die with it; only the verdict comes back.
The rule is therefore not about capability (the driver could obviously do the edit) but about where the
tokens accumulate.

**There is a floor as well as a ceiling — a subagent is not free.** Every child re-establishes context
from scratch, so delegating a one-line lookup costs more than doing it. The line is roughly: if the
answer needs more than one or two file reads, delegate; if you already know the file and line, don't.

---

## Why filing happens at a checkpoint, not mid-discussion

Filing a ticket the moment a gap is mentioned pre-empts the discussion twice over: it hijacks a thread
the operator opened in order to *think*, and it hands a half-formed problem statement to a future
governor run as authorized work. By the time the discussion reaches its natural checkpoint, it has
usually decided what the item actually is — often that it is part of an existing ticket, or not a
ticket at all.

The consolidation rule follows from the same place. A worker picks up one ticket and opens one PR;
two tickets that would resolve in a single PR cost a full extra dispatch — a fresh context, a fresh
branch, a fresh CI run — to produce the same diff.

---

## Learnings vs. CLAUDE.md vs. tickets

The three files fail in different directions when misused:

- A **work item** in `learnings.md` never gets scheduled — nothing reads that file looking for work.
- A **fixed bug** written up in `learnings.md` becomes archaeology: it describes a state of the world
  that no longer exists. Promote the durable lesson to `CLAUDE.md` or delete it.
- A **transient** note in `CLAUDE.md` is the expensive mistake — "provider X is flaky this week" is
  still being re-sent on every turn six months later, long after it stopped being true.

The SessionStart digest reads only the **root** `learnings.md`, and only the newest few entries. It is
tuned by `SHIPLOOP_LEARNINGS_MAX_ENTRIES` (default 3) and `SHIPLOOP_LEARNINGS_MAX_LINES` (default 40).
When working inside a sub-repo, open that sub-repo's `learnings.md` yourself.

---

## Rules that live here because something else already enforces them

These were hard rules in `CLAUDE.md` until a frequency audit moved them. Each fires rarely *and* has a
mechanical backstop, so paying for the prose on every turn bought nothing. They are still rules.

- **MCP servers always at workspace root.** Never `claude mcp add` from a sub-repo — the server ends up
  scoped to that sub-repo and is invisible from the root session where you actually work. Rare, and the
  failure is a visibly missing tool rather than silent corruption, so it is cheap to rediscover.

- **One package manager at the root — never two.** Set via `ROOT_PM` in `scripts/lib/workspace.sh`. The
  root `.gitignore` ignores the off-PM root lockfiles, so a stray second lockfile can't be committed
  and diverge. Sub-repos keep their own package managers independently; only the *root* is constrained.

- **The main checkout stays on `main`, every repo, always.** The `check-main-on-main.sh` SessionStart
  hook re-checks this at the start of every session and warns (non-blocking) if any repo has drifted,
  so the invariant is surfaced when it matters instead of being re-read every turn. The half of this
  rule that no hook covers — *coordination files commit directly to `main` here, never branched or
  PR'd* — stayed in `CLAUDE.md`.

The general test used for that audit: a rule earns its place in `CLAUDE.md` if it fires often, **or**
if violating it fails silently and unrecoverably (nobody consults an appendix before `reset --hard`).
Rules that are both rare and mechanically caught belong here.

---

## Workspace-specific notes

_(append your own architecture notes, provider gotchas, and rule rationale below)_
