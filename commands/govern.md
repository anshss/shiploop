---
description: Become the governor — launch the bash-driven ticket loop (scripts/govern/run-loop.sh): a fresh headless worker per ticket, auto-merge allowlisted repos on green-or-no-checks CI, periodic supervisor, escalate hard-stops, deterministic tickets.md bookkeeping. Keeps THIS session's context flat.
allowed-tools: Bash, Read
---

# /meta-repo:govern

Launch the governor — a **pure-bash driver** (`scripts/govern/run-loop.sh`) so this session's context
stays flat (near-zero parent cost). Claude runs only in fresh, bounded sub-sessions: the per-ticket
**worker** and a periodic **supervisor**. `$ARGUMENTS`: empty = whole eligible backlog · a number =
one ticket · `--dry-run` = prove it, ship nothing · `--exclude N,N` = skip tickets a parallel govern
session owns.

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
- **Surface escalations** when it finishes: read `governor/escalations.md` (`## Open`) and the run's
  `logs/govern/run-*/summary.md`, and summarize what needs the operator.
- **Do NOT re-implement the loop in-context** — driving tickets by hand in this session is the
  anti-pattern this design replaces. If the driver halts (circuit breaker / supervisor halt), report
  the reason; don't take over.

## Policy (enforced by the scripts, not by you)
- Sequential; auto-merge only `GOVERN_MERGE_REPOS` on **green-or-no-checks** CI; every other repo is
  PR-only.
- Hard-stops (destructive git; prod data / destructive schema / secrets) and doctrine gaps → worker
  **parks** → escalation.
- Additive prod migrations auto-apply only if `GOVERN_MIGRATE_CMD` is configured (else park for manual
  apply); destructive migrations always park.
- Supervisor every `GOVERN_SUPERVISOR_EVERY` (default 5) resolved tickets + on anomaly.
- Single-run lock (`governor/.govern.lock`); resumable — resolved tickets are deleted from
  `tickets.md`, parked ones are skipped via `escalations.md`, an existing `ticket-<N>` PR is reused,
  so a re-run continues cleanly.
- Hard bounds so a run always ends: `GOVERN_MAX_TICKETS` (20), `GOVERN_MAX_BAD_STREAK` (4),
  `GOVERN_MAX_RUNTIME` (~4h), `GOVERN_WORKER_TIMEOUT` (1h, a stuck worker is killed not stalled).
- Progress-preserving: only resolved worktrees are torn down; failed/parked/timed-out worktrees are
  kept (work survives). Every exit writes `logs/govern/run-*/summary.md`.
