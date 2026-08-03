---
description: Launches the ticket governor: grinds tickets via right-sized workers, guarded auto-merge, flat context.
allowed-tools: Bash, Read
---

# /shiploop:govern

> **Workspace-local override:** if `.claude/commands/govern.md` exists in this workspace, follow
> THAT file instead — it is the live, locally-improved copy; this global copy is the fallback for
> un-scaffolded workspaces.

Launch the governor — a **pure-bash driver** (`scripts/govern/run-loop.sh`) so this session's context
stays flat (near-zero parent cost). Claude runs only in fresh, bounded sub-sessions: the per-ticket
**worker** and a periodic **supervisor**.

`$ARGUMENTS`:

| Argument | Effect |
|---|---|
| *(empty)* | The whole eligible backlog — one ticket at a time, or N at a time if this workspace set `GOVERN_PARALLEL_DEFAULT=N` |
| `<N>` | That one ticket only — always sequential (nothing to fan out) |
| `<N> <N> <N>` | Exactly that ticket set, in severity order |
| `--parallel[=N]` | Work up to N tickets concurrently; bare `--parallel` uses the workspace default cap (else 4) |
| `--serial` | Force one ticket at a time over the whole backlog (`--parallel=1` is identical) |
| `--dry-run` | Prove it, ship nothing |
| `--exclude N,N` | Skip these tickets (e.g. another govern session owns them) |

**Concurrency.** The default is **sequential**; set `GOVERN_PARALLEL_DEFAULT=N` in
`scripts/lib/workspace.sh` to make a plain `run-loop.sh` fan out (4 is a sensible fleet setting), or
pass `--parallel[=N]` per run. In parallel mode the driver becomes an orchestrator: for a backlog
pull it spawns **N full backlog drivers**, each grinding the queue until it is empty and contending
on the per-ticket claim lock — literally the "launch N terminals" recipe, automated. Because each
child is an ordinary sequential driver, every backlog mechanism keeps working inside it (dependency
gate, #60 failure streak, periodic supervisor, bad-streak breaker). For an explicit ticket set it
spawns one single-ticket child per named ticket instead. Safety is unchanged — the per-ticket claim
lock + the bookkeep lock are what make concurrent drivers exactly-once safe; the orchestrator adds
nothing to that model. Note the hard bounds are **per driver**, so a parallel backlog run's ceiling
is N × `GOVERN_MAX_TICKETS` (it still always ends), and N concurrent workers cost N× the spend.

**Locality batching (`GOVERN_BATCH_MAX`, default `1` = off).** Concurrency governs how many workers
run at once; batching governs how many tickets each one takes. Exploration is the dominant cost of a
resolved ticket (~98% cache reads), so three tickets in the same directory mean three workers each
paying full discovery cost on the same code. `GOVERN_BATCH_MAX=N` groups up to N same-area tickets
into ONE worker, which explores once and opens ONE PR for the group (per-ticket commits). Groups are
keyed on the leaf directory of the ticket's `Files:`/`Where:` paths, are disjoint by construction —
which is also what stops two concurrent drivers racing the same file — and never co-batch two tickets
in a dependency relation. Every ticket in a group is claim-locked, and a batched ticket is bookkept
only on an explicit per-ticket `resolved` in the worker's `tickets` array; anything else leaves it in
the queue. Backlog pulls only; an explicit ticket set is dispatched as named. See
`governor/README.md` for the full semantics.

The **run-start reconcile** (apply escalation answers → regenerate `pending-escalations.json` →
`preflight-main.sh` → externalization lane → NA-skip streak bookkeeping) is explicitly *not* per
driver: it is whole-run state reconciliation against the one shared meta checkout, and
`preflight-main.sh` fetches / rebases / pushes it. The orchestrator runs it once, before it spawns
anything and while it holds the single-run lock; each child is handed the internal `--orchestrated`
flag and skips it (logging one auditable `run-start reconcile: skipped` line). Never pass
`--orchestrated` by hand — a driver run with it reconciles nothing.

Precedence, highest first: `--serial` › `--parallel=N` › bare `--parallel` › `GOVERN_PARALLEL=N` ›
`GOVERN_PARALLEL_DEFAULT` (unset or 1 = sequential; the target-set size caps it when several tickets
are named). A resolved cap of 1 from any source means `--serial`, i.e. the whole backlog one ticket
at a time — never "one ticket then quit".

Run from the **main checkout** of the meta-repo (not a worktree), in a **plain terminal** — NOT from
inside an interactive Claude session. A nested `claude -p` inherits the parent's `CLAUDE_CODE_*` env
and the headless worker then never finalizes (answers but emits no `result`, hangs to the timeout).
`spawn-worker.sh` defensively scrubs those vars so the loop itself survives a nested launch, but your
manual preflight ping below won't — so run the preflight (and ideally the whole loop) from a real
terminal.

## Before a live run (once)
Workers authenticate via subscription OAuth — confirm a child `claude` can auth (in a plain terminal):
```bash
claude -p "ping" --model sonnet --strict-mcp-config   # should print "pong"-ish text, NOT a 401
```
`--strict-mcp-config` matches how workers actually launch (no MCP servers — they'd only slow startup
and can stall exit). If it 401s, run `claude login` in this shell first. (Don't set
`ANTHROPIC_API_KEY` unless you deliberately want the API-key fallback.) If it *hangs* with no output,
you're almost certainly running it nested inside a Claude session — open a real terminal.

Also confirm the doctrine + allowlist are set: `governor/preferences.md` reflects how you'd decide,
and `GOVERN_MERGE_REPOS` in `scripts/lib/workspace.sh` lists exactly the repos safe to auto-merge.

## Trust ladder — how much the governor does on its own (`GOVERN_AUTONOMY`)
One knob in `scripts/lib/workspace.sh` sets how far the governor is allowed to go. Graduate up a rung
as you trust the loop — you never rewrite config, just flip the value:

| `GOVERN_AUTONOMY` | Workers do the work + push `ticket-<N>` | Open a PR | Governor merges |
|---|---|---|---|
| `observe` | yes | **draft** PR (visible, inert) | never |
| `pr-only` | yes | normal PR | never (a human merges) |
| `auto` | yes | normal PR | auto-merges allowlisted repos on green-or-no-checks CI |

- **Start at `observe`** to watch what the harness produces without a single line landing on `main`:
  every ticket ends in a draft PR you read at your leisure.
- **Move to `pr-only`** (the default a fresh scaffold seeds) once the drafts look right — now you get
  the full ship pipeline minus the final click; nothing merges until you say so.
- **Flip to `auto`** when you trust it — the governor merges allowlisted-repo PRs itself (frontend
  stays PR-only regardless of the rung). This is the original behavior.

Backward compat: a workspace scaffolded before the ladder existed has no `GOVERN_AUTONOMY` line and
behaves as `auto` (unchanged). Add the line from the template to opt into a lower rung.

## Run it
```bash
scripts/govern/run-loop.sh $ARGUMENTS
```
Relay its log lines to the operator as they appear. The driver does everything — select → spawn → CI
→ merge → bookkeep → supervise → escalate — deterministically.

## What you (this Claude session) do
- **Launch** `run-loop.sh` and report its progress + the final `resolved / parked / failed` tally.
- **Surface + ANSWER escalations** when it finishes (#62 — escalations are no longer write-only):
  1. Read `governor/pending-escalations.json` (the driver writes it at run-end: the still-
     unanswered `## Open` entries). If `count` is 0, nothing needs the operator — just summarize.
  2. Present **ALL** pending escalations in a **single batched `AskUserQuestion` call** (#89) —
     `AskUserQuestion` takes up to **4 questions per prompt**, so one entry → one question, and a
     whole run's blocked tickets are asked **at once**, not one prompt per ticket. If `count > 4`,
     chunk into ceil(count/4) calls (4, then the rest) — still the minimum number of prompts, never
     one-per-ticket. For each entry use its `question` + `options`, and ALWAYS include these
     standing choices so the answer drives the lifecycle: **Do the work** (un-park → governor
     retries), **Defer / keep-manual** (auto-moves the ticket to `tickets-parked.md`), and **Keep
     open** (decide later).
     - **Don't fragment the asks across a phased run.** If you split one backlog into multiple
       `run-loop.sh` invocations, each run emits its own `pending-escalations.json` and you'd
       surface the escalations in **separate waves**. Prefer a **single whole-backlog invocation**
       when batching matters, or defer surfacing until the **final** phase, so all of the run's
       blocked tickets land in one batched ask.
     - **Inherent constraint (by design, not a bug):** the headless driver can't pause mid-run for
       an answer, so whatever you record applies at the **NEXT** run-start (`escalations-apply-answers.sh`).
       That two-run drain — run, answer the batch, re-run to act on the answers — is expected; the
       fix here is only to make the *ask* a single batch, not to make the loop interactive.
  3. Write the operator's choice back into `governor/escalations.md` under that `### #N` entry via
     `scripts/govern/record-escalation-answer.sh <N> --answer "<their words>" --disposition <token>
     [--rule "<rule text>"]` (`<token>` one of `do-the-work` | `defer` | `mitigated` | `keep-open`) —
     a Bash-only helper, so this step never needs an Edit-tool ask. Run it once per answered ticket.
  - The NEXT `run-loop.sh` start applies these automatically (`escalations-apply-answers.sh`):
    un-park, migrate-to-parked, and/or append the rule to `preferences.md`. You don't act on them
    by hand — just record the answers.
- **Do NOT re-implement the loop in-context** — driving tickets by hand in this session is the
  anti-pattern this design replaces. If the driver halts (circuit breaker / supervisor halt), report
  the reason; don't take over.

## Policy (enforced by the scripts, not by you)
- Sequential by default; `GOVERN_PARALLEL_DEFAULT=N` (or `--parallel[=N]`) fans out into N concurrent
  backlog drivers, `--serial` forces one-at-a-time. Auto-merge only
  `GOVERN_MERGE_REPOS` on **green-or-no-checks** CI; every other repo is
  PR-only. The `GOVERN_AUTONOMY` trust-ladder rung gates this: `observe`/`pr-only` never auto-merge at
  all (PRs are left open); only `auto` merges. See the Trust ladder section above.
- Hard-stops (destructive git; prod data / destructive schema / secrets) and doctrine gaps → worker
  **parks** → escalation.
- Additive prod migrations auto-apply only if `GOVERN_MIGRATE_CMD` is configured (else park for manual
  apply); destructive migrations always park.
- Supervisor every `GOVERN_SUPERVISOR_EVERY` (default 5) resolved tickets + on anomaly. The cadence is
  **per driver**, plus two out-of-loop passes (`GOVERN_SUPERVISOR_FLUSH=0` disables both):
  - a **run-tail flush** — one pass at end-of-loop when a driver still holds 1..`SUP_EVERY`-1
    unreviewed resolves, so its last few tickets are never skipped;
  - a **whole-run pool review** — one pass in the `--parallel` orchestrator over the aggregated
    `state.jsonl` after all children are reaped, so some supervisor always sees the run as a whole
    (each child's own passes only ever see that child's slice).

  **Why not scale the per-driver cadence by the fan-out?** Because the per-driver cadence is not
  globally looser in the steady state: N drivers each firing every `SUP_EVERY` of their *own* resolves
  still totals ≈ K/`SUP_EVERY` passes over K tickets, so dividing the cadence by N would over-fire by
  ~N× on a long run. What parallel actually loses is the per-driver **tail** — with `SUP_EVERY=5`, a
  12-ticket backlog split 3-per-driver across 4 drivers reaches the periodic pass zero times, where
  the same 12 run sequentially fire it twice. The tail flush restores that rhythm at ~1 extra pass per
  driver, and the pool review adds the whole-run view a pool-level supervisor was wanted for — without
  lifting the in-loop verdict handling out, since at run-end only `concerns` are still actionable
  (`skipThisRun` / `attemptNext` / `waitForMerge` / `halt` all steer a selection loop that has already
  finished, and `attemptNext`'s priority queue is per-process in-memory state regardless).
- Single-run lock (`governor/.govern.lock`); resumable — resolved tickets are deleted from
  `queue/tickets.md`, parked ones are skipped via `escalations.md`, an existing `ticket-<N>` PR is reused,
  so a re-run continues cleanly.
- Hard bounds so a run always ends: `GOVERN_MAX_TICKETS` (20), `GOVERN_MAX_BAD_STREAK` (4),
  `GOVERN_MAX_RUNTIME` (`0` = no cap by default; set to bound wall-clock), `GOVERN_WORKER_TIMEOUT`
  (1h, a stuck worker is killed not stalled), `GOVERN_WORKER_MAX_TOKENS` (0 = unlimited by default; a
  wandering worker is killed once it crosses the budget, recorded as a distinct `budget-exceeded`
  outcome).
- Progress-preserving: only resolved worktrees are torn down; failed/parked/timed-out worktrees are
  kept (work survives). Every exit writes `logs/govern/run-*/summary.md`.
