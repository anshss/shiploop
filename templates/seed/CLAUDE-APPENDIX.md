# <workspace> — appendix

**This is the DEFAULT sink for durable knowledge.** `CLAUDE.md` is re-sent to the model on every turn;
this file costs nothing until a session actually opens it. So a lesson lands *here* unless it has
earned the always-on slot — the core stays scannable and cheap, the depth lives here. When a
`CLAUDE.md` rule grows a paragraph of justification, the rule stays there and the paragraph moves here.

Read this file when you need the *why* behind a rule, the full command reference, or a deep gotcha
writeup. Append freely — there is no length budget on this file.

**What earns the always-on slot in `CLAUDE.md` instead: frequency × severity, never frequency alone.**
Something that fires rarely still earns it when missing it fails *silently* or *irreversibly* (a
command that reports success while changing nothing). Something that fires often but fails loudly and
recoverably does not — you will rediscover it in one turn. Take the cheapest rung that works: make it
impossible (a guard) > make it caught (a lint or a test) > make it retrievable (**here**) > make it
always-on. A promotion into `CLAUDE.md` at budget should also name what it *displaces*: without an
eviction, "is this useful?" is always yes, and the always-on file only ever ratchets upward.

**This file is not a rot reservoir.** Moving a line here fixes COST, never WRONGNESS — a wrong line
parked here is still wrong, it has just gone from *injected always* to *retrieved unpredictably,
reviewed never*. Rot has exactly three fixes: be right, supersede in place, delete. None of them is a
move. So entries here carry the same discipline as `learnings.md`: write **observations, not
recommendations**, keep the **date, source, and n** that make a claim checkable, **rewrite** an entry
when you re-measure it rather than appending a second one beside it, and if something cannot be made
self-correcting and does not clear the bar, **delete it rather than demote it**.

---

## Operating commands (full)

| Command | Purpose |
|---------|---------|
| `npm run dev` | Boot all sub-repos (`-- --only a,b` to scope); tee output to `logs/<name>.log` |
| `npm run dev:<name>` | Boot one sub-repo |
| `npm run doctor` | Health audit: tooling, env, ports, repo presence |
| `npm run sync` | Pull/rebase every sub-repo onto its origin `main`, pruning dead branches |
| `npm run tail` | Tail sub-repo dev logs, interleaved and prefixed by name |
| `npm run worktree:new -- <slug>` | Allocate a slot; create isolated worktrees on branch `<slug>` |
| `npm run worktree:rm -- <slug>` | Clean up + remove a worktree, free its slot |
| `npm run worktree:status` | List allocated worktree slots |
| `npm run worktree:exec -- <slug> [-- <cmd>]` | Run a command with that slot's env |
| `npm run worktree` | Worktree dispatcher (`new` / `rm` / `status` / `exec`) |
| `npm run govern -- <N> ...` | Dispatch the tickets you name (or just say "work on 42 51") |
| `npm run govern:health` | Governor health audit |
| `npm run govern:dry-run -- <N>` | Rehearse one ticket end to end, nothing merged or committed |
| `npm run govern:audit` | Manual run audit, zero model spend unless invoked |
| `npm run govern:budgets` | Enforce context budgets outside a dispatch (`--dry` to preview) |
| `npm run govern:trim` | Evidence-based CLAUDE.md trim: auto-move provably dead or duplicate blocks, propose the rest |
| `npm run govern:externalize` | File open Low-severity tickets as public issues (no-op until opted in) |
| `npm run govern:validations` | Run the governor validation suite |

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

## Two lanes, one worker

A **worker** is the trim, single-ticket session that resolves one `## #N` end to end and opens one
PR. There are two ways to start one, and both run the same doctrine file,
`governor/worker-prompt.md`:

- **Interactive lane:** `Agent(subagent_type: "worker")` from a live session. The scaffolded
  definition at `.claude/agents/worker.md` pins the model and the tool set in frontmatter (so
  right-sizing is not left to judgment) and points at the canonical doctrine rather than restating
  it. The run shows up in the session UI with live token counts and an openable transcript, and its
  structured report comes back to the driver.
- **Autonomous lane:** `npm run govern -- <N> ...`, or just say "work on 42 51". Same doctrine,
  headless, plus the full gate stack: dependency ordering, cross-driver re-verify, failure-streak
  escalation, merge, and queue bookkeeping.

Anything else you spawn with the `Agent` tool is a **subagent**, never a worker. The distinction is
load-bearing rather than cosmetic: `worker` is a literal string in the call, so a routing rule that
says "worker" cannot be satisfied by a generic spawn that merely feels worker-like.

**Why the interactive lane stops at PR-open.** Merge, the CI await, the park-on-red-CI recovery path
and the queue edit all live in govern's run loop, and a session that merged its own PR would bypass
every one of them. Dispatching `npm run govern -- <N>` once the PR is open adopts that PR instead of
redoing the work, so the two lanes compose rather than duplicate.

**Why the worker makes its own worktree.** The `Agent` tool's `isolation: "worktree"` worktrees the
root repo only, and a meta-repo's nested sub-repo `.git` directories do not come along, leaving a
tree that cannot commit or push. `npm run worktree:new -- t<N>` allocates the real thing.

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

Two optional digest gates, both **off** by default:

- `SHIPLOOP_LEARNINGS_TTL=1` degrades an entry older than `SHIPLOOP_LEARNINGS_TTL_DAYS` (default 14)
  to a **title-only** line. Not a delete — a still-true measurement that vanishes just gets re-derived
  at full cost by a future session.
- `SHIPLOOP_LEARNINGS_LINT=1` prints one line when `learnings.md` is structurally broken (a heading
  with no body, or body text orphaned before the first heading) and stays silent when it is healthy.
  The digest slices the file at headings, so appending an entry *between* a heading and its body
  injects a garbled fragment into every session until someone notices.

Be aware of what the ranking actually is: entries are ordered by the date **typed into the heading** —
a self-report about when someone wrote it, not evidence that it is still true — with same-date ties
broken by file position. That ranking can promote an entry into every session forever and can never
demote one, which is why the TTL exists and why re-measuring means **rewriting the entry in place**.

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

## Fleet visibility — seeing what the governor is actually doing

Governor workers are detached `claude -p` processes. Their pid lives only in a bash array inside
`run-loop.sh`, and structured state is written only at completion — so while a run is in flight
nothing on disk says "running". Claude's own subagent panel cannot help: it renders Task-tool
children of *this* session, and there is no way to inject a row into it from outside.

`GOVERN_EVENTS=1` turns on one append-only log, `governor/events.jsonl`, and everything else folds
it. Off by default; nothing about a run changes when you enable it, and a failed append is swallowed
rather than aborting the run.

| Want | Run |
|---|---|
| A snapshot, right now | `npm run govern:status` (add `--json` for machines) |
| It in the statusline | `/shiploop:statusline` — opt-in, and it **wraps** your existing statusline rather than replacing it |
| Live notifications in-session | Nothing: the shiploop plugin's monitor already tails the log and reports state transitions |

Three things worth knowing before you go looking for a bug in it:

- **A "live" worker in the log is a claim, not a fact.** A killed driver or a `pkill claude` leaves a
  `worker_spawned` with no matching `worker_done` forever. Every reader arbitrates with `kill -0`;
  `govern:status` additionally appends a synthetic `status:"stale"` row so the log self-heals.
- **The fold is last-event-wins per (run_id, ticket)**, not spawned-minus-done. A retry is
  spawn → done → spawn, and a subtraction would call that ticket idle.
- **The monitor is deliberately stingy.** Every line it prints becomes a notification in the driver's
  context — the exact resource shiploop exists to conserve. It emits transitions only, dedupes, caps
  at `GOVERN_MONITOR_MAX_PER_MIN` (6) per minute, and never replays history. If you want the raw
  stream, `tail -f governor/events.jsonl` yourself; do not make the monitor chattier.

---

## Workspace-specific notes

_(append your own architecture notes, provider gotchas, and rule rationale below)_
