---
description: Launches the ticket governor: grinds tickets via right-sized workers, guarded auto-merge, flat context.
allowed-tools: Bash, Read
---

# /shiploop:govern

> **Workspace-local override:** if `.claude/commands/govern.md` exists in this workspace, follow
> THAT file instead — it is the live, locally-improved copy; this global copy is the fallback for
> un-scaffolded workspaces.

Launch the governor — a **pure-bash driver** (`scripts/govern/run-loop.sh`) so this session's context
stays flat. Claude runs only in fresh, bounded sub-sessions: the per-ticket **worker** and a periodic
**supervisor**.

`$ARGUMENTS`:

| Argument | Effect |
|---|---|
| *(empty)* | The whole eligible backlog — one ticket at a time, or N at a time if `GOVERN_PARALLEL_DEFAULT=N` |
| `<N>` | That one ticket only — always sequential |
| `<N> <N> <N>` | Exactly that ticket set, in severity order |
| `--parallel[=N]` | Work up to N tickets concurrently; bare `--parallel` uses the workspace default cap (else 4) |
| `--serial` | Force one ticket at a time (`--parallel=1` is identical) |
| `--dry-run` | Prove it, ship nothing |
| `--exclude N,N` | Skip these tickets (e.g. another govern session owns them) |

**Concurrency.** Default is sequential; `GOVERN_PARALLEL_DEFAULT=N` in `scripts/lib/workspace.sh` (or
`--parallel[=N]` per run) makes the driver an orchestrator: for a backlog pull it spawns **N full
backlog drivers**, each grinding the queue and contending on the per-ticket claim lock — the "launch N
terminals" recipe, automated. Each child is an ordinary sequential driver, so every backlog mechanism
(dependency gate, failure streak, periodic supervisor, bad-streak breaker) keeps working inside it. An
explicit ticket set instead spawns one single-ticket child per named ticket. Safety is unchanged: the
per-ticket claim lock + bookkeep lock make concurrent drivers exactly-once safe. Hard bounds are
**per driver** — a parallel backlog run's ceiling is N × `GOVERN_MAX_TICKETS`, and N concurrent workers
cost N× the spend.

**Locality batching (`GOVERN_BATCH_MAX`, default `1` = off).** Concurrency governs how many workers run
at once; batching governs how many tickets each one takes. `GOVERN_BATCH_MAX=N` groups up to N
same-area tickets (keyed on the leaf directory of `Files:`/`Where:`) into ONE worker — it explores
once and opens ONE PR (per-ticket commits), since exploration is the dominant cost of a resolved
ticket (~98% cache reads). Groups are disjoint by construction (also what stops two concurrent drivers
racing the same file) and never co-batch two tickets in a dependency relation. Every ticket in a group
is claim-locked; a batched ticket is bookkept only on an explicit per-ticket `resolved` in the
worker's `tickets` array. Backlog pulls only. See `governor/README.md` for full semantics.

The **run-start reconcile** (apply escalation answers → regenerate `pending-escalations.json` →
`preflight-main.sh` → externalization lane → NA-skip streak bookkeeping) runs ONCE, in the
orchestrator, before spawning anything, while it holds the single-run lock — it's whole-run state
reconciliation against the one shared meta checkout. Each child gets the internal `--orchestrated`
flag and skips it (logs `run-start reconcile: skipped`). Never pass `--orchestrated` by hand.

Precedence, highest first: `--serial` › `--parallel=N` › bare `--parallel` › `GOVERN_PARALLEL=N` ›
`GOVERN_PARALLEL_DEFAULT` (unset/1 = sequential; a named target-set size caps it). A resolved cap of 1
from any source means the whole backlog one ticket at a time — never "one ticket then quit".

Run from the **main checkout** (not a worktree), in a **plain terminal** — NOT inside an interactive
Claude session. A nested `claude -p` inherits the parent's `CLAUDE_CODE_*` env and the headless worker
never finalizes (answers but emits no `result`, hangs to timeout). `spawn-worker.sh` scrubs those vars
defensively so the loop survives a nested launch, but your manual preflight ping below won't — run it
(and ideally the whole loop) from a real terminal.

## Before a live run (once)
Workers authenticate via subscription OAuth — confirm a child `claude` can auth (plain terminal):
```bash
claude -p "ping" --model sonnet --strict-mcp-config   # should print "pong"-ish text, NOT a 401
```
`--strict-mcp-config` matches how workers actually launch (no MCP servers). 401 → `claude login` in
this shell first (don't set `ANTHROPIC_API_KEY` unless you want the API-key fallback). Hangs with no
output → you're nested inside a Claude session; open a real terminal.

Also confirm `governor/preferences.md` reflects your doctrine and `GOVERN_MERGE_REPOS` in
`scripts/lib/workspace.sh` lists exactly the repos safe to auto-merge.

## Trust ladder (`GOVERN_AUTONOMY`)
One knob sets how far the governor goes on its own. Graduate up a rung as you trust the loop:

| `GOVERN_AUTONOMY` | Workers do the work + push `ticket-<N>` | Open a PR | Governor merges |
|---|---|---|---|
| `observe` | yes | **draft** PR (visible, inert) | never |
| `pr-only` (default) | yes | normal PR | never (a human merges) |
| `auto` | yes | normal PR | auto-merges allowlisted repos on green-or-no-checks CI |

Start at `observe` to watch output before anything lands on `main`. Move to `pr-only` once drafts look
right. Flip to `auto` when you trust it — governor merges allowlisted-repo PRs itself.

Backward compat: a workspace scaffolded before the ladder existed has no `GOVERN_AUTONOMY` line and
behaves as `auto` (unchanged). Add the line to opt into a lower rung.

## Run it
```bash
scripts/govern/run-loop.sh $ARGUMENTS
```
Relay its log lines as they appear. The driver does everything — select → spawn → CI → merge →
bookkeep → supervise → escalate — deterministically.

## What you (this Claude session) do
- **Launch** `run-loop.sh` and report progress + the final `resolved / parked / failed` tally.
- **Surface + ANSWER escalations** when it finishes:
  1. Read `governor/pending-escalations.json` (driver writes it at run-end). `count: 0` → nothing
     needed, just summarize.
  2. Present **ALL** pending escalations in a **single batched `AskUserQuestion` call**
     (4-questions-per-prompt limit → one entry per question; `count > 4` → chunk into
     ceil(count/4) calls). For each entry use its `question` + `options`, and ALWAYS include: **Do
     the work** (un-park → governor retries), **Defer / keep-manual** (auto-moves to
     `tickets-parked.md`), **Keep open** (decide later).
     - Don't fragment asks across a phased run — a single whole-backlog invocation (or deferring
       surfacing to the final phase) keeps a run's blocked tickets in one batched ask.
     - **By design:** the headless driver can't pause mid-run for an answer, so any answer applies at
       the NEXT run-start (`escalations-apply-answers.sh`). That two-run drain (run → answer → re-run)
       is expected.
  3. Write the answer into `governor/escalations.md` under that `### #N` entry via
     `scripts/govern/record-escalation-answer.sh <N> --answer "<their words>" --disposition <token>
     [--rule "<rule text>"]` (`<token>` = `do-the-work` | `defer` | `mitigated` | `keep-open`). Run
     once per answered ticket.
  - The NEXT `run-loop.sh` start applies these automatically (un-park / migrate-to-parked / append rule
    to `preferences.md`) — you only record the answers.
- **Do NOT re-implement the loop in-context.** If the driver halts (circuit breaker / supervisor
  halt), report the reason; don't take over.

## Policy (enforced by the scripts, not by you)
- Sequential by default; `GOVERN_PARALLEL_DEFAULT=N`/`--parallel[=N]` fans out; `--serial` forces
  one-at-a-time. Auto-merge only `GOVERN_MERGE_REPOS` on green-or-no-checks CI; every other repo is
  PR-only. `observe`/`pr-only` never auto-merge; only `auto` does.
- Hard-stops (destructive git; prod data / destructive schema / secrets) and doctrine gaps → worker
  **parks** → escalation.
- Additive prod migrations auto-apply only if `GOVERN_MIGRATE_CMD` is configured (else park); destructive
  migrations always park.
- Supervisor every `GOVERN_SUPERVISOR_EVERY` (default 5) resolved tickets + on anomaly, **per driver**,
  plus two out-of-loop passes (`GOVERN_SUPERVISOR_FLUSH=0` disables both): a **run-tail flush** (one
  pass at end-of-loop for a driver's 1..N-1 unreviewed resolves, so the tail is never skipped) and a
  **whole-run pool review** (one pass over the aggregated `state.jsonl` after all children are reaped,
  in the `--parallel` orchestrator). The per-driver cadence is NOT scaled down by the fan-out — N
  drivers each firing every `SUP_EVERY` of their own resolves already totals ≈K/`SUP_EVERY` passes
  globally; dividing by N would over-fire ~N×. What parallel loses is the per-driver tail (a 12-ticket
  backlog split 3-per-driver across 4 drivers hits the periodic pass zero times vs twice
  sequentially) — the tail flush restores that, and the pool review adds the whole-run view.
- Single-run lock (`governor/.govern.lock`); resumable — resolved tickets are deleted from
  `queue/tickets.md`, parked ones skipped via `escalations.md`, an existing `ticket-<N>` PR reused.
- Hard bounds so a run always ends: `GOVERN_MAX_TICKETS` (20), `GOVERN_MAX_BAD_STREAK` (4),
  `GOVERN_MAX_RUNTIME` (0 = no cap by default), `GOVERN_WORKER_TIMEOUT` (1h, stuck worker killed),
  `GOVERN_WORKER_MAX_TOKENS` (0 = unlimited by default; wandering worker killed on budget cross,
  recorded as `budget-exceeded`).
- Progress-preserving: only resolved worktrees are torn down; failed/parked/timed-out worktrees are
  kept. Every exit writes `logs/govern/run-*/summary.md`.
