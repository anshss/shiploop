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

## The pairing method, in one paragraph

`bench/rollup.mjs` analyses EVERY backlog — there is no ranking, no floor, no "keep the best N"
selection any more. The pairing unit is **(backlog, rep)**: a pair exists when both arms have a
completed cell for the same backlog and rep. Exclusion is symmetric (drop the whole pair, never one
arm) and listed with its reason (`capped`, `void-no-activation`, or `error`).

The **statistical unit is the backlog**, not the pair: a backlog's included reps fold into one mean
per arm before the relative delta is taken, `(mean_shiploop - mean_vanilla) / mean_vanilla`, so a
backlog run many times cannot out-vote one run only once. For every metric, the rollup reports the
median across backlog-level deltas, a 95% bootstrap confidence interval of that median (fixed seed,
10000 resamples — the same input file always reproduces the same interval), and a two-sided
Wilcoxon signed-rank p-value (exact for n <= 25 backlogs, normal approximation with tie correction
above); n is the count of backlogs with at least one usable rep, never the count of pairs. A losing
backlog stays in the cost/token comparison; only quality is gated on whether a ticket actually
cleared, and there too the unit is the backlog: a ticket counts as cleared by an arm only if a
strict majority of that backlog's own reps cleared it. This is the JetBrains-SkillsBench-style
shape (paired tasks, a median over backlog-level deltas, a significance test, a smoke-then-full
ladder) rather than a self-selected scoreboard.

## What is measured, and where it comes from

Per arm, off that session's own `"type":"result"` event: the four-way token breakdown,
`total_cost_usd`, and (in the with-shiploop arm) `subagent_stats` and, when
`--forward-subagent-text` is supported, per-subagent `message.usage` / `message.model`. The token
breakdown is summed across every entry in that event's `modelUsage` map when the map is present and
non-empty, falling back to the plain `usage` field only when it is not (see "`.usage` counts the
session's own turns only" below for why `usage` alone is not the complete figure). Nothing is
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

### `.usage` counts the session's own turns only, `modelUsage` counts everything

A session's `usage` field on its own `"type":"result"` event is scoped to that session's own
turns. It does not include a subagent spawned through the Agent tool, because a subagent's turns
are billed on the SAME session (there is no separate stream for it to appear in) but the session's
own running `usage` counter never adds them in. `modelUsage`, a separate map on the same event keyed
by model, does: it aggregates every model call the billing period touched, subagent turns included,
and its own per-model `costUSD` entries sum to `total_cost_usd` exactly, which is the check that
catches a divergence: a vanilla arm with no subagents shows `usage` and summed `modelUsage`
agreeing to a haiku sliver of incidental side traffic, while a with-shiploop arm that spawns several
subagents shows `usage` far short of the summed figure while `total_cost_usd` still tracks it.
`govern::stream_usage` sums `modelUsage` for the token total whenever the map is present and
non-empty, and reads `usage` directly only as a fallback for a stream that never populated it.

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

- **Do not split the headline BY model tier.** A session's `modelUsage` map is keyed by model and
  absorbs incidental side calls — a haiku entry has been observed with real input tokens in a
  session whose worker ran on opus, so a per-tier breakdown ("the opus share was X") would silently
  fold that side call into the wrong tier. This forbids the SPLIT only. The SUM across every tier
  is a different operation, corroborated by `total_cost_usd` (a session's summed per-model `costUSD`
  equals its `total_cost_usd` exactly), and it is what the headline token number reads, see
  "`.usage` counts the session's own turns only" above. `modelUsage`'s per-tier breakdown remains
  attribution-only (the advisor/worker split inside the treatment arm), never a headline by itself.
- **Do not sum per-turn usage as a session total.** Per-turn output rows have been observed to sum
  to roughly a tenth of a session's own `result`-event total. The result event is authoritative;
  a sum over the stream is not a fallback, it is a different, wrong number.

## Attribution inside the with-shiploop arm

Never the headline — the cost and token numbers above come from the arm's own `result` event
regardless of whether any of this succeeds.

- **`subagent_stats`** (`spawned`/`completed`/`failed`/`killed`/`refused{depth_limit,concurrency_limit,budget}`/`by_type`)
  is read for attribution and logged when it disagrees with the activation check below
  (`bench::stream_had_subagent_activity`, `bench/record.sh`). A subagent refused for zero tools, or
  a treatment arm that never spawned one at all, still exits 0 with `is_error:false` — the exit code
  alone cannot tell "measured something" from "measured nothing."
- **The activation check** is the stronger, enforced signal: `bench::stream_worker_spawn_count`
  (`bench/record.sh`) counts Agent/Task `tool_use` invocations directly in the advisor's own
  stream, never `subagent_stats`'s self-report alone. `run.sh`'s main loop forces a shiploop cell
  with zero to `status: "void-no-activation"` — excluded from every metric and named in the paired
  report's own Activation section, the same way a capped cell is excluded and named, rather than
  aborting the whole run the way an earlier design's hard stop did.
- **Forwarded subagent turns** (`--forward-subagent-text`, tagged `parent_tool_use_id`, each with
  its own `message.usage` / `message.model`) give the advisor/worker split. Gated behind a cached
  `claude --help` probe, an env kill switch, and a HARD STOP (not a degraded arm) when unsupported —
  see `README.md`.
- **Lever events** (`logs/govern/<run>/lever-events.jsonl`, contract in `bench/LEVER-EVENTS.md`) are
  read against an explicit three-name allow-list, counting a malformed line and an unrecognized event
  name separately rather than dropping either. This is a COUNT, not a price: there is currently no
  live per-class token-estimate table anywhere in this repository, so a lever's occurrence count is
  reported, never converted into a credited token or dollar figure. See `bench/KNOWN-LIMITS.md`.

## Why the driver's own tokens are no longer a separate bias

An earlier version of this design read worker transcripts only, so the session that turned a
conversation into tickets, decided scope, and reviewed PRs was invisible to it — a bias that grew
as the harness got better at delegating instead of doing the work itself. The rebuilt design closes
that gap for COST: the with-shiploop arm's measured `result` event IS the advisor session's own
event, so `total_cost_usd` already prices every worker subagent it spawned, in the same session,
with no separate accounting step. TOKENS need a second read to reach the same completeness: the
event's plain `usage` field counts the advisor session's own turns only and says nothing about a
subagent's, so the token total comes off `modelUsage` (summed across every model entry) instead,
which is complete in the same way `total_cost_usd` already was. There is no longer a separate "was
the driver counted" question to ask, for cost or for tokens.

## Quality is checked by a mechanical oracle, pass/fail only, and reported separately from cost

Unlike a purely transcript-derived model, this design can and does check whether a ticket was
actually resolved: `verify_cmd` is run against the arm's own tree once the arm finishes, nothing
patched in first. See "Verification" in `README.md`. This is PASS/FAIL against one mechanical
oracle, never a quality score, and it is reported as its OWN section, never blended into the cost
cut: a losing backlog (either arm fails to fully clear it) still contributes its cost and token
deltas to the paired report — dropping it would let a benchmark quietly average over only the
comparisons that happened to go well. `bench/rollup.mjs`'s quality section instead compares,
per-ticket, cleared-by-vanilla against cleared-by-shiploop across every included pair, reports each
arm's clear rate and the better/worse/same counts, and runs an exact two-sided sign test over the
discordant tickets — the one place in this report a quality claim gets its own significance test,
separate from the cost/token deltas' Wilcoxon test.

## Dose response is descriptive, not a claim

`bench/rollup.mjs` also buckets the median cost delta by the shiploop arm's own worker-spawn count
and by the backlog's ticket count, printed as a small table with no significance test attached. This
is a hint for where to look next (does delegating more move the number, does a longer backlog),
never a finding — the n in any one bucket is typically small enough that a bucket-level test would
overclaim.

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
for a longer, curated backlog (see "There is no published live backlog yet" in
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

## The smoke gate: a live run bigger than one cell must already be proven at this hub sha

A LIVE (non-dry) run with more than one (backlog x rep) cell refuses to start unless
`BENCH_SMOKE_RUN=<run-id>` names a prior results dir, recorded at THIS SAME hub git sha (`git
rev-parse HEAD`, stamped as `hubSha` on every rollup row), whose every cell completed
(`resolved`/`failed`, never `capped`) and whose shiploop cell(s) actually activated
(`workerSpawns > 0`). A run of exactly one backlog and one rep IS a smoke run itself and needs no
gate — there is nothing bigger it could be proving the pipeline for. `BENCH_SKIP_SMOKE_GATE=1` is
the deliberate override, recorded into the run's own `kind:"meta"` row so a run without proof is
never silently indistinguishable from one with it.

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
bash bench/run.sh --dry-run                        # zero spend, canned fixtures for both arm shapes
bash bench/run.sh --backlog <one-name> --run-id smoke   # 1-backlog, 1-rep smoke — no gate needed
BENCH_SMOKE_RUN=smoke bash bench/run.sh --reps 2   # the real run, gated on that smoke run
node bench/rollup.mjs                              # paired median/CI/p per metric, plus the headline
```

There is no published headline to recompute right now: no curated backlog exists yet
(`bench/KNOWN-LIMITS.md`), so there is nothing behind a committed `results.jsonl` for this to
reproduce.
