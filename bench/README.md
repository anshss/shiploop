# bench

The benchmark behind shiploop's cost claim. The unit is **a full session clearing a backlog**, not a
ticket: the whole loop (scout, cheap-floor dispatch, escalation, fresh context per worker) against
the whole alternative (one Claude Code session grinding the same backlog, top to bottom).

There are two paths. **The replay path is the one that produces a number today.** The live A/B
harness is the measured path, and it has not been run.

Design and rationale: `.specs/2026-09-03-benchmark-design.md`.

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
| `--scope all\|resolved` | count every ticket the loop paid for, or only the resolved ones. Default `all` |
| `--json` | machine-readable, same numbers |

The report always carries the pieces that make the number checkable: n runs, n tickets, sessions
excluded for having no result event, the ceiling no architecture could beat, the rates
reconciliation ratio, and the **per-ticket-position curve**. Ticket 1 saves exactly 0%, because
nothing has been carried into it yet. That is the most useful line in the output.

## The number, on the author's corpus

Every fleet workspace the author runs, unfiltered: 251 runs, 607 tickets, 7 workspaces.

| vs a session with | tokens | cost |
|---|---|---|
| 1M context | **70.3%** | 57.4% |
| 200k context + compaction | 30.0% | 18.1% |

Published unfiltered on purpose. Restricting to runs that clear five or more tickets raises the 1M
figure to about 74%, and a single deep-backlog workspace reaches 77%, because **the saving is a
property of backlog depth, not of the harness**. Ticket 1 saves exactly 0%: a fresh session against
a fresh session is the same session. By ticket 3 it is 63%, by ticket 5 it is 74%, by ticket 8 it is
87%. The median run in this corpus clears one ticket, so the aggregate is carried by the minority of
long runs, and a two-ticket backlog will not see 70%.

Restricting the same corpus by run depth, 1M arm:

| runs of depth | runs | tickets | tokens | cost |
|---|---|---|---|---|
| all | 251 | 607 | 70.3% | 57.4% |
| >= 2 | 109 | 465 | 73.7% | 61.4% |
| >= 3 | 86 | 435 | 75.0% | 62.6% |
| >= 5 | 67 | 390 | 76.0% | 63.9% |
| >= 8 | 24 | 255 | 80.2% | 69.3% |

142 of the 251 runs clear a single ticket and contribute a 0% saving by construction, which is what
holds the unfiltered figure at 70.3%. From depth 2 onward the number is stable in a 74 to 76 band,
so a backlog of three to five tickets is enough for a measurement to mean something.

Quote the arm alongside the number. Against the 200k default the same corpus gives 30.0% tokens, and
someone reproducing this will run the default.

## Path 2: the live A/B harness (the measured path, not yet run)

Everything below this line is the harness for a real measured run: two arms actually executed
against a pinned backlog set with a SWE-bench-shaped oracle. It is complete and tested, and it has
not been executed against a published backlog. When it is, its numbers supersede the replay path's,
and the replay path stays as the tool that computes a number for someone else's fleet.

## What is here

```
bench/
  replay.mjs                      replay path: fleet transcripts -> measured vs modeled matrix
  METHODOLOGY.md                  what is measured, what is modeled, every assumption and its bias
  backlogs/<name>/backlog.jsonl   the published backlog set (schema: backlogs/SCHEMA.md)
  pilot-backlogs/                 candidate pool, gitignored, never pushed
  run.sh                          driver: backlog x arm x rep -> worktree -> arm -> verify -> record
  validate-backlog.sh             offline fail-to-pass gate; decides which backlogs are eligible
  arms.sh                         the three arm shapes
  record.sh                       result events -> results.jsonl rows
  rollup.mjs                      results.jsonl -> the three metric cuts, selection, headline
  fixtures/                       canned streams, the replay fixture fleet, golden results
  results/<run-id>/               results.jsonl + session logs, gitignored
```

## Arms

| Arm | Shape |
|---|---|
| `vanilla` | One `claude -p` session for the whole backlog, headless default model, in a fresh worktree of the pinned ref. Prompt is the backlog verbatim. |
| `shiploop` | The real `templates/govern/run-loop.sh` over a `queue/tickets.md` seeded with the same backlog, in a scaffolded throwaway workspace, defaults on. Cost is everything the loop spends: driver, scouts, workers, escalations. |
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
`output_tokens` snapshots (which undercounts real output by a median of 33x) is not what produced
the shiploop arm.
