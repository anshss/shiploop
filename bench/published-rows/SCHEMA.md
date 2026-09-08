# bench/published-rows

Empty on purpose. **No benchmark number is published from this repository right now.**

## Why there is nothing here

A published row set is the evidence behind a performance claim, and the claim would not survive
contact with how the corpus was actually collected:

- **Nothing is instrumented.** Four of the levers the bench attributes savings to (`watchdog`,
  `resume-not-restart`, `skip-the-model`, `escalation-correction`) are read from
  `logs/govern/<run>/lever-events.jsonl`. That emitter ships default OFF (`GOVERN_LEVER_EVENTS=0`)
  and has not run anywhere, so every existing run is uninstrumented and those four levers are
  uncredited.
- **The driver tier was never recorded.** The default `driver-tier` baseline needs to know which
  model dispatched a run. No run in any existing corpus carries a `driver-model` stamp, so the tier
  falls back to "the highest tier seen in the run" almost every time. That fallback is a guess, and
  it is a guess in the direction that flatters the harness.
- **The harness's own overhead is mostly invisible.** Orchestration transcripts are charged into the
  shiploop arm, but almost no run wrote one, so nearly every run is `overhead-uncovered` and the
  shiploop-side cost is a lower bound rather than a measurement.

A number computed on that corpus today measures the instrumentation gap, not the product. So none is
published, quoted, or committed.

## What has to happen first

1. The lever-event emitter merges and is switched on.
2. Runs accumulate, on a version that stamps both `shiploop-version` and the driver model.
3. Only then does anyone run `bench/replay.mjs` for a number, and publish the rows behind it here.

## The row shape, for when that happens

`node bench/replay.mjs --rows` writes one JSON object per line, one line per (run, ticket position),
per arm. Identifiers are hashed: no workspace path, fleet name or internal ticket id survives.

| Field | Type | Notes |
|---|---|---|
| `arm` | string | `200k`, `1m` or `uncapped` |
| `baseline` | string | `same-mix` or `driver-tier` |
| `run` | string | 16 hex chars, sha256 of `<fleet>#<run>`, stable within one file only |
| `version` | string | the run's stamped shiploop version, or `unknown` |
| `ts` | string, null | the run directory's `YYYYMMDD-HHMMSS`, or null if it does not parse |
| `position` | integer | the ticket's depth in its run, 1-based. Position 1 always saves 0% |
| `counted` | boolean | whether `--scope` counted this ticket in the totals |
| `sessions` | integer | sessions that fed this row |
| `shipTokens`, `shipCostUsd` | number | the measured arm |
| `vanillaTokens`, `vanillaCostUsd` | number | the modeled arm |

Aggregating a rows file back into a percentage needs neither the transcripts nor `replay.mjs`:

```bash
node bench/replay.mjs --rows-file bench/published-rows/<file>.jsonl --json
```

and the same arithmetic in `jq`, so a reader never has to trust the tool's own aggregation:

```bash
jq -s '
  group_by(.arm)[] |
  {
    arm: .[0].arm,
    tokenReductionPct: ((([.[]|.vanillaTokens]|add) - ([.[]|.shipTokens]|add)) / ([.[]|.vanillaTokens]|add) * 100),
    costReductionPct:  ((([.[]|.vanillaCostUsd]|add) - ([.[]|.shipCostUsd]|add))  / ([.[]|.vanillaCostUsd]|add)  * 100)
  }
' bench/published-rows/<file>.jsonl
```
