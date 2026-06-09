# Governor harness — operating guide

One long-running **governor** drives fresh per-ticket **headless `claude -p`** workers. The operator
job shrinks to: managing `tickets.md`, answering `escalations.md`, and the two hard-stop decision
classes. The governor itself is a **pure-bash driver** (`scripts/govern/run-loop.sh`) — it spends ~zero
Claude context; Claude runs only inside the bounded worker and supervisor sub-sessions.

## Run it
From the main checkout, invoke the slash command:
```
/govern              # work the whole eligible backlog, sequentially
/govern 42           # work only ticket #42
/govern --dry-run    # prove the pipeline, ship nothing
```
Or directly: `scripts/govern/run-loop.sh [--dry-run] [--exclude N,N] [<ticket>]`.

## Worker authentication (do this once before a live run)
Spawned `claude -p` workers need their own credential. Use **subscription OAuth**: run `claude login`
once in the environment where the governor runs. **Verify:** `claude -p "ping" --model sonnet` should
print text, not `401 Invalid authentication credentials`. Don't set `ANTHROPIC_API_KEY` in that shell
unless you deliberately want the API-key fallback (it overrides the OAuth credential).

## Pieces
- `preferences.md` — doctrine injected into every worker (input; the operator customizes it).
- `escalations.md` — parked decisions awaiting you (output). Answer inline; mark "make this a rule" to
  grow the doctrine.
- `worker-prompt.md` / `supervisor-prompt.md` — the templates workers / the supervisor run.
- `improvements.md` — self-improvement proposals (output; observe→propose, never auto-applied unless
  you opt in).
- `scripts/govern/*.sh` — the mechanism (select / spawn / await-ci / merge / bookkeep / supervise).
- `tickets-parked.md` — move tickets here to defer them; the governor ignores it.

## Policy (enforced by the scripts)
- Sequential: one ticket fully resolved before the next.
- Auto-merge only `GOVERN_MERGE_REPOS` (workspace.sh) on **green-or-no-checks** CI; every other repo
  is PR-only.
- Hard-stops (always escalate): destructive git; prod data / destructive schema / secrets.
- Doctrine gap → park + escalate.
- Additive prod migration auto-applies **only if** `GOVERN_MIGRATE_CMD` is configured (else it parks
  for a manual apply — it never merges code ahead of a schema it needs and forgets).

## Hard bounds (a run always ends; tune via env)
- `GOVERN_MAX_TICKETS` (20) — stop after N tickets this run (caps a tickets-beget-tickets loop).
- `GOVERN_MAX_BAD_STREAK` (4) — stop after N **consecutive** parked/failed.
- `GOVERN_MAX_RUNTIME` (14400s ≈ 4h) — stop starting tickets past this.
- `GOVERN_WORKER_TIMEOUT` (3600s) — per-worker wall-clock; a stuck/offline worker is killed, not left
  to stall the loop. `0` = unbounded.
- `GOVERN_SUPERVISOR_EVERY` (5) — supervisor review cadence (+ on anomaly).

## Progress preservation (acts like a human reopening sessions)
- Only a cleanly **resolved** ticket's worktree is torn down. **Failed / parked / timed-out worktrees
  are kept** on disk (uncommitted work survives) + their path is logged. A timeout is a *pause*, not
  lost work — the PR (if opened) is safe on GitHub and the ticket stays in `tickets.md`.
- **No duplicate PRs on resume:** before spawning, an existing open PR on branch `ticket-<N>` is
  detected and the run resumes from CI→merge→bookkeep.
- A clean interrupt (Ctrl-C / SIGTERM / sleep) leaves the in-flight ticket + worktree; re-running
  continues (resolved → gone from `tickets.md`; parked → skipped via `escalations.md`).
- A run writes a plain-words summary on **every exit (clean OR crash/kill)** to
  `logs/govern/run-*/summary.md` and `logs/govern/last-session.md`.

## Worker hook isolation (automatic)
`spawn-worker.sh` runs children with **`--setting-sources user`**, dropping this repo's PROJECT
`.claude/settings.json` hooks — so a worker does NOT inherit a SessionEnd cleanup (which could be
fleet-wide), the Stop ticket-sweep reminder (clobbers the worker's final stdout), or the SessionStart
flood. The worker still gets user-level config, auth, CLAUDE.md, and skills. The report is read from a
file, so even a stray Stop hook can't corrupt it — belt and suspenders.

## Self-improvement (observe → propose; never auto-applies)
After a run that hit friction (any parked/failed ticket or supervisor concern), a fresh read-only
reviewer (`govern-improve.sh`) appends concrete improvement proposals to `governor/improvements.md`. It
only *proposes*; the operator reviews and applies. Safety rails (hard-stops, run bounds, permission
gate, merge allowlist) are **never** auto-changed. Disable with `GOVERN_IMPROVE=0`. Opt-in guarded
auto-apply (`GOVERN_SELF_APPLY=1`, default OFF) applies ONE proposal under strict guards (edit-only
agent, mechanism-scripts allowlist, protected-pattern revert, test-gate) at run-end so it takes effect
next run.

## Constraints to respect
- Workers never write `tickets.md` — `govern-bookkeep.sh` does, in the main checkout.
- Going live from a dry-run is just running without `--dry-run`; no code change.
