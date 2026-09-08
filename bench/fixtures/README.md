# bench/fixtures

Canned inputs so the whole `templates/govern/test/test-bench-*.sh` suite runs with zero spawns and
zero spend. Two families live here.

## Live A/B harness fixtures

Canned `claude -p --output-format stream-json` streams for `bench/run.sh --dry-run`.

| File | Stands in for |
|---|---|
| `vanilla-session.jsonl` | the one long session the `vanilla` arm runs over a whole backlog |
| `shiploop-driver.jsonl` | the governor driver session the `shiploop` arm spawns |
| `shiploop-worker.jsonl` | one fresh-context worker session inside the `shiploop` arm |
| `partial-no-result.jsonl` | a session hard-killed before it emitted a `result` event |
| `selection-results.jsonl` | five backlogs: three comparable with different deltas, one whose vanilla arm failed to clear, one capped |

The numbers in these five are synthetic and arithmetically convenient. They carry no claim about
real runs and nothing published may be computed from them.

## Replay fixtures

| Path | What it is |
|---|---|
| `make-replay-fixture.mjs` | the generator. Everything below is produced by it, and it is the only place the numbers are written down |
| `replay-fleet/` | a synthetic fleet workspace: `logs/govern/run-20260101-000000/ticket-1NN/worker.jsonl` plus `governor/ticket-history.jsonl` |
| `replay-empty-fleet/` | a workspace with a `logs/govern` directory and nothing in it |
| `golden-results.jsonl` | the same four sessions expressed as a `results.jsonl` for the rollup test |

Regenerate with `node bench/fixtures/make-replay-fixture.mjs`. It rewrites `replay-fleet/`,
`replay-empty-fleet/` and `golden-results.jsonl` together, so they can never drift apart.

### Why these fixtures replaced the old golden file

The previous `golden-results.jsonl` hardcoded a $24.00 vanilla arm against a $3.70 shiploop arm, an
84.6% saving that was invented to be easy to divide. Nothing had measured it and nothing had modeled
it. A test asserting that number reads as a result even when a comment says it is not one.

These fixtures carry the shape of the real corpus instead: a result event with a full `usage`
object, 1-hour cache writes only, `modelUsage` per model, and per-assistant-event `output_tokens`
that are truncated snapshots rather than a running total. The vanilla row in `golden-results.jsonl`
is now `bench/replay.mjs`'s own 1M-context model of the same four sessions, and every row carries
`provenance: "measured"` or `provenance: "modeled"`. No test in the suite asserts a headline that
was made up.

They are still not measurements. They are a synthetic corpus chosen so the expected output is
derivable by hand, which is the point of the table below.

### The derivation

Every turn's **context** is `input + cacheRead + cacheCreation` and is stated directly by the
generator. Turn 1 primes the session: input 10,000, cache write 12,000, the rest cache read. Every
later turn: input 0, cache write 5,000, the rest cache read.

| Ticket | Model | Turn contexts | input | cache write | cache read | output | total | cost |
|---|---|---|---|---|---|---|---|---|
| 101 | opus | 50k .. 400k, 8 turns | 10,000 | 47,000 | 1,743,000 | 40,000 | 1,840,000 | $2.3915 |
| 102 | opus | 50k .. 300k, 6 turns | 10,000 | 37,000 | 1,003,000 | 30,000 | 1,080,000 | $1.6715 |
| 103 | opus | 50k .. 250k, 5 turns | 10,000 | 32,000 | 708,000 | 20,000 | 770,000 | $1.2240 |
| 104 | sonnet | 300k, 500k, 700k | 10,000 | 22,000 | 1,468,000 | 25,000 | 1,525,000 | $0.6516 |
| 105 | opus | one turn, no result event | | | | | excluded | excluded |

Shiploop arm: **5,215,000 tokens, $5.9386.** Each ticket's `total_cost_usd` is set to exactly what
the published rates give, so the reconciliation ratio pins at 1.000 and a rate-table regression
shows up as a drift rather than as nothing.

Carry is last turn context minus first: 101 leaves 350,000, 102 leaves 250,000, 103 leaves 200,000.
So the carry arriving at each ticket is 0, 350,000, 600,000 and 800,000.

Per turn the modeled session re-reads `min(carry, window - turn context)`, and every session after
the first refunds its 12,000-token re-prime:

| Arm | 102 | 103 | 104 | carry re-read | refund | vanilla tokens | vanilla cost |
|---|---|---|---|---|---|---|---|
| `200k` | 300,000 | 300,000 | 0 | 600,000 | 36,000 | 5,779,000 | $5.9506 |
| `1m` | 2,100,000 | 3,000,000 | 1,500,000 | 6,600,000 | 36,000 | 11,779,000 | $8.5006 |
| `uncapped` | 2,100,000 | 3,000,000 | 2,400,000 | 7,500,000 | 36,000 | 12,679,000 | $8.6806 |

Which gives the figures the tests assert:

| Arm | tokens | cost |
|---|---|---|
| `200k` | 9.8% fewer | 0.2% lower |
| `1m` | 55.7% fewer | 30.1% lower |
| `uncapped` | 58.9% fewer | 31.6% lower |

The 200k arm barely moves because ticket 104's own turns already exceed a 200k window, leaving no
room for carry at all. That is the same lower-bound behavior the real corpus shows, and it is why
`bench/METHODOLOGY.md` reads the 200k arm as a floor rather than an estimate.

Two properties the fixture exists to lock:

- **Ticket 101 saves exactly 0%.** Nothing has been carried into it. Any model that reports a
  saving on the first ticket of a run is wrong.
- **Summing the stream is a trap.** Every assistant event reports `output_tokens: 4`, three events
  per turn, 22 turns: 264 in total against a real 115,000. A tool that sums the stream reports
  5,100,264 shiploop tokens instead of 5,215,000 and publishes a saving that is not there.
