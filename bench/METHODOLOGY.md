# bench/METHODOLOGY.md

How `bench/replay.mjs` produces shiploop's headline number, what part of it is measured, what part
is modeled, and every place the model could be wrong.

Read this before quoting a percentage from this repository.

## The one-sentence version

**The shiploop arm is measured. The vanilla arm is modeled. No vanilla session was ever run.**

The published *best-case* number is a *counterfactual*: an estimate of what the same backlog would
have cost inside one long Claude Code session, computed from what the shiploop sessions actually
did. It is not a measurement of two things that both happened.

`bench/run.sh` HAS now been executed against a real (if small, private, pilot-scale) backlog —
`bench/README.md`'s "Path 2" section and `bench/KNOWN-LIMITS.md` carry that result and its caveats
in full. This section's counterfactual model is still what produces the larger, published
best-case number below, over the much larger real-fleet corpus.

This distinction is the whole reason the document exists. A tool's self-reported saving is a claim
about its counterfactual, not about anyone's bill. `replay.mjs` prints that on its own first line,
in the default human output, not in a footnote.

## What is measured

Every number on the shiploop side comes from transcripts the governor already wrote:

- `<fleet>/logs/govern/**/*.jsonl` (worker sessions, and the `attempt*` variants an escalation
  produces), excluding `state.jsonl`, which is bookkeeping rather than a transcript.
- `<fleet>/governor/ticket-history.jsonl` for per-ticket status and completion order.

Per session, billed usage is taken from the `{"type":"result"}` event's `usage` object, and nothing
else: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.

### The result-event gotcha

The streamed per-`assistant`-event `usage.output_tokens` is a **truncated running snapshot**. It
does not accumulate across content blocks, and summing it is wrong by more than an order of
magnitude. Measured over the 338 sessions of the largest fleet in the corpus, the result event's
output divided by the summed stream snapshots has a **median of 33.0x**, a minimum of 3.4x and a
maximum of 233.2x. One session sums to 1,368 across its assistant events while its own result event
reports 45,120. The error is not a constant, so it cannot be corrected with a multiplier.

Any tool that sums the stream will report a shiploop arm that is almost entirely free, and will
publish a saving that does not exist. `replay.mjs` therefore reads billed usage only from result
events, and `test-bench-replay.sh` asserts that specific trap is avoided by number, not by intent.

The assistant events are used for exactly one thing they are exact at: the per-turn **context**
(`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`), which is known before
generation. Summing the deduplicated per-turn context reproduces the result event's own input,
cache-read and cache-write totals to the token, which is what licenses using it.

Turns are deduplicated by `message.id`, because the stream emits one event per content block with
an identical usage snapshot. Assistant messages with `model: "<synthetic>"` and no usage (interrupt
and API-error notices the CLI injects) are dropped: nobody was billed for them.

### Sessions that are excluded

A session with no result event, or with a result event carrying no `usage` object, is **excluded**
and counted as excluded in the report. It is never priced at zero, and it is never estimated. In
the author's corpus this is a large number of sessions, mostly hub test runs and killed sessions,
and the report prints the count next to every arm so the exclusion is visible rather than buried.

## Pricing

Published Anthropic list rates, USD per million tokens. Nothing here is fitted to the data.

| Tier | Input | Output | Cache read | Cache write (1h) | Cache write (5m) |
|---|---|---|---|---|---|
| Opus | $5 | $25 | $0.50 | $10 | $6.25 |
| Sonnet | $2 | $10 | $0.20 | $4 | $2.50 |
| Haiku | $1 | $5 | $0.10 | $2 | $1.25 |

Cache read is 0.1x input, cache write is 2x input at the 1-hour TTL and 1.25x at 5 minutes. Tier is
resolved from the model name; a session's `modelUsage` map is used when present, so a session that
escalated from Haiku to Opus is priced per model rather than at one blended rate. Models whose tier
is unrecognized are priced as Opus and listed by name in the report.

Every cache write in the author's corpus is `ephemeral_1h_input_tokens`: across the 534 sessions
whose result events carry the split, 62,991,225 tokens at the 1-hour TTL and **zero** at 5 minutes.
The 1-hour multiplier therefore does all the work here; the 5-minute rate is applied pro rata where
a session mixes them, and sessions whose result event omits the split are priced at the 1-hour rate,
which is the more expensive of the two and applies to both arms equally.

**Both arms are priced from this table.** The vanilla arm has no reported cost to use, so using the
CLI's reported `total_cost_usd` for the shiploop arm and a rate table for the vanilla arm would
compare two different measuring instruments. The reported cost is used for one thing only:

### The reconciliation ratio

Per session, computed cost divided by the `total_cost_usd` the CLI itself reported. The report
prints the median and the share of sessions within 2%. Over 610 sessions in the author's corpus the
median is **1.000**, which is the evidence that the rate table above is the one being billed. A
median that drifts from 1.000 means the table is stale and every dollar figure in the report should
be discarded until it is fixed.

Roughly 20% of sessions fall outside 2%. Those are the older sessions whose result events predate
the `modelUsage` field, where the tier has to be inferred from the stream, and sessions whose cache
writes were priced across a model switch. The median is the honest statistic here; the mean is not.

## The model: what the vanilla arm is

One session, working the same run's tickets in the order they completed. Ticket order comes from
`ticket-history.jsonl` timestamps, falling back to transcript mtime when a ticket is absent from
the history (a git checkout does not preserve mtimes, which is why the timestamp is primary).

Per ticket *k*, the modeled session does the same work with one difference: **every turn of ticket
k additionally re-reads the context carried out of tickets 1..k-1**, at the cache-read rate.

- **Carry is measured, never reconstructed.** A session's residue is the growth of its own observed
  per-turn context, last turn minus first turn. It is never derived from output counts, which the
  gotcha above makes unusable, and never assumed.
- **The carry is bounded by the context window.** Per turn, the modeled session can only carry
  `min(carry, window - observed turn context)`. That is the only thing separating the arms.
- **Output is identical in both arms.** It is the same work and the same code written. It is a
  shared fixed cost and it appears in both arms in full. This is also what sets the ceiling.
- **Fresh sessions get charged for re-priming; the modeled session gets that back.** Every shiploop
  session after the first pays a first-turn cache write to load the system prompt, `CLAUDE.md` and
  the ticket text. One accumulating session pays that once, so the model refunds it from the
  vanilla arm at the cache-write rate.

### The three arms

| Arm | Window | What it represents |
|---|---|---|
| `200k` | 200,000 | a default Claude Code session, where compaction bounds how much carry can exist |
| `1m` | 1,000,000 | a session with the 1M context window, the strongest honest opponent |
| `uncapped` | none | a session that never compacts and never forgets. **Unphysical**, computed and labelled as such |

`uncapped` exists to show the size of the window's contribution, not to be quoted. It is labelled
unphysical in the tool's own output.

### The baseline axis: which model the counterfactual ran on

Added 2026-09-08 (#108). The arm above says how much a single session could CARRY. The baseline says
what MODEL it ran on. They compose into a matrix, 3 arms x 2 baselines, selected with `--baseline`.

| Baseline | The counterfactual | Default |
|---|---|---|
| `same-mix` | the same sessions at the same tiers, glued into one session | no |
| `driver-tier` | one session running entirely on the dispatching session's own tier | **yes** |

`same-mix` is the pre-#108 model, unchanged and kept: it is the arm the published 70.2/57.3 and
30.1/18.2 were computed on, and `bench/published-rows/replay-2026-09-05.jsonl` re-aggregates to
those figures to one decimal as a regression guard (`test-bench-regression.sh`).

`same-mix` has one structural blind spot, and it is the harness's most-used lever in practice:
routing work to cheaper models. Under it, a sonnet worker's tokens are priced as sonnet on BOTH
arms, so moving work off the driver's expensive tier is worth exactly zero by construction.
`driver-tier` fixes that by pricing the counterfactual at the tier the operator would actually have
been sitting on: the real alternative to the harness is one interactive session, on the model they
chose, doing everything itself.

**How the driver tier is resolved**, in order: the run's `driver-model` stamp, then the tier named
by the run's own orchestration transcript, then a FALLBACK to the highest tier any session in the
run touched. The fallback is the generous-to-shiploop choice, so the report counts how many runs
used it (`driverTierAudit.fromFallbackHighestTier`) rather than hiding it inside an average.

### Three metrics, never blended

| Metric | What moves it | What does not |
|---|---|---|
| tokens | context carried, work avoided | **routing.** A token is a token; moving work to a cheaper model cannot change this column, and the report says so where it prints it |
| cost (USD) | everything, at API list rates | nothing, which is why it is the most fragile of the three |
| quota-weighted tokens | tokens x the tier's input-rate ratio (opus 5x, sonnet 2x, haiku 1x) | the dollar rate table's absolute level |

Quota-weighted tokens are the subscription framing of the routing credit: a plan meters capacity,
not dollars, and an opus token eats five haiku tokens' worth of it. The weights are the published
input-rate ratios and are printed in the report header next to the number that used them. They are
labelled `quota-weighted` everywhere and are never added to, or presented as, raw tokens.

### Per-lever attribution

The report decomposes each arm's saving into additive components and asserts internally that they
sum to it (`leverSumCheck` in the JSON, `sum check:` in the report). A component is one of:

| Lever | How it is credited |
|---|---|
| carry | the carry-read minus the re-prime refund, as before |
| routing | the measured work repriced at the driver tier (zero under `same-mix`) |
| cache-prefix | turn-1 cache READS that would have been cache WRITES without cross-worker prefix preservation, at the 1.9x spread. Worth zero tokens: read and write are the same token count |
| watchdog | from `watchdog-kill` events: one further turn at the context reached, capped by the arm's window. A floor, not the true counterfactual |
| resume-not-restart | from `resume` events: fresh-start tokens minus what the checkpoint actually loaded |
| skip-the-model | from `scripted-action` events: a conservative per-class token estimate, table printed in the report. An unknown class is counted and credited zero |
| escalation-correction | from `escalation` events: the routing credit claimed for a failed cheap-tier attempt is taken back. Negative by construction |
| harness-overhead | the orchestration-side transcripts, charged into the shiploop arm. **Negative by construction** |
| output-suppression | **uninstrumented.** The withheld bytes are, by definition, absent from every transcript, and the wire contract (`bench/LEVER-EVENTS.md`) carries no event for them |
| shared-exploration, memory-budget, blocked-work-early-catch | **unmeasured.** Each is printed with the counterfactual it would need |
| lean-worker-session, scripted-codebase-map | **absorbed (uncredited, conservative).** See below |

The four event-derived levers are credited ONLY in runs that carry `logs/govern/<run>/lever-events.jsonl`.
A run without one is **uninstrumented**, which is not the same as zero-saving and is never reported
as one: the table prints the word `uninstr.` and the coverage count ("credited in N of M runs")
rather than a zero row that an average would then drag down.

**Absorbed levers.** The vanilla arm is constructed FROM shiploop's own transcripts, so a saving
already baked into those transcripts (trimmed tool lists, stripped worker context, the scripted
codebase map replacing exploratory reads) benefits BOTH arms equally and earns zero credit here. A
true vanilla session would be fatter than the modeled one on those axes, so the model understates
shiploop on them. The direction of that error is known, which is why they are `absorbed`, not
`unmeasured`.

**The honest caveat on the composite.** The pure single-session counterfactual is `coreModel` in
the JSON, printed on every arm as "carry-only legacy model". The headline number is a COMPOSITE:
each lever carries its own counterfactual, and they are not all "one accumulating session". The
prefix, watchdog, resume and skip-the-model levers are measured against "the same harness without
that lever", not against a single session that would never have spawned a worker at all. The
composite is what the product actually avoids paying; `coreModel` is the strict single-session
comparison. Both are printed, always, and neither is presented as the other.

### Partial sessions: `--partials price|drop`

A session killed before it emitted a result event has an exactly recoverable input side and an
unrecoverable output side. `--partials price` (the default since #108) counts what it did record,
flags the row `partial`, and leaves output at zero. `--partials drop` is the pre-#108 behaviour and
is kept because reproducing a historical number requires it. **Both totals are printed either way**,
so the delta between them is always visible: dropping our own spend is the one exclusion that
flatters us.

Pre-flight aborts are a different thing and are handled differently. A run whose `state.jsonl` is
0 bytes never dispatched anything, so there is no work to price. Those runs stay excluded, but the
report counts and prints them ("N run(s) aborted before dispatch"): they are a dispatch-health
signal, not a bench input.

Work the loop recorded as resolved with no transcript at all (a direct-to-main completion, or a
hand-written resolve) is likewise counted and printed. It is out of the bench's scope by design and
the denominator gap has to be visible rather than silently absent.

### Scope

`--scope all` (default) counts every ticket the loop paid for, including failures. `--scope
resolved` counts only tickets `ticket-history.jsonl` marks resolved.

Scope selects what is **counted**, never what **happened**. A ticket the loop failed still consumed
tokens and still would have grown a single session's context, so it keeps contributing carry to the
tickets after it under either scope. Dropping it from the run outright would shorten the modeled
session and mechanically move the number, which is a measurement artifact rather than a result.

On the author's corpus `--scope resolved` is the **harsher** cut, not `--scope all`: resolved
tickets skew toward earlier positions in a run, where less has been carried.

### Version scope

No transcript event names the shiploop *package* version, so by default the tool would blend every
harness version a workspace has ever run into one number — an old workspace's figure diluted by
whatever the harness did three versions ago. `run-loop.sh` now stamps each run directory it creates
with `run-.../shiploop-version` at dispatch (best-effort: an unreadable version marker never blocks
a dispatch, the run is simply left unstamped). By default `bench/replay.mjs` keeps only the runs
stamped with the newest version present in the corpus and reports the rest as excluded, split into
older-stamped and unstamped-legacy so the two are never conflated. `--all` restores the full,
unscoped sweep. If nothing in the corpus is stamped at all, there is no "newest" to select, so the
default falls back to the full sweep and says so rather than reporting a phantom zero-run corpus.
`--since` (the older, coarser run-directory-timestamp proxy) still works and composes with either
mode. Full mechanism and disclosure: `bench/KNOWN-LIMITS.md`.

## The number is a function of backlog length, not of the harness

This is the finding most likely to be misread, so it is stated before the ceiling.

The saving is carry, carry accumulates across a run, and ticket 1 saves exactly 0%. So the reduction
a fleet shows is mostly a statement about **how many tickets its runs clear**, not about how good
the harness is. The report prints the median tickets per run next to every arm for that reason.

Across the author's seven fleets with transcripts (measured 2026-09-05), on the `1m` arm:

| Fleet | tickets | runs | tokens | cost |
|---|---|---|---|---|
| aquanode | 338 | 80 | 77% | 63% |
| claude-keepalive | 31 | 4 | 73% | 58% |
| tokenjam | 83 | 26 | 69% | 59% |
| vibelab | 5 | 1 | 51% | 35% |
| vibetrading | 105 | 98 | 4% | 2% |
| shiploop (the hub's own workspace) | 43 | 40 | 6% | 4% |
| splito | 2 | 2 | 0% | 0% |

The bottom three fleets are not worse-run fleets. They dispatched close to one ticket per run, so
nothing was ever carried, so by this model they saved nothing. Any single figure quoted from the
pooled corpus is an average over that spread, and the spread is wider than the figure.

## The ceiling

Output is a cost no architecture removes. The work still has to be written, and shiploop writes the
same code a single session would. So the maximum reduction any tool could report against a given
arm is the point where everything except output has gone to zero.

`replay.mjs` computes and prints this per arm. On the author's corpus (measured 2026-09-05, the
same 7-fleet/251-run/607-ticket corpus as `README.md`'s best-case number):

| Arm | Ceiling, tokens | Ceiling, cost |
|---|---|---|
| `200k` | 99.6% | 85.7% |
| `1m` | 99.8% | 92.5% |
| `uncapped` | 99.9% | 96.0% |

The token ceiling is nearly 100% because output is a rounding error in token count (20.2M of
3,464M). The cost ceiling is the meaningful one, because output is billed at 5x input and 50x cache
read. **Anything claiming to beat roughly 93% on cost against a 1M session is claiming to have
removed the writing.**

## The live harness's per-session ceiling

`bench/run.sh` and `bench/arms.sh` (the live A/B path, not replay) need a hard per-session ceiling
on every spend-bearing session in BOTH arms: an always-on rail, not an option, per the spec. The
ceiling was originally `--max-turns`, gated on a cached `claude --help` probe
(`govern::claude_supports_max_turns` in `templates/govern/lib/common.sh`). A later CLI release
(observed: claude 2.1.246) dropped `--max-turns` entirely and ships `--max-budget-usd`, a
per-session dollar cap, in its place. The harness now probes for `--max-turns` FIRST and falls back
to `--max-budget-usd` (`govern::claude_supports_max_budget_usd`, same cached-probe pattern) only
when turns support is absent. A CLI with neither flag is still a hard stop:
`BENCH_ALLOW_UNCAPPED_TURNS=1` is the only, deliberate, operator override, exactly as it was before
the fallback existed.

**The dollar cap is not neutral between arms**, and this is a deliberate, documented choice rather
than an accident: the vanilla arm is ONE session doing the WHOLE backlog, while the shiploop arm is
many short worker sessions. Giving both the identical flat per-session dollar figure would bind
vanilla far tighter than shiploop, because vanilla has to fit every ticket's work under one ceiling
that a worker only has to fit one ticket's work under.

The harness resolves this by NOT using one flat number for both:

- **Vanilla's per-session cap is `BENCH_MAX_USD`, the whole run's budget.** Since vanilla's session
  is already doing all of the run's work, capping it at anything less than the run budget would be
  a second, tighter ceiling that the shiploop arm's workers never individually face.
- **Each shiploop worker's cap is `BENCH_MAX_SESSION_USD`, default $5.** This is a flat, documented
  dollar figure sized for one ticket's worth of work, the dollar analogue of the pre-existing
  80-turn worker default (vanilla: 200 turns for the backlog vs. 80 turns per worker; the dollar
  defaults follow the same shape, a whole-run figure vs. a per-ticket figure).

**A vanilla session truncated by its own cap is not a loss for vanilla and not a win for shiploop.**
`bench::stream_hit_session_cap` (`bench/record.sh`) reads the truncated session's `"type":"result"`
event and detects the CLI's own `error_max_*` subtype (covering both `error_max_turns` and the
budget ceiling's matching subtype, by prefix rather than an exact string, so either ceiling is
caught without a version compare). `run.sh` checks every session stream in a cell for this BEFORE
deriving a status from ticket completion; a cell containing even one capped session is forced to
`status: "capped"`, overriding whatever `resolved`/`failed` the ticket count alone would have given
it. The rollup already drops a `capped` backlog from the published set for the run-level
`BENCH_MAX_USD` cap (see the assumptions below); this reuses that same drop path for a per-session
truncation, so a rail artifact can never be published as a measured result in either direction.

## Every assumption, and which arm it flatters

Stated worst-first: the assumptions that inflate shiploop's number come first.

### Flatters shiploop

1. **The driver is not counted.** The real corpus logs worker sessions only. The governor driver
   session, and the interactive session that dispatched it, spent tokens that are absent from the
   shiploop arm. This is the largest known bias and it is unquantified, because the transcripts do
   not exist. The live A/B harness (`bench/run.sh`) counts the driver; the replay path cannot.

   **CORRECTION (2026-09-08, #108).** This is no longer unquantified, and it is no longer left
   uncharged where it can be read. `replay.mjs` now sums every orchestration-side transcript a run
   produced (any `governor`/`driver`/`scout`/`review`/`re-verify`/`supervise` transcript, and any
   transcript sitting outside a `ticket-*` directory) INTO the shiploop arm's tokens, cost and
   quota-weighted totals. That lowers the shiploop number, which is the point. A run that produced
   no such transcript is flagged `overhead-uncovered` and counted, so the report states in every
   run how much of the corpus this charge could actually reach. The residual bias is therefore
   bounded by the uncovered count instead of being a shrug: where coverage is 0 of N runs, the
   shiploop arm's cost is a stated LOWER bound rather than a measurement. The interactive session
   that typed `/shiploop:bench` is still not counted anywhere, and never will be by this path.
2. **Scouts and re-verification are counted only when they wrote a worker transcript.** Anything
   the loop spends outside `logs/govern/**/*.jsonl` is invisible here.
3. **A modeled session is assumed to do the same work in the same number of turns.** A single
   session carrying full history might finish some tickets in fewer turns because it already knows
   the codebase. The model gives it no such credit. This is the most arguable assumption in the
   document, and it is the one most likely to be attacked.
4. **A mixed-model session is now priced per session, per tier, on BOTH arms.** This entry
   previously described `dominantTier()`, which resolved ONE tier for a whole session (the model
   holding the largest token volume) and priced all of that session's modeled carry-read and
   re-prime-credit at it. On a session that escalated mid-ticket, the later heavier-context turns
   pulled that choice toward the pricier tier and the entire session's modeled overhead was billed
   there, inflating the modeled vanilla cost in shiploop's favour.

   `dominantTier()` is gone (removed 2026-09-08, #108). The modeled side is now priced at the
   session's own input-side token mix blended across the tiers that actually ran it
   (`sessionInputRate()` in `bench/replay.mjs`), so a session that spent 90% of its input side on
   sonnet has 90% of its modeled overhead priced at sonnet. For a single-model session the two
   rules are identical to the cent, which is why the frozen fixtures reproduce unchanged. The
   direction of the old bias was toward shiploop; removing it moves the cost figure slightly
   AGAINST shiploop on mixed-model corpora and leaves the token figure untouched, because the token
   path never multiplies by a rate.

   The residue of this entry that still stands: **the cost reduction is a weaker number than the
   token reduction**, because cost depends on the rate table and on which model ran what, and
   tokens do not. See `bench/KNOWN-LIMITS.md` and `README.md`'s "Tokens vs. cost" section.

### Flatters vanilla (makes the published number conservative)

5. **Compaction is free.** The `200k` arm bounds carry to the window but charges nothing for the
   compaction calls a real 200k session would make, which are real tokens and real latency. A real
   200k session is more expensive than this arm.
6. **The carry never needs re-writing.** Carry is charged at the cache-read rate for every turn, as
   if it were permanently warm. Real cache entries expire, and a real session re-writes them at 2x
   input. Charging every re-write would make the vanilla arm substantially more expensive.
7. **The re-prime refund is generous.** The whole first-turn cache write of every later session is
   refunded to the vanilla arm, as if a single session would need none of it. The refund fires on
   *any* session boundary after the run's very first session, including a same-ticket retry, not
   only a boundary between two different tickets. That is why 3 of the 753 position-1 rows in
   `bench/published-rows/replay-2026-09-05.jsonl` show `vanillaTokens` slightly *below*
   `shipTokens` (all three are the same run, `sessions: 2` at position 1, replayed once per arm):
   a retried ticket 1 still earns the refund on its second attempt even though nothing has been
   carried across tickets yet. This is the correct application of the rule above, not a separate
   bug, and it moves the reported reduction in vanilla's favor (smaller), the same direction as
   every other item in this section. It does not move the median: `README.md`'s "ticket 1 (n=248)
   0%" is the median across all 248 position-1 rows in the `1m`-arm pool, and a 0.3%-of-corpus
   exception does not shift a median. Read "ticket 1 saves 0%" everywhere in this repository as
   the median / single-session case, not a per-row guarantee.
8. **`200k` carry is bounded by observed context that came from 1M-window sessions.** Many worker
   turns in the corpus already exceed 200k of context on their own, which leaves the modeled 200k
   session no headroom for carry at all and drives its reduction toward zero. A real 200k session
   would have compacted its own working context to fit, freeing room for carry and paying for the
   compaction. The `200k` arm should therefore be read as a **lower bound**, and it is the reason
   this implementation reports a smaller 200k saving than a naive model would.

### Direction unknown

9. **Ticket order is completion order.** Runs that dispatched tickets concurrently are replayed as
   if they were sequential in the order they finished. A different order changes which tickets sit
   at which position, and therefore how much carry each one is charged.
10. **Escalation attempts are summed into one ticket.** A ticket that failed and was retried
    contributes both attempts' tokens to the shiploop arm and both attempts' residue to the carry.

## What is not measured at all

- **No vanilla transcript exists.** Not one. The vanilla arm has never been executed.
- **Wall-clock time.** Nothing here measures how long anything took, and no throughput claim in
  this repository is supported by the replay path.
- **Quality.** The replay path knows nothing about whether the work was any good. It counts tokens
  for tickets the governor recorded, at whatever status it recorded them.
- **Subscription quota.** Every dollar figure is API list rate. On a subscription those dollars are
  a proxy for quota burn, not an invoice. The published figure is a percentage, so it is the same
  in both worlds, but the absolute dollars are not anyone's bill.

## Reproducing it

```bash
# your own workspace
node bench/replay.mjs --fleet /path/to/your-workspace --arm all

# every fleet workspace beside you, which is how the published number is produced
node bench/replay.mjs --arm all

# machine-readable, same numbers
node bench/replay.mjs --arm 1m --json
```

Those three commands need the author's own fleet transcripts, which are private workspaces and are
not in this repository. **Recomputing the published headline needs neither the transcripts nor
`replay.mjs`** -- only the anonymized rows already committed at
`bench/published-rows/replay-2026-09-05.jsonl` and `jq`:

```bash
jq -s '
  group_by(.arm)[] |
  {
    arm: .[0].arm,
    tokenReductionPct: ((([.[]|.vanillaTokens]|add) - ([.[]|.shipTokens]|add)) / ([.[]|.vanillaTokens]|add) * 100),
    costReductionPct:  ((([.[]|.vanillaCostUsd]|add) - ([.[]|.shipCostUsd]|add))  / ([.[]|.vanillaCostUsd]|add)  * 100)
  }
' bench/published-rows/replay-2026-09-05.jsonl
```

The tool will do the same aggregation over any published rows file without touching a workspace,
which is what the regression test runs:

```bash
# the frozen corpus, through the tool: 70.2/57.3 (1m), 30.1/18.2 (200k), 85.5/77.4 (uncapped)
node bench/replay.mjs --rows-file bench/published-rows/replay-2026-09-05.jsonl --json
```

Rows published from #108 onward also carry `baseline`, `version` and `ts`, so a version-scoped or
baseline-scoped recomputation is a filter rather than a re-run. Rows published before that carry
none of the three; a reader treats a missing `version` as `unknown`, and the tool counts them:

```bash
# one arm, one baseline, one harness version, straight off published rows
jq -s '
  [.[] | select(.arm == "200k" and (.baseline // "same-mix") == "driver-tier" and (.version // "unknown") == "1.19.0")] |
  {
    n: length,
    tokenReductionPct: ((([.[]|.vanillaTokens]|add) - ([.[]|.shipTokens]|add)) / ([.[]|.vanillaTokens]|add) * 100),
    costReductionPct:  ((([.[]|.vanillaCostUsd]|add) - ([.[]|.shipCostUsd]|add))  / ([.[]|.vanillaCostUsd]|add)  * 100)
  }
' bench/published-rows/<file>.jsonl
```

This sums the same `shipTokens`/`vanillaTokens` (and `*CostUsd`) columns `replay.mjs --json` summed
to build the published aggregate, over every one of the 1,821 committed rows, and reproduces
70.2%/57.3% (`1m`), 30.1%/18.2% (`200k`) and 85.5%/77.4% (`uncapped`) exactly. That is what
"recomputable" means in this document: a reader never has to trust the author's run of the tool,
only arithmetic over rows they can read themselves.

The tests that lock the arithmetic are `templates/govern/test/test-bench-replay.sh` and
`test-bench-replay-schema.sh`, running against `bench/fixtures/replay-fleet`, a synthetic fleet
whose every expected figure is derivable by hand from the table in `bench/fixtures/README.md`.
