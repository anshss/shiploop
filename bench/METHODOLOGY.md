# bench/METHODOLOGY.md

How the live A/B harness (`bench/run.sh`, `bench/arms.sh`, `bench/record.sh`, `bench/rollup.mjs`)
measures a backlog run, what it actually reads off a session, and every rail that keeps the
comparison fair.

Read this before quoting a percentage from this repository.

## The one-sentence version

**Both arms are measured. Nothing is modeled.** The with-shiploop arm and the without-shiploop arm
are both real `claude -p` sessions, spawned the same way, over the same backlog, and the only
architectural difference between them is which directory the session opens in.

This is a change from an earlier design in this directory, which computed a *counterfactual*: an
estimate of what an un-run vanilla session would have cost, derived from a real shiploop session's
own transcripts. That path is retired. Several of shiploop's own levers work by making a model call
*not happen* (a deterministic apply that skips a worker entirely, a filter that never transmits
passing output, a trim that never sends a schema at all), and an absence leaves no trace in a
transcript to model from. Running both arms for real is the only way to see the combination.

## What is measured, and where it comes from

Per arm, off that session's own `"type":"result"` event: `usage` (the four-way token breakdown),
`total_cost_usd`, and (in the with-shiploop arm) `subagent_stats` and, when
`--forward-subagent-text` is supported, per-subagent `message.usage` / `message.model`. Nothing is
re-priced from a hand-maintained rate table: both arms report their own real `total_cost_usd`
directly from the CLI, so there is no modeling step where a table could go stale.

### The result-event gotcha

The streamed per-`assistant`-event `usage.output_tokens` is a **truncated running snapshot**. It
does not accumulate across content blocks, and summing it is wrong by more than an order of
magnitude — measured on real corpora, the result event's own output divided by the summed stream
snapshots has run past 30x on individual sessions. Any tool that sums the stream will report an
arm that is almost entirely free, and will publish a saving that does not exist.

`govern::stream_usage` (`templates/govern/lib/common.sh`), the ONE parser `bench::session_row`
(`bench/record.sh`) uses, therefore reads billed usage from the LAST `"type":"result"` event only.
When a session was killed before it emitted one, tokens are recovered from the per-turn assistant
events instead (`usageSource: "assistant-partial"`) — the INPUT side of that recovery is exact
(summed per-turn context reproduces a result event's own totals to the token), but the OUTPUT side
is not, because it is exactly the truncated-snapshot sum described above. `costUsd` is never
fabricated in this case: it stays `null`, never a confident zero. `templates/govern/test/test-bench-schema.sh`
case 7 asserts this against a real killed-session fixture, by number, not by intent.

### Two token cuts, never blended

`bench/rollup.mjs` reports two readings of the same token counts, and states which one it used:

| Cut | Formula | What it says |
|---|---|---|
| billable | input + output + cache creation | charges cache reads at nothing — the conservative reading |
| all-in | every token the API moved (input + output + cache read + cache creation) | the full traffic |

Neither is "the" token number; the report always states which one produced a given figure. The two
can disagree in SIGN: a run of fresh per-ticket sessions can WRITE more cache than one long session
does (each fresh context re-primes), so the billable cut can show more tokens even while the all-in
cut shows fewer. `bench/rollup.mjs` prints a negative cut as "X% MORE", never dressed as "fewer".

### Two rules for what NOT to do with usage

Both derived from live probes against a real corpus, not assumed:

- **Do not split the headline by model tier.** A session's `modelUsage` map is keyed by model and
  absorbs incidental side calls — a haiku entry has been observed with real input tokens in a
  session whose worker ran on opus. `modelUsage` is read for attribution (the advisor/worker split
  inside the treatment arm), never for the headline cost or token number, which always come off the
  session's own aggregate `usage` / `total_cost_usd`.
- **Do not sum per-turn usage as a session total.** Per-turn output rows have been observed to sum
  to roughly a tenth of a session's own `result`-event total. The result event is authoritative;
  a sum over the stream is not a fallback, it is a different, wrong number.

## Attribution inside the with-shiploop arm

Never the headline — the cost and token numbers above come from the arm's own `result` event
regardless of whether any of this succeeds.

- **`subagent_stats`** (`spawned`/`completed`/`failed`/`killed`/`refused{depth_limit,concurrency_limit,budget}`/`by_type`)
  is asserted directly: `spawned > 0 && completed > 0`, or the cell is rejected outright
  (`bench::stream_had_subagent_activity`, `bench/record.sh`). A subagent refused for zero tools, or
  a treatment arm that never spawned one at all, still exits 0 with `is_error:false` — only this
  field can tell "measured something" from "measured nothing."
- **Forwarded subagent turns** (`--forward-subagent-text`, tagged `parent_tool_use_id`, each with
  its own `message.usage` / `message.model`) give the advisor/worker split. Gated behind a cached
  `claude --help` probe, an env kill switch, and a HARD STOP (not a degraded arm) when unsupported —
  see `README.md`.
- **Lever events** (`logs/govern/<run>/lever-events.jsonl`, contract in `bench/LEVER-EVENTS.md`) are
  read against an explicit five-name allow-list, counting a malformed line and an unrecognized event
  name separately rather than dropping either. This is a COUNT, not a price: there is currently no
  live per-class token-estimate table anywhere in this repository, so a lever's occurrence count is
  reported, never converted into a credited token or dollar figure. See `bench/KNOWN-LIMITS.md`.

## Why the driver's own tokens are no longer a separate bias

An earlier version of this design read worker transcripts only, so the session that turned a
conversation into tickets, decided scope, and reviewed PRs was invisible to it — a bias that grew
as the harness got better at delegating instead of doing the work itself. The rebuilt design does
not have this gap: the with-shiploop arm's measured `result` event IS the advisor session's own
event, so its specification, dispatch, and review tokens are counted by construction, in the same
number as every worker subagent it spawned. There is no longer a separate "was the driver counted"
question to ask.

## Quality is checked by a mechanical oracle, pass/fail only

Unlike a purely transcript-derived model, this design can and does check whether a ticket was
actually resolved: `verify_cmd` (the test the merged upstream PR made pass) is run against the
arm's own tree, after the golden `test_patch` (test-file changes only) is applied. See "Verification"
in `README.md`. This is PASS/FAIL against one mechanical oracle, never a quality score, and a
backlog either arm fails to fully clear is dropped from the published set rather than counted as a
partial success.

## The ceiling

Output is a cost no architecture removes. The work still has to be written, and the with-shiploop
arm writes the same code a single session would. So the maximum reduction either arm's own number
could show is the point where everything except output has gone to zero — output is a large share
of a session's cost (billed well above input and cache-read rates), so the cost ceiling in
particular sits well under 100%. A reduction that would require removing the writing itself is
arithmetically impossible, not merely impressive, and any future report should print this ceiling
next to a headline for exactly that reason.

## Backlog depth, not the harness, dominates a short run

The effect a comparison can show grows with how much work a backlog actually contains: a
single-ticket backlog gives shiploop's context-carrying and routing levers almost nothing to act on,
and the variance on a short run is largest exactly where the effect is smallest. This is an argument
for a longer, curated backlog (see "There is no published (6+ ticket) live backlog yet" in
`bench/KNOWN-LIMITS.md`), not for reverting to a modeled counterfactual.

## The live harness's per-session ceiling

`bench/run.sh` and `bench/arms.sh` need a hard per-session ceiling on every spend-bearing session,
in BOTH arms: an always-on rail, not an option. The ceiling is `--max-turns`, gated on a cached
`claude --help` probe (`govern::claude_supports_max_turns` in `templates/govern/lib/common.sh`). A
later CLI release (observed: claude 2.1.246) dropped `--max-turns` entirely and ships
`--max-budget-usd`, a per-session dollar cap, in its place; the harness probes for `--max-turns`
FIRST and falls back to `--max-budget-usd` (`govern::claude_supports_max_budget_usd`, same
cached-probe pattern) only when turns support is absent. A CLI with neither flag is a hard stop:
`BENCH_ALLOW_UNCAPPED_TURNS=1` is the only, deliberate, operator override.

**The ceiling is EQUAL on both arms**, `BENCH_TURNS` (default 200) / `BENCH_SESSION_USD` (default
the run's own `BENCH_MAX_USD`). This is a deliberate change from an earlier, asymmetric design
(vanilla capped at 200 turns for a whole backlog, a worker capped at 80 turns per ticket): now that
each arm is exactly one whole-backlog session, there is no shape-specific reason left for one arm's
ceiling to bind tighter than the other's, and an unequal ceiling would itself silently rig the
comparison.

**A session truncated by its own cap is not a loss for one arm and not a win for the other.**
`bench::stream_hit_session_cap` (`bench/record.sh`) reads the truncated session's `"type":"result"`
event and detects the CLI's own `error_max_*` subtype (covering both `error_max_turns` and the
budget ceiling's matching subtype, by prefix rather than an exact string, so either ceiling is
caught without a version compare). `run.sh` checks every session stream in a cell for this BEFORE
deriving a status from ticket completion; a cell containing even one capped session is forced to
`status: "capped"`, overriding whatever `resolved`/`failed` the ticket count alone would have given
it, and `bench/rollup.mjs` drops a capped backlog from the published set the same way it drops one
that hit the run-level `BENCH_MAX_USD` cap.

## An empty backlog gets its own status, never "resolved"

A backlog with zero tickets makes a naive `cleared == total` comparison read `0 == 0`, which is
indistinguishable from a cell that actually cleared everything. `run.sh`'s main loop checks the
ticket count before that comparison and records `status: "no-tickets"` instead, so a cell that
measured nothing can never be read as a successful run. `bench::validate_backlog` also logs a
warning up front when it discovers a zero-ticket backlog, once per backlog rather than once per
cell.

## Rows integrity

Every `kind:"rollup"` row `bench::record_rollup` writes carries a `checksum`: a hash over just that
row's own numeric fields (turns, the token breakdown, cost, session counts, tickets
cleared/total). A row with no `checksum` (any fixture predating this) is unverified, not invalid.
This exists so a hand-edited `results.jsonl` cannot regenerate a self-consistent false table: the
numbers and the checksum would disagree.

## Cost figures and account type

Every cost figure comes from `total_cost_usd` on the session's `result` event, which is API-list-rate
denominated regardless of how the CLI is authenticated. On a subscription those dollars are a proxy
for quota burn; on an API key they are the invoice. A published figure would be a percentage, so it
is identical in both worlds, but the absolute dollars are not anyone's literal bill.

## What is not measured at all

- **Wall-clock time.** Nothing here measures how long anything took, and no throughput or speed
  claim in this repository is supported by this benchmark.
- **Subscription quota directly.** Every dollar figure is API list rate; see "Cost figures" above.
- **Anything outside the tool-call surface bench can see.** A worker's own `Bash` tool could reach
  the network directly; see the offline-guard limits in `bench/KNOWN-LIMITS.md`.

## Reproducing a run

```bash
bash bench/run.sh --dry-run          # zero spend, canned fixtures for both arm shapes
bash bench/run.sh --reps 2           # the real run over the published backlog set
node bench/rollup.mjs                # the three metric cuts, selection, headline sentence
```

There is no published headline to recompute right now: no curated 6+ ticket backlog exists yet
(`bench/KNOWN-LIMITS.md`), so there is nothing behind a committed `results.jsonl` for this to
reproduce.
