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
| `make-lever-fixture.mjs` | the generator for the multi-lever fixture below. Same rule: the numbers live here and nowhere else |
| `replay-lever-fleet/` | a three-session run with three tiers, an orchestration transcript, a driver-model stamp, a killed session, a `lever-events.jsonl`, and a second run that aborted pre-flight |
| `golden-results.jsonl` | the same four sessions expressed as a `results.jsonl` for the rollup test |
| `make-outcome-fixture.mjs` | the generator for the attempt-outcome fixture below |
| `replay-outcome-fleet/` | three tickets exercising spawn-worker.sh's per-attempt ledger (`attempts.jsonl`): a two-attempt retry with the ledger present, a single attempt classified `infra`, and a ticket with no ledger at all |

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

## The multi-lever fixture (`replay-lever-fleet`)

Built for `templates/govern/test/test-bench-levers.sh`, which asserts the whole
`2 baselines x 3 arms x 2 partials` matrix exactly. Regenerate with
`node bench/fixtures/make-lever-fixture.mjs`.

Run `run-20260201-000000`, stamped shiploop `1.19.0`, `driver-model` = `claude-opus-4-8` (so the
driver tier is RESOLVED, not guessed from the highest tier present). A second run
`run-20260202-000000` holds a 0-byte `state.jsonl` and nothing else: a pre-flight abort.

| Session | Tier | Turn contexts (input / write / read) | billed | tokens | cost |
|---|---|---|---|---|---|
| ticket-201 worker | sonnet | 100k (10k/20k/70k), 200k (0/0/200k) | in 10k, out 10k, read 270k, write 20k | 310,000 | $0.254 |
| ticket-202 worker | haiku | 100k (10k/0/90k), 100k (0/0/100k) | in 10k, out 10k, read 190k, write 0 | 210,000 | $0.079 |
| ticket-203 worker | sonnet | 50k (10k/10k/30k), no result event | in 10k, out 0, read 30k, write 10k | 50,000 | recovered |
| governor (orchestration) | opus | 20k (20k/0/0) | in 20k, out 5k | 25,000 | $0.225 |

`lever-events.jsonl` carries one of each contract event, plus the three things a reader must
survive: an event name it does not know, a `scripted-action` class it has no estimate for, and a
line that is not JSON.

| Event | Payload | Credit |
|---|---|---|
| `watchdog-kill` | sonnet, `ctxTokens` 300,000 | 200,000 tokens on the `200k` arm (the window caps it), 300,000 on the others |
| `resume` | haiku, checkpoint 10,000 vs fresh 60,000 | 50,000 tokens |
| `scripted-action` | class `version-bump` (a real scout `DET_KIND`) | 45,000 tokens, the published per-class floor |
| `scripted-action` | class `not-a-known-class` | zero, counted, and named in the report |
| `escalation` | failed tier haiku, 50,000 tokens | -$0.20 against the routing credit (the opus/haiku input spread) |

### The derivation

Carry: 201 leaves 100,000 (200k last turn minus 100k first), 202 leaves 0. So 202 is charged
100,000 on each of its two turns and 203 is charged 100,000 on its one turn; no arm's window binds
any of them. The only re-prime refund is 203's 10,000 first-turn write (202's is zero).

| | `--partials drop` | `--partials price` |
|---|---|---|
| shiploop tokens (incl. 25,000 orchestration) | 545,000 | 595,000 |
| carry tokens (re-read less refund) | 200,000 | 290,000 |
| vanilla tokens, `200k` | 1,015,000 | 1,155,000 |
| vanilla tokens, `1m` / `uncapped` | 1,115,000 | 1,255,000 |

Cost, on the headline cell (`driver-tier` x `200k` x `price`): shiploop $0.624 (work $0.399 plus
$0.225 of orchestration), vanilla $2.2525, which is a 72.3% reduction. Component by component:
carry $0.05, routing $0.796, cache-prefix $1.140, watchdog $0.04, resume $0.005, skip-the-model
$0.0225, escalation -$0.20, harness overhead -$0.225. Those eight sum to $1.6285, and $0.624 plus
$1.6285 is $2.2525: the additivity the report asserts on every run.

Two properties this fixture exists to lock, beyond the arithmetic:

- **Tokens are identical under both baselines.** Routing changes what tokens COST, never how many
  there are, and the test asserts that as an identity across all six arm/partials pairs.
- **Uninstrumented is not zero.** `replay-fleet` carries no `lever-events.jsonl`, so the same four
  levers must read `uninstrumented` there while reading measured here.

## The attempt-outcome fixture (`replay-outcome-fleet`)

Built for `templates/govern/test/test-bench-outcome.sh`, which asserts the "present class, absent
class" contract for `outcomeBreakdown()` (queue #108, "no attempt-outcome dimension"). Regenerate
with `node bench/fixtures/make-outcome-fixture.mjs`.

Three tickets in `run-20260301-000000`, each exercising a different state of spawn-worker.sh's
per-attempt ledger (`attempts.jsonl`, sibling of the transcript):

| Ticket | Attempts | Ledger | Classification |
|---|---|---|---|
| `ticket-701` | 2: `worker.attempt1.jsonl` then `worker.jsonl` | present, both rows | attempt 1 `first-attempt` (36,000 tokens), attempt 2 `judgment` (47,000 tokens) |
| `ticket-702` | 1: `worker.jsonl` | present, one row | `infra` (29,000 tokens) -- proves a class other than the first two sorted alphabetically is actually read off the ledger |
| `ticket-703` | 1: `worker.jsonl` | absent (no `attempts.jsonl` at all) | `unclassified`, reason `no-ledger` (21,000 tokens) |

This is deliberately NOT a numeric-derivation fixture the way `replay-fleet` and
`replay-lever-fleet` are: only the classification path is under test, so token counts are small
and arbitrary rather than chosen to land on a checkable percentage. `ticket-701` is the shape that
matters most -- it is the ordinary retry, and it is what proves `worker.jsonl` always resolves to
the ledger's own highest attempt number rather than a hardcoded one.
