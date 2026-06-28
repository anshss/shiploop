# Governor harness — operating guide

One long-running **governor** drives fresh per-ticket **headless `claude -p`** workers. The operator
job shrinks to: managing `queue/tickets.md`, answering `escalations.md`, and the two hard-stop decision
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
- `escalations.md` — parked decisions awaiting you (output). Answer inline (or via the relay, below);
  mark "make this a rule" to grow the doctrine.
- `pending-escalations.json` — machine-readable driver→relay hand-off of the unanswered `## Open`
  entries (regenerated every run-end; gitignored runtime state).
- `worker-prompt.md` / `supervisor-prompt.md` — the templates workers / the supervisor run.
- `improvements.md` — self-improvement proposals (output; observe→propose, never auto-applied unless
  you opt in).
- `decisions-log.md` — append-only record of dated operator decisions (audit / continuity reference);
  a recurring decision here graduates into a `preferences.md` rule.
- `scripts/govern/*.sh` — the mechanism (select / spawn / await-ci / merge / bookkeep / supervise /
  escalation lifecycle).
- `queue/tickets-parked.md` — manual defer queue the governor ignores. A `defer` escalation answer
  auto-migrates a ticket here (#62).

## Escalation lifecycle (#62 — answers feed back into the loop)
Parked decisions used to be **write-only**: a worker appended a `## Open` entry and nothing ever
asked the operator, so they sat unanswered indefinitely. Now the loop closes itself:
- **Run-end (`escalations-emit-pending.sh`):** writes `pending-escalations.json` (the unanswered
  `## Open` entries) and fires `GOVERN_NOTIFY_CMD` if set — so a headless run still signals you.
- **Relay (`/govern` session):** presents all pending escalations in a **single batched
  `AskUserQuestion`** (#89 — ≤4 questions per prompt; chunk if >4, never one prompt per ticket) and
  records each operator's **Answer** + a canonical **Disposition** (`do-the-work` | `defer` |
  `mitigated` | `keep-open`) back into `escalations.md` (plus an optional "Make this a rule?" sentence).
- **Next run-start (`escalations-apply-answers.sh`):** acts on each recorded answer —
  `do-the-work` un-parks (governor retries the ticket), `defer` auto-migrates the ticket to
  `queue/tickets-parked.md` (renumbered, still TODO) and resolves the escalation, `mitigated` removes the
  ticket from `queue/tickets.md` and closes it as accepted-current-state (harm already zero — NOT parked as
  still-todo), and a rule sentence is appended to `preferences.md`. Idempotent and committed like the
  bookkeep.

`GOVERN_NOTIFY_CMD` (optional): a command fed the alert message on stdin when pending escalations
exist (e.g. `GOVERN_NOTIFY_CMD='terminal-notifier -title Governor'` or a Slack webhook curl).
Unset → the run summary's "Needs you" section is the signal.

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
  lost work — the PR (if opened) is safe on GitHub and the ticket stays in `queue/tickets.md`.
- **No duplicate PRs on resume:** before spawning, an existing open PR on branch `ticket-<N>` is
  detected and the run resumes from CI→merge→bookkeep.
- A clean interrupt (Ctrl-C / SIGTERM / sleep) leaves the in-flight ticket + worktree; re-running
  continues (resolved → gone from `queue/tickets.md`; parked → skipped via `escalations.md`).
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
- Workers never write `queue/tickets.md` — `govern-bookkeep.sh` does, in the main checkout.
- Going live from a dry-run is just running without `--dry-run`; no code change.
