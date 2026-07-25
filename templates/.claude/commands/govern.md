---
description: Become the governor — launch the bash-driven ticket loop (scripts/govern/run-loop.sh): a fresh headless worker per ticket, auto-merge allowlisted repos on green-or-no-checks CI, periodic supervisor, escalate hard-stops, deterministic queue/tickets.md bookkeeping. Keeps THIS session's context flat.
allowed-tools: Bash, Read
---

# /govern

Launch the governor — a **pure-bash driver** (`scripts/govern/run-loop.sh`) so this session's context
stays flat (near-zero parent cost). Claude runs only in fresh, bounded sub-sessions: the per-ticket
**worker** and a periodic **supervisor**. `$ARGUMENTS`: empty = whole eligible backlog · a number =
one ticket · **multiple numbers = work exactly that ticket SET, sequentially, in severity order**
(e.g. `152 153 154 155` works all four, in one run — a numeric arg no longer silently overwrites the
previous one and truncates the run to the last ticket) · `--dry-run` = prove it, ship nothing ·
`--exclude N,N` = skip tickets a parallel govern session owns.

**Running tickets in parallel:** add `--parallel[=N]` to any of the above (or set `GOVERN_PARALLEL=N`)
to work the ticket set — or, with no explicit numbers, the top-N eligible backlog tickets — with N
concurrent drivers instead of one sequential process; N defaults to the target-set size, or 4 for a
bare backlog pull. This is the built-in equivalent of the manual recipe of hand-launching N separate
single-ticket `run-loop.sh <N>` drivers, each with `GOVERN_ALLOW_CONCURRENT=1` — the per-ticket claim
lock + the bookkeep lock make either form exactly-once safe; `--parallel` just drives the fan-out/
wait/aggregate for you and reports one combined resolved/parked/failed/timed-out tally at the end.

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
     retries), **Defer / keep-manual** (auto-moves the still-TODO ticket to `queue/tickets-parked.md`),
     **Mitigated** (harm already zero / accept current state → removes the ticket from `queue/tickets.md`
     and closes it as accepted-current-state, NOT parked as still-todo), and **Keep open** (decide
     later).
     - **Don't fragment the asks across a phased run.** If you split one backlog into multiple
       `run-loop.sh` invocations, each run emits its own `pending-escalations.json` and you'd
       surface the escalations in **separate waves**. Prefer a **single whole-backlog invocation**
       when batching matters, or defer surfacing until the **final** phase, so all of the run's
       blocked tickets land in one batched ask.
     - **Inherent constraint (by design, not a bug):** the headless driver can't pause mid-run for
       an answer, so whatever you record applies at the **NEXT** run-start (`escalations-apply-answers.sh`).
       That two-run drain — run, answer the batch, re-run to act on the answers — is expected; the
       fix here is only to make the *ask* a single batch, not to make the loop interactive.
  3. Write the operator's choice back into `governor/escalations.md` under that `### #N` entry:
     fill `- **Answer:**` with their words and `- **Disposition:**` with the canonical token
     (`do-the-work` | `defer` | `mitigated` | `keep-open`). If they want it to become standing policy,
     put the rule sentence in `- **Make this a rule?:**`.
  - The NEXT `run-loop.sh` start applies these automatically (`escalations-apply-answers.sh`):
    un-park, migrate-to-parked, and/or append the rule to `preferences.md`. You don't act on them
    by hand — just record the answers.
- **Do NOT re-implement the loop in-context** — driving tickets by hand in this session is the
  anti-pattern this design replaces. If the driver halts (circuit breaker / supervisor halt), report
  the reason; don't take over.

## Policy (enforced by the scripts, not by you)
- Sequential by default (`--parallel` opts into N concurrent single-ticket drivers, see above); auto-
  merge only `GOVERN_MERGE_REPOS` on **green-or-no-checks** CI; every other repo is PR-only.
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
  `GOVERN_MAX_RUNTIME` (~4h), `GOVERN_WORKER_TIMEOUT` (1h, a stuck worker is killed not stalled),
  `GOVERN_WORKER_MAX_TOKENS` (0 = unlimited by default; a wandering worker is killed once it crosses
  the budget, recorded as a distinct `budget-exceeded` outcome).
- Progress-preserving: only resolved worktrees are torn down; failed/parked/timed-out worktrees are
  kept (work survives). Every exit writes `logs/govern/run-*/summary.md`.
