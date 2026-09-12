# bench

The benchmark behind shiploop's cost claim. The unit is **a full session clearing a backlog**, not a
ticket: the whole loop (scout, cheap-floor dispatch, escalation, fresh context per worker) against
the whole alternative (one Claude Code session grinding the same backlog, top to bottom).

**What the percentage is a percentage of.** Every number in this file is a reduction in total
billed tokens across a backlog run (context read, context write, and the response itself), not a
fraction of your bill. Output tokens, the actual code and prose written, are paid in full by BOTH
arms: it is the same work and the same code either arm has to produce, and no architecture removes
that cost. That sets a hard ceiling well under 100%, and the ceiling on cost is far lower than the
ceiling on tokens (`bench/METHODOLOGY.md`, "The ceiling"). A token or cost reduction quoted from this file
is never the same claim as cutting your bill by that same fraction, because the bill also carries
the output share that no reduction touches.

There are two numbers, and this file states which side of each is measured and which is modeled,
in the same sentence as the number, per `bench/KNOWN-LIMITS.md` (read that file first — it leads
with what does not hold).

- **The best-case number** (below): `bench/replay.mjs` over real governor transcripts already on
  disk. The shiploop arm is measured billed usage. The vanilla arm is a **model** of one
  accumulating session over the same tickets — no vanilla session was run for this number.
- **The honest number** (`## Path 2`): a real, live, two-arm run — `claude -p` vs the actual
  governor loop — where BOTH arms are measured, on the same tiny pilot backlog, same model, no
  remotes, nothing that can push.

Where either number does not hold: `bench/KNOWN-LIMITS.md`.

## The published claim

The project website carries this sentence. The GitHub repo description no longer does, and the
website copy is being revised separately; it is reproduced here because it is what this directory
would have to back:

> Shiploop minimizes tokens per shipped work, making Claude Code up to 70% more efficient and
> faster by cutting wasted model work and getting more from its warm prompt cache with lean,
> context-aware, resilient workers.

**Nothing in this directory currently backs any number in that sentence.** The claim-audit table
that used to live here mapped each element of it to a measured or modeled figure. Those figures came
off a corpus that cannot support them, so they have been removed rather than restated with caveats:

- Nothing in the corpus is instrumented yet. Five of the levers the bench attributes savings to are
  read from `lever-events.jsonl`; the emitter now ships on by default at runtime
  (`GOVERN_LEVER_EVENTS=0` is the kill switch), but no run collected so far carries it.
- No run recorded which model dispatched it, so the counterfactual's model tier is a fallback guess
  in the direction that flatters the harness.
- Almost no run wrote an orchestration transcript, so the harness's own overhead is uncharged and
  the shiploop side of any comparison is a lower bound rather than a measurement.

What can be said without a number, and what this repository does say elsewhere in full:

- **"and faster" is not backed and cannot become backed by this benchmark.** No wall-clock timing is
  collected anywhere in this repository (`bench/METHODOLOGY.md`, "What is not measured at all").
  Running N fresh worker sessions sequentially may well be slower than one continuous session.
- **"more efficient" is ambiguous between tokens and cost, and they are not the same number.** The
  token figure is model-independent by construction; the cost figure depends on the rate table and
  on the corpus's model mix. A cost reduction never carries the same confidence as a token
  reduction, whatever the two turn out to be.
- **"cutting wasted model work" and "warm prompt cache" are mechanism descriptions, not metrics.**
  They describe why a modeled effect exists. Neither is a quantity this repository computes.

`bench/published-rows/SCHEMA.md` states what has to happen before any of this can carry a figure
again: instrumentation merged and switched on, runs accumulated on a stamping version, then a run.

### Tokens vs. cost: not the same robustness

The token reduction is **model-independent by construction**: the token path involves no dollar
rate at any step (`bench/replay.mjs`, `replayRun`), so a token figure would be the same on a corpus
billed at any prices. The cost reduction is **not**: it applies the published per-tier rate table to
both arms, so it is a function of that corpus's particular mix of haiku/sonnet/opus sessions and
moves if the mix moves, even when the underlying token behaviour is identical. Whenever these
numbers exist again, a cost reduction must never be quoted with the same confidence as a token
reduction. See also the mixed-model pricing note in `bench/METHODOLOGY.md` ("Flatters shiploop") and
`bench/KNOWN-LIMITS.md`, which biases the cost figure specifically, not the token one.

## Where the number is worst

Publishing a bad row is the category's cheapest credibility, and it costs nothing to keep doing.
Three, each with its source, none softened:

- **Ticket position 1 saves exactly 0%.** A fresh session against a fresh session is the same
  session: nothing has been carried into the first ticket of any run, in any arm, at any fleet, so a
  per-task claim is indefensible and the claim can only ever exist at the run level. This is
  structural, not a property of any particular corpus, and `templates/govern/test/test-bench-replay.sh`
  asserts it on the fixture.
- **The arm most readers will actually run is the weakest one.** Any "up to" figure will be the `1m`
  (1M-context) arm. Against the CLI's own 200k default with compaction the same corpus always gives
  a substantially smaller number, because a 200k window cannot hold much carry in the first place.
  Quote the arm or quote nothing.
- **The one live, both-arms-measured run cleared 0 of 2 tickets on either side, and produced no
  usable savings figure.** `bench/pilot-backlogs/shiploop-mini`: both arms were executed for real
  against the same two tickets, and neither satisfied the golden-test-patch oracle. The harness arm
  spent MORE tokens than the single-session arm, not fewer. The magnitudes are not published, for
  the same reason no favourable magnitude is (see "Path 2" below, and `bench/KNOWN-LIMITS.md`, "The
  honest live run: both arms scored 0/2 on the mechanical oracle").

Do not quote a number from this file without also carrying the fact directly above it.

## Path 1: replay (what produces the number today)

`bench/replay.mjs` reads governor transcripts a fleet has already written, sums the measured billed
usage, and models what the same tickets would have cost inside one accumulating Claude Code session.
Zero dependencies, read only, no `claude` process, no spend.

```bash
# reproduce the published number: every fleet workspace beside you
node bench/replay.mjs --arm all

# get your own: point it at your workspace
node bench/replay.mjs --fleet /path/to/your-workspace --arm all

# or, with the plugin installed, from inside your workspace
/shiploop:bench
```

**The number it prints is a modeled counterfactual.** The shiploop arm is measured billed usage.
The vanilla arm never ran: it is a model. The tool prints that as a line in its own output, not as
a footnote, and every assumption with its bias direction is in `bench/METHODOLOGY.md`. Read that
before quoting a percentage.

| Flag | Meaning |
|---|---|
| `--fleet <path>` | a workspace to read, repeatable. Omit for auto-discovery of the current workspace and its siblings |
| `--arm 200k\|1m\|uncapped\|all` | which counterfactual session to model. Default `all`. `uncapped` is computed and labelled unphysical |
| `--baseline same-mix\|driver-tier\|all` | which MODEL the counterfactual runs on. Default `driver-tier`. Composes with `--arm` as a matrix |
| `--partials price\|drop` | count a session killed before its result event from the usage it did record, or drop it. Default `price`. Both totals print either way |
| `--scope all\|resolved` | count every ticket the loop paid for, or only the resolved ones. Default `all` |
| `--json` | machine-readable, same numbers |
| `--rows` | one anonymized row per (run, ticket position), carrying the run's harness `version` and `ts` |
| `--rows-file <path>` | aggregate a published rows file instead of reading transcripts. No workspace is touched |

**Three metrics, never blended.** The report prints tokens, cost in USD, and quota-weighted tokens
(tokens x the tier's input-rate ratio, the subscription framing). Routing work to a cheaper model
cannot move the token column, and the report says so where it prints it.

**Every lever, named.** The report decomposes the saving into additive components and asserts that
they sum to it. Levers with no counterfactual are listed as `unmeasured`; levers already baked into
both arms are listed as `absorbed (uncredited, conservative)`; levers that need instrumentation the
corpus does not carry read `uninstrumented`, never `0%`. Full map: `bench/METHODOLOGY.md`.

**The harness pays for itself.** Orchestration-side transcripts (governor, scout, re-verification)
are summed INTO the shiploop arm. That lowers the shiploop number on purpose. A run that wrote no
such transcript is flagged `overhead-uncovered` and counted, so what the charge could not reach is
stated rather than assumed to be zero.

The report always carries the pieces that make the number checkable: n runs, n tickets, sessions
excluded for having no result event, the ceiling no architecture could beat, the rates
reconciliation ratio, and the **per-ticket-position curve**. Ticket 1 saves exactly 0%, because
nothing has been carried into it yet. That is the most useful line in the output.

## There is no published number yet, and this section says why

This is where a measured corpus figure used to sit. It is gone, deliberately, and nothing has
replaced it.

The mechanism in this directory is complete: `bench/replay.mjs` runs, models both baselines and all
three arms, prices three metrics, attributes per lever, and prints its own coverage. What it does
not have is a corpus worth reporting on:

| What the model needs | What the corpus has |
|---|---|
| `lever-events.jsonl` per run, for five of the levers | nothing yet. The emitter now ships on by default at runtime, but has not been live for any run in the existing corpus |
| the dispatching session's model, for the `driver-tier` baseline | nothing. Every run falls back to "highest tier seen", a guess that flatters the harness |
| an orchestration transcript per run, to charge the harness its own overhead | almost nothing. Nearly every run is `overhead-uncovered`, so the shiploop side is a lower bound |
| a version stamp per run, to scope a figure to one harness version | nothing on any historical run |

A percentage computed against that is a measurement of the instrumentation gap, not of the product,
so none is published, quoted, or committed anywhere in this repository.

**Anyone can still compute their own**, and the tool will tell them exactly how much of what it
models their corpus could actually support:

```bash
node bench/replay.mjs --fleet /path/to/your-workspace --arm all
```

The report prints the coverage counts next to every lever, the count of runs whose driver tier was
guessed, the count of `overhead-uncovered` runs, and a paragraph saying that an uninstrumented
corpus understates the harness rather than measuring it at zero. Read those before reading the
percentage.

**The order of operations before a number ships here** (`bench/published-rows/SCHEMA.md`):
instrumentation merges and is switched on, runs accumulate on a version that stamps both the
harness version and the driver model, and only then does anyone run the bench for a figure and
publish the rows behind it.

## Path 2: the live A/B harness, and the honest run it produced

**`bench/pilot-backlogs/shiploop-mini` (2 tickets, mined from shiploop's own history, gitignored,
not the published backlog set: `bench/KNOWN-LIMITS.md`).** Two arms actually executed, same tickets,
no remotes, nothing that can push. This is the path that measures both sides at once, rather than
modelling one of them.

**The result was adverse, and it is stated here without figures.** Neither arm cleared either ticket
against the oracle: `vanilla` 0 of 2, `shiploop` 0 of 2. The harness arm spent MORE tokens than the
single long session, not fewer, and less money, the latter partly because the governor's own
per-ticket model sizing put one worker on a cheaper tier than the other arm ran on. That is a real
product behaviour, but the run was supposed to hold the model constant across arms and did not, so
even the direction of the cost result is confounded. Full disclosure of both failures:
`bench/KNOWN-LIMITS.md`, "The honest live run" and "The honest run's arms were not on the same
model".

**Why no magnitudes.** Adverse results are described without figures here for exactly the same
reason favourable ones are: nothing in the current corpus is instrumented well enough to quote, and
a number is either publishable or it is not, regardless of which direction it points. A reader must
not read the absence of bad numbers as the absence of bad results. The bad result is above, in
words: the harness lost this run on tokens, and neither arm did the job.

Everything below this line is the harness itself: two arms actually executed against a pinned
backlog with a SWE-bench-shaped oracle, exercised for real above. The replay path (Path 1) remains
the tool for computing a number from a fleet's own accumulated logs; this path is the one that
measures both sides at once.

## What is here

```
bench/
  replay.mjs                      replay path: fleet transcripts -> measured vs modeled matrix
  gen-proof-table.mjs             published-rows -> a human-readable proof table, deterministic
  METHODOLOGY.md                  what is measured, what is modeled, every assumption and its bias
  backlogs/<name>/backlog.jsonl   the published backlog set (schema: backlogs/SCHEMA.md)
  pilot-backlogs/                 candidate pool, gitignored, never pushed
  published-rows/SCHEMA.md        the row shape, and why nothing is published yet
  run.sh                          driver: backlog x arm x rep -> worktree -> arm -> verify -> record
  validate-backlog.sh             offline fail-to-pass gate; decides which backlogs are eligible
  arms.sh                         the three arm shapes
  record.sh                       result events -> results.jsonl rows
  rollup.mjs                      results.jsonl -> the three metric cuts, selection, headline
  fixtures/                       canned streams, the replay fixture fleet, golden results
  results/<run-id>/               results.jsonl + session logs, gitignored
  results/README.md               why no result table is committed right now
```

## Arms

| Arm | Shape |
|---|---|
| `vanilla` | One `claude -p` session for the whole backlog, headless default model, in a fresh worktree of the pinned ref. Prompt is the backlog verbatim. |
| `shiploop` | The real shipped session lane (`pre-dispatch-check.sh`, then `spawn-worker.sh`, then `resolve-ticket.sh`) walked over a `queue/tickets.md` seeded with the same backlog, in a scaffolded throwaway workspace, defaults on. Cost is everything the lane spends: gates, scouts, workers, escalations. |
| `vanilla-fresh` | A fresh session per ticket, sequential. Private record only, opt-in via `--arm vanilla-fresh`. |

Ticket text is byte-identical across arms. Neither arm has WebFetch or WebSearch.

## Running the live A/B harness

Requires `node`, `jq`, `git`, and a `claude` CLI on PATH. It spends real quota. The replay path
above needs none of that and spends nothing.

```bash
# 1. Dry run first. Zero network, zero spend, canned fixtures for both arm shapes.
bash bench/run.sh --dry-run

# 2. The real run over the published backlog set.
bash bench/run.sh --reps 2

# 3. The three metric cuts, the selection ranking, and the headline sentence.
node bench/rollup.mjs
```

`run.sh` prints the results path; `rollup.mjs` with no argument reads the newest run under
`bench/results/`. Pass a path to read a specific one.

The rollup prints every cut it can compute and `n/a` with a reason for any it cannot. The headline
line names which metric produced its percentage, so a token cut is never published under a cost
word.

## Rails

Both are always on. Neither is an option.

| Rail | Default | Behavior |
|---|---|---|
| `BENCH_MAX_USD` | 60 | Hard cap on API-rate `total_cost_usd` across the run, checked before each cell is dispatched. Past it the driver stops dispatching and records the remaining cells with `status: capped`; the rollup drops a capped backlog rather than counting a truncated run as a saving. |
| `BENCH_MAX_TURNS` | 200 vanilla session, 80 per shiploop worker | `--max-turns` on every spawned session. A run that hits the ceiling clears fewer tickets, records as failed-to-clear, and drops the backlog from the published set. |

`--max-turns` is gated on a cached `claude --help` capability probe, never a version compare. If the
CLI does not support it, `run.sh` refuses to spawn rather than silently running uncapped. The
override is deliberate and explicit: `BENCH_ALLOW_UNCAPPED_TURNS=1`. `BENCH_MAX_TURNS_FLAG=0` is the
kill switch that omits the flag; `_GOVERN_MAXTURNS_SUPPORTED=1|0` pre-seeds the probe for tests.

Both arms reach that one probe, `govern::claude_supports_max_turns` in
`templates/govern/lib/common.sh`, so they can never disagree about CLI support. The shiploop arm's
workers get the ceiling through `GOVERN_WORKER_MAX_TURNS`, which `spawn-worker.sh` resolves behind
the same probe. That knob is OFF by default (`0` means no flag and no probe), so a fleet that never
sets it spawns exactly as it did before the bench existed.

Other knobs: `BENCH_CLAUDE_BIN` (default `claude`), `BENCH_OUT_ROOT`, `BENCH_MODEL_LABEL` (the model
name written onto each row and into the headline sentence).

`bench/backlogs/fixture-backlog/` is a test fixture, not a benchmark backlog. It names a
`fixture://` repo, so a non-dry run refuses it up front rather than failing halfway through a
clone, and it can never be counted toward a published backlog total.

## Verification: the golden test patch

`verify_cmd` is the test the merged upstream PR made pass, so **at the pinned `ref` it does not
exist yet**. The oracle is therefore SWE-bench shaped, and the ordering is the contract:

1. Worktree at `ref`. The arm receives `title` and `body` verbatim and nothing else. It never sees
   `test_patch`, `merge_sha`, `upstream_pr`, or `verify_cmd`.
2. The arm finishes and commits.
3. `git apply` the ticket's `test_patch` onto the arm's tree, then run `verify_cmd`.
4. If the apply fails, record the sentinel `90` and treat the ticket as unresolved. No 3-way merge,
   no fuzzy apply, no `--reject`.

Same path for both arms. Per-ticket outcomes land in `results/<run-id>/verify/<cell>.jsonl`, which
is the private record; only the cell-level counts reach `results.jsonl`. Nothing is judged by a
model. A backlog either arm fails to fully clear is dropped from the published set, so completion
on the published sample is 100% by construction and is not a reported metric.

### Backlog validation

Before a backlog can enter the pilot it has to prove the fail-to-pass property offline:

```bash
bash bench/validate-backlog.sh --backlogs bench/pilot-backlogs --json
```

Per ticket, against a real clone, no model calls: `test_patch` must apply at `ref`, `verify_cmd`
must FAIL there, and at `merge_sha` the test content must be present and `verify_cmd` must PASS.
A backlog under `--min-tickets` (default 6) is marked unusable, and the gate exits non-zero when
nothing is usable so a pilot script cannot proceed on an empty eligible set.

## Cost figures and account type

Every cost figure comes from `total_cost_usd` on the session's `result` event, which is API-list-rate
denominated regardless of how the CLI is authenticated. On a subscription those dollars are a proxy
for quota burn; on an API key they are the invoice. The published figure is a percentage, so it is
identical in both worlds.

## Tests

`templates/govern/test/test-bench-*.sh`, fixture-driven, zero spawns. They resolve the hub as
`$DIR/../../..` and skip (exit 77) anywhere else, so they are listed in `tools/hub-context-tests.txt`
and run by the `hub-context-tests` CI job from the checkout, where a skip is a hard failure.

```bash
for t in templates/govern/test/test-bench-*.sh; do bash "$t"; done
```

`test-bench-replay.sh` and `test-bench-replay-schema.sh` cover the replay path against
`fixtures/replay-fleet`, a synthetic fleet whose every expected figure is derivable by hand from the
table in `fixtures/README.md`. They assert, among other things, that summing the stream's
`output_tokens` snapshots (which undercounts real output badly enough to invent a saving that is
not there) is not what produced the shiploop arm.

`test-bench-proof-table.sh` exercises `bench/gen-proof-table.mjs` against a rows file generated
into a temp directory from the synthetic fixture fleet: it asserts the generator is deterministic,
that its output does not depend on the caller's working directory, that an explicit path argument
reproduces the default, and that the table tags its measured and modeled sides inline. It no longer
diffs against a committed table, because no result table is committed: see `bench/results/README.md`
and `bench/published-rows/SCHEMA.md`. That drift guard comes back with the first published corpus.
