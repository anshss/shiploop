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

## Trust ladder (`GOVERN_AUTONOMY` in workspace.sh)
One knob sets how far the governor goes on its own; graduate up a rung as trust builds (flip the value,
nothing else):
- **`observe`** — workers do the work, push `ticket-<N>`, and open a **draft** PR; the governor never
  merges. Work is visible (a PR to read) but inert. The safest first setting.
- **`pr-only`** — workers open normal PRs; the governor still never merges (a human clicks merge). The
  default a fresh scaffold seeds — full pipeline minus the final merge.
- **`auto`** — full autonomy: the governor auto-merges allowlisted-repo PRs on green-or-no-checks CI
  (frontend stays PR-only regardless). The original behavior.

Backward compat: a workspace.sh predating this knob has no `GOVERN_AUTONOMY` line and resolves to
`auto` (unchanged). Graduation is always one direction you choose: observe → pr-only → auto.

## Policy (enforced by the scripts)
- Sequential: one ticket fully resolved before the next.
- Auto-merge only `GOVERN_MERGE_REPOS` (workspace.sh) on **green-or-no-checks** CI, and only when
  `GOVERN_AUTONOMY=auto` (the trust ladder above); every other repo — and every rung below `auto` —
  is PR-only.
- Hard-stops (always escalate): destructive git; prod data / destructive schema / secrets.
- Doctrine gap → park + escalate.
- Additive prod migration auto-applies **only if** `GOVERN_MIGRATE_CMD` is configured (else it parks
  for a manual apply — it never merges code ahead of a schema it needs and forgets).

## Right-sizing + retry escalation (which model runs, and what a retry changes)
- Sizing is **measured, not declared**. Before dispatch, `scout-ticket.sh` runs a cheap read-only
  `haiku` pass over the real code and answers six questions (files touched, repos involved, do tests
  cover it, is there a precedent commit, is the change local or structural, is the fix direction
  concrete or vague). A pure-bash scoring table — no second model call — turns that into
  `(model, effort)`. `GOVERN_WORKER_MODEL` / `GOVERN_WORKER_EFFORT` are the workspace floors, used
  when there is no usable verdict (scout disabled, timed out, or output rejected by the guard).
- Tickets do **not** carry `Model:` / `Effort:` fields. They used to, and the filing-time guess
  outranked the measurement — backwards, since the guess is made before any evidence exists. Legacy
  entries still carrying them are inert. `GOVERN_MEASURED_SIZING=0` restores the old precedence.
- The tier set is deliberately **coarse and must stay so**: the prompt cache is per-model and an
  effort change invalidates the tools+system prefix, so spreading N tickets across N distinct
  `(model, effort)` combinations fragments the cross-worker shared prefix that currently works.
- A **retry** classifies *why* the prior attempt failed and escalates the axis that actually failed —
  it no longer always jumps to `GOVERN_WORKER_MODEL`, which used to re-bet the top tier on failures
  where the model was never the problem:

  | failure signature (from the outcome ledger + the driver) | response |
  |---|---|
  | gh/network/auth outage, transient drop, CI state unverifiable | retry **identically** — nothing escalates |
  | red CI (usually a portability/env bug, not a thinking bug) | **same tier**, same effort |
  | burned the per-worker token budget while still exploring | scope underestimated → **raise the tier** |
  | opened a PR that never landed (a coherent but wrong fix) | judgment → **raise effort**, and the tier |
  | anything else, incl. a wall-clock timeout or no evidence | fallback: escalate to `GOVERN_WORKER_MODEL` |

- Effort is the cheaper knob, so it moves first; the tier moves only when it is below the floor. An
  escalation never **down**-grades below the tier the first attempt used — only a positively
  identified infra/CI cause may keep a sub-floor tier. Every decision is logged as
  `worker #N sizing: model=… effort=… retry-class=… — <reason>`.
- `GOVERN_RETRY_CLASSIFY=0` — kill switch: pins every retry back to the old
  always-escalate-to-`GOVERN_WORKER_MODEL` behavior.
- `GOVERN_MEASURED_SIZING=0` — kill switch: restores the old precedence in which a ticket's
  `Model:`/`Effort:` field outranks the measured verdict.

### Not every ticket earns a full worker
Dispatch used to be unconditional: every ticket got a fresh headless worker that re-derived the
codebase from scratch, however much the parent session already knew. The reason to spawn at all is
that the work would flood the parent with output it will never reference again — so when the parent
already holds the context, the spawn buys nothing and pays a cold start.

The split is by **token weight, not by task**: the parent DECIDES (states the change it already
knows), the worker EXECUTES (the edits, the test runs, the build errors, the retry loop, the PR —
the verbose part, which stays in a throwaway context). "Let the parent do the work" would destroy
the flat-parent property the governor exists for.

    GOVERN_WARM="<ticket-number>|<what you read, and the change you believe is needed>" <run command>

- The signal is **explicit and narrow, never inferred**: it names exactly ONE ticket, and it is
  per-invocation, so it cannot rot in the queue the way a ticket field does. A malformed value is
  ignored with a log line rather than guessed at.
- With a stated change → an **execute-only worker**: it gets the change instead of exploring its way
  to it, and runs at the cheapest existing tier (never a newly minted `(model, effort)` pair — that
  would re-fragment the shared prompt-cache prefix). A retry escalates off that cheap tier as usual.
- With an EMPTY change → **no worker at all**: the ticket is PARKED with the assertion recorded as an
  escalation. Never auto-resolved — "the parent thinks nothing is needed" is a claim for a human to
  confirm, and a silently dropped ticket is the one outcome this must not produce.
- **The risk, stated plainly:** a warm parent can be stale or simply wrong, and an execute-only
  worker will faithfully implement a wrong instruction where a cold worker would have re-derived the
  truth. So the brief is falsifiable, not a command: it states what the parent *believes* and
  instructs the worker to STOP and report rather than proceed if the code does not match.
- `GOVERN_EXECUTE_ONLY=0` — kill switch: hard-disables the branch fleet-wide even when `GOVERN_WARM`
  is set.

## Hard bounds (a run always ends; tune via env)
- `GOVERN_MAX_TICKETS` (20) — stop after N tickets this run (caps a tickets-beget-tickets loop).
- `GOVERN_MAX_BAD_STREAK` (4) — stop after N **consecutive** parked/failed.
- `GOVERN_MAX_RUNTIME` (`0` = no cap, default) — stop starting tickets past this many seconds. Set a
  positive value to impose a wall-clock cap (e.g. to fit a provider usage window). MAX_TICKETS +
  per-worker timeout + bad-streak still bound the run.
- `GOVERN_WORKER_TIMEOUT` (3600s) — per-worker wall-clock; a stuck/offline worker is killed, not left
  to stall the loop. `0` = unbounded.
- `GOVERN_WORKER_MAX_TOKENS` (`0` = unlimited, default) — per-worker cumulative token cap; a wandering
  worker is killed once it crosses this, same as the wall-clock timeout. Polled every
  `GOVERN_TOKEN_POLL_S` (20s default) against the live worker JSONL. Recorded as a DISTINCT
  `budget-exceeded` outcome (not `timeout`) in `state.jsonl` / the cross-run history, so a worker that
  ran out of budget while still exploring is never conflated with one that just ran long. Worktree is
  preserved and a re-run resumes it, exactly like a timeout.
- `GOVERN_SUPERVISOR_EVERY` (5) — supervisor review cadence (+ on anomaly).

## Upstream-drift pre-gate (`GOVERN_PREGATE_DRIFT`, default `1` = on)

If your workspace dogfoods this harness as one of its own sub-repos, a mechanism script under
`scripts/govern/` has a counterpart in the hub `templates/` — and another fleet may have already
ported the fix a ticket is asking for *up*. Nothing used to enforce the "diff the workspace copy
against the hub template first" rule, so a worker could spend a whole session re-deriving a fix that
was one `/shiploop:update` away. `lib/pregate.sh` closes that with pure file/git reads before the
worker is spawned — no LLM call, no network, no writes.

- **The direction test.** `live != template` alone would fire on every unported *local* improvement.
  `sync-templates.sh --paths` already lists the mirrored files this workspace changed since the sync
  marker, i.e. unported local work. Differs **and** in `--paths` → we moved → spawn. Differs and
  **not** in `--paths` → the hub moved → surface it.
- **It can never resolve a ticket.** Its only outcome is park + escalate ("port the hub diff down"),
  strictly weaker than what a worker could have done. The operator decides whether the hub version
  actually covers the ticket.
- **Fail-open everywhere.** Missing marker, missing `sync-templates.sh`, unparseable `Where:`,
  unmirrored path, any ambiguity → emit nothing → spawn exactly as before. A false negative costs one
  session; a false positive would silently stall a real ticket.
- **Narrow by construction.** Only literal, glob-free paths under `GOVERN_PREGATE_PREFIXES`
  (`scripts/ governor/ .githooks/ .claude/commands/`) are even considered, so a product-repo ticket
  can't trip it. Skipped for an explicit ticket set — the operator chose that ticket deliberately.

Codemod auto-detection is deliberately **not** implemented: a false positive that "resolves" a ticket
without fixing it is far worse than a missed opportunity, and no narrow, safe detector was found.

## Locality batching (`GOVERN_BATCH_MAX`, default `1` = off)

Exploration is the dominant cost of a resolved ticket (~98% cacheRead): three tickets that all touch
`scripts/govern/` mean three workers each paying full discovery cost on the same code — three repo
loads, three `CLAUDE.md` reads, three architecture explorations. `GOVERN_BATCH_MAX=N` lets ONE worker
take up to N tickets from the **same area** so that discovery is paid once.

- **Key.** The leaf directory name of the dominant path token on the ticket's `Files:` line (a
  measured file list, preferred) or its `Where:` line. Depth-1 is deliberate: a hub/workspace mirror
  pair (`templates/govern/run-loop.sh` ↔ `scripts/govern/run-loop.sh`) *is* the same area. A ticket
  that names no path is **unlocalized** and is never batched on a guess.
- **Grouping.** Eligible tickets are partitioned into **disjoint** groups in severity order, capped at
  N. Groups are disjoint by construction, which also makes `--parallel` safer: concurrent drivers can
  no longer be handed two tickets that edit the same file.
- **One worker → one branch → one PR** per group, with per-ticket commits.
- **Dependencies.** Two tickets in a dependency relation — declared (`**Depends on:**`) or implicit
  (the other side's `**Blocks:**`) — are **never** co-batched, so a group can't be worked out of order.
  Each batched ticket also re-passes the pre-spawn dependency gate individually.
- **Locking.** Every ticket in a group is claim-locked by the driver for the whole run, so the
  exactly-once guarantee is unchanged. A contended candidate is simply left out of the group.
- **Partial failure is per-ticket.** The worker returns a `tickets` array of `{ticket,status,note}`.
  A batched ticket is bookkept (and its block deleted) **only** on an explicit `resolved` entry —
  any other status, a missing entry, or an unparseable report leaves it in `tickets.md` for a later
  run. A group's verdict can never mark an unfixed ticket resolved.

Batching and parallelism pull against each other: past a point, bigger groups trade wall-clock for the
token saving. Hence the conservative default of `1` (one ticket per worker — today's behavior). Only
applies to a **backlog** pull; an explicit ticket set is dispatched exactly as named.

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

## Self-ROI telemetry (#272)
Every run-end **automatically** surfaces a governor-health summary — no manual log spelunking —
computed from `governor/ticket-history.jsonl` (the cross-run outcome log): **park rate**
(resolved vs parked vs failed/timeout), **self-referential churn** (share of resolved tickets whose
PR(s) only touched the harness / skill-template repos — governor self-work with near-zero product
value, the #115 waste class), and **tokens-per-ticket** + cost (from the tokenjam-tagged worker
token usage folded into each history entry). It's printed to the run log (`health | …` lines) and
into `summary.md`, showing **this run vs the rolling all-time trend** so a waste class is visible
*before* it dominates a run. Query it anytime: `<pm> run govern:health` (rolling), or
`scripts/govern/govern-health.sh --json` / `--run <id>` / `--last <N>`. Token/churn columns populate
going forward (older history rows predate the enrichment and show as "no data in scope"). Which
repos count as self-referential is `GOVERN_SELFREF_REPOS` (defaults to the merge-universe repos
outside `$REPOS` — the meta-repo + any skill-template repo).

### The sizing decision, not just the cost
A row that says a ticket cost `$9.66` but not *what tier produced that* is unlearnable — "does this
class of ticket actually succeed at sonnet?" has no answer, so any scope→tier table stays hand-tuned
forever. So each history row also carries the **decision**: `model`, `effort`, `attempt` (1-based),
and `usageSource`. `govern-health.sh` groups spend + resolve rate **by model** from those fields
(`.byModel` in `--json`; a `by model :` block in the human output), which is the sizing table read off
real runs. Mechanics:

- `spawn-worker.sh` appends one row per spawn to `logs/govern/run-*/ticket-N/attempts.jsonl` — the
  resolved model/effort **and where each came from** (a brain-decided ticket field vs the workspace
  fallback vs a retry escalation), plus that attempt's measured usage. `run-loop.sh` reads the ledger:
  spend is **summed across the run's attempts** (an in-run re-dispatch's tokens belong to the ticket
  too), while the decision fields come from the **last** attempt — the one that produced the outcome.
  So when reading per-tier success rates, filter to `attempt == 1`: a row with `attempt > 1` records
  the tier that *finished* the ticket, after a cheaper bet had already been tried and escalated away
  (`byModel.retries` counts those, so the contamination is visible rather than silent).
- **A killed attempt records its usage too.** A worker hard-killed before its verdict (wall-clock
  timeout, token budget, a stop signal) never emits the final `result` event that carries usage, so
  those rows used to be null — biased in the worst possible direction, since a failed attempt is
  exactly what proves a tier was too cheap. Tokens are now recovered from the per-turn
  `.message.usage` events (`usageSource:"assistant-partial"`); `costUsd` stays null, because the
  stream carries no per-turn price and a fabricated one would be worse than a gap.
- **Every read of a `worker.jsonl` goes through `govern::stream_grep`, never bare `grep`.** A stream
  can carry a NUL-byte hole (a re-dispatch truncating the file while the prior attempt's fd is still
  open at a high offset), and plain `grep` then classifies it as *binary* and prints **nothing** —
  silently reporting "no usage" for an intact `result` event, and equally silencing the token-budget
  kill switch, the infra/interrupted classifiers, and the report-from-stream fallback. `stream_grep`
  forces text semantics; spawn-worker also rotates a prior attempt's stream to
  `worker.attempt<K>.jsonl` so a fresh inode makes the corruption unreachable in the first place.

- **One row per ticket per run, even under the parallel default.** The per-ticket claim lock only keeps
  a sibling driver off a ticket *while* a worker holds it. A ticket that ends non-resolved (timeout /
  budget-exceeded / failed / parked) stays in `queue/tickets.md` and frees its claim the moment its
  outcome is recorded, and the `excludes` list that stops the *same* driver re-picking it is
  per-process in-memory state a sibling cannot see — so a sibling reaching selection after that
  release used to re-spawn a second full worker on a question the run had already answered, and write
  a second `state.jsonl` + history row for it (double-counting the consecutive-failure streak). Each
  recorded outcome now also appends its ticket number to a run-scoped `attempted.txt`, which every
  driver folds into its own excludes before selecting; the orchestrator's children share the
  orchestrator's file, and a driver that skips a ticket this way logs *"already answered by another
  driver this run"*. Only a child spawned with `--orchestrated` adopts an inherited path, so an
  unrelated `run-loop.sh` launched inside a live session never picks up another run's set.

Rows written before these fields existed simply lack them; every consumer filters on presence, so old
history keeps working unchanged.

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
gate, merge allowlist) are **never** auto-changed. Disable with `GOVERN_IMPROVE=0`.

The pass fires **once per run**, in the orchestrator, over the aggregated state after reaping — not
once per driver. A child driver only ever sees its own slice of the run, so a per-driver "review of
the run" is structurally a review of a fragment, and an N-way parallel run filed N near-identical
tickets (two of them from the same wall-clock run). Triage also **appends to a standing ticket**
rather than minting a new `## #N` each time, since the same friction recurs and produces the same
proposal. `GOVERN_IMPROVE_PER_RUN=0` restores per-driver filing. Opt-in guarded
auto-apply (`GOVERN_SELF_APPLY=1`, default OFF) applies ONE proposal under strict guards (edit-only
agent, mechanism-scripts allowlist, protected-pattern revert, test-gate) at run-end so it takes effect
next run.

## Constraints to respect
- Workers never write `queue/tickets.md` — `govern-bookkeep.sh` does, in the main checkout.
- Going live from a dry-run is just running without `--dry-run`; no code change.
