# bench

The benchmark behind shiploop's cost claim. The unit is **a full session clearing a backlog**, not a
ticket: a session opened in a scaffolded shiploop workspace (advisor, worker subagents, the
installed doctrine) against the same checkout with no shiploop installed at all (default Claude
Code, out of the box).

**What a percentage would be a percentage of.** Any number this directory eventually publishes is a
reduction in total billed tokens or dollars across a backlog run (context read, context write, and
the response itself), never a fraction of your bill. Output tokens, the actual code and prose
written, are paid in full by BOTH arms: it is the same work and the same code either arm has to
produce, and no architecture removes that cost. That sets a hard ceiling well under 100%.

**The marketing sentence the project's site carries is not backed by anything in this directory.**
It claims a token efficiency figure and a speed claim. Neither is computed here: no wall-clock
timing is collected anywhere in this repository, so a speed claim can never come from this
benchmark, and no run has yet produced a curated, multi-backlog cost figure this directory would
stand behind. This file states what is and is not measured, plainly, rather than restating an
unbacked figure with a caveat attached.

## The design

**with shiploop** = a session opened in a scaffolded shiploop workspace: it acts as advisor, spawns
worker subagents through the native Agent tool, and follows whatever the installed CLAUDE.md /
SKILL.md tells it to.

**without shiploop** = a session opened in the same checkout with no `.claude/`, no `CLAUDE.md`, no
hooks, no `scripts/govern`, no `queue/tickets.md` — the CLI's own default toolset, MCP included, the
way a user without shiploop actually has it.

Both arms are real, measured sessions. **Nothing is modeled.** The only difference between them is
which directory the session opens in: same checkout, same pinned ref, same backlog text word for
word, same turn ceiling, same tool list (neither arm gets a curated `--tools` flag — a trimmed tool
schema is itself one of the levers under test, so handing it to one arm or withholding it from the
other would lend that arm part of the product's own credit).

## Two numbers, never blended

- **Tokens.** Model-independent by construction: no dollar rate enters the token side at any step,
  so the token figure would be the same on a corpus billed at any prices.
- **Dollars.** Depends on the published per-tier rate table and on which arm routes to which model
  tier. A dollar reduction must never be quoted with the same confidence as a token reduction, and
  the two are reported separately, never combined into one number.

A percentage is only ever computed when both arms are fully measured for the SAME backlog, on the
SAME tier, and neither hit its turn/spend ceiling — see "Rails" below.

## What is here

```
bench/
  METHODOLOGY.md                  what is measured, what every fairness rail closes, and why
  KNOWN-LIMITS.md                 what does not hold yet, read this before quoting anything
  LEVER-EVENTS.md                 the wire contract for the three lever-attribution events
  backlogs/<name>/backlog.jsonl   the published backlog set (schema: backlogs/SCHEMA.md)
  pilot-backlogs/                 candidate pool, gitignored, never pushed
  run.sh                          driver: backlog x arm x rep -> worktree -> arm -> verify -> record
  validate-backlog.sh             offline fail-to-pass gate; decides which backlogs are eligible
  arms.sh                         the two arm shapes (plus the private vanilla-fresh variant)
  record.sh                       result events -> results.jsonl rows, plus attribution reading
  rollup.mjs                      results.jsonl -> the three metric cuts, selection, headline
  fixtures/                       canned streams and golden results.jsonl fixtures
  results/<run-id>/               results.jsonl + session logs, gitignored
  results/README.md               why no result table is committed right now
```

## Arms

| Arm | Shape |
|---|---|
| `vanilla` (without shiploop) | One `claude -p` session for the whole backlog, the CLI's own default toolset, no `.claude/`, no hooks, in a fresh worktree of the pinned ref. Prompt is the backlog verbatim. |
| `shiploop` (with shiploop) | One `claude -p` session for the whole backlog, opened inside a workspace `scaffold.sh` actually built, same prompt as vanilla. It follows the installed doctrine — acts as advisor, spawns worker subagents through the native Agent tool — and bench scripts none of that sequence on its behalf. |
| `vanilla-fresh` | A fresh session per ticket, sequential. Private record only, opt-in via `--arm vanilla-fresh`, never published. |

Ticket text is byte-identical across arms; neither arm sees `verify_cmd`, `test_patch`, `merge_sha`,
or `upstream_pr`. Neither arm is handed a curated tool list.

## Attribution inside the treatment arm

`--forward-subagent-text` surfaces the advisor's own turns and every worker subagent's turns in one
stream, each tagged with its `parent_tool_use_id` and carrying its own `message.usage` /
`message.model`. That, plus the session's own `result.subagent_stats`
(`spawned`/`completed`/`failed`/`killed`/`refused`/`by_type`), gives the advisor/worker split inside
the with-shiploop arm. **This is attribution, never the headline** — the headline cost and token
numbers come from the session's own `result` event regardless of whether attribution succeeded.

Gated behind a cached `claude --help` probe (never a version compare), an env kill switch
(`BENCH_FORWARD_SUBAGENT_TEXT=0`), and — unlike the turn-ceiling probe — a HARD STOP rather than a
degraded arm when the running CLI does not support it: there is no substitute flag, and running
without it would silently drop attribution while everything else looked like a normal run.

`subagent_stats.spawned > 0 && completed > 0` is asserted directly against the session's own result
event before a cell is accepted. A subagent refused for zero tools, or a treatment arm that never
spawned one at all, still exits 0 with `is_error:false` — the exit code cannot tell "measured
something" from "measured nothing," only `subagent_stats` can.

## Running the live A/B harness

Requires `node`, `jq`, `git`, and a `claude` CLI on PATH. It spends real quota.

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
word. A cell that is `capped`, has `status:"no-tickets"` (an empty backlog), or failed the
subagent-activity assertion is excluded from every cut, counted as excluded, never averaged in.

## Rails

Always on. Neither is an option.

| Rail | Default | Behavior |
|---|---|---|
| `BENCH_MAX_USD` | 60 | Hard cap on API-rate `total_cost_usd` across the run, checked before each cell is dispatched. Past it the driver stops dispatching and records the remaining cells with `status: capped`; the rollup drops a capped backlog rather than counting a truncated run as a saving. |
| `BENCH_MAX_TURNS` | 200, EQUAL on both arms | `--max-turns` on every spawned session. Non-binding by construction — each arm is one whole-backlog session now, so there is no shape-specific reason for one arm's ceiling to bind tighter than the other's. A cell that hits it is forced to `capped`. |

`--max-turns` is gated on a cached `claude --help` capability probe, never a version compare. If the
CLI does not support it, `run.sh` falls back to `--max-budget-usd` (equal on both arms, default the
run's own `BENCH_MAX_USD`); if neither flag is supported, `run.sh` refuses to spawn rather than
silently running uncapped. The override is deliberate and explicit:
`BENCH_ALLOW_UNCAPPED_TURNS=1`. `BENCH_MAX_TURNS_FLAG=0` is the kill switch that omits the flag;
`_GOVERN_MAXTURNS_SUPPORTED=1|0` pre-seeds the probe for tests.

Both arms reach the same probe, `govern::claude_supports_max_turns` in
`templates/govern/lib/common.sh`, so they can never disagree about CLI support. Bench sets no
worker-tier env at all for the shiploop arm — no `GOVERN_WORKER_TOOLS`, no `GOVERN_WORKER_MODEL`, no
`GOVERN_WORKER_MAX_TURNS` — because the scaffolded workspace's own `.claude/agents/worker.md` is the
only source of a worker's model and tools, and both are levers under test, not something bench pins.

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
model. A backlog either arm fails to fully clear is dropped from the published set.

### Backlog validation

Before a backlog can enter the pilot it has to prove the fail-to-pass property offline:

```bash
bash bench/validate-backlog.sh --backlogs bench/pilot-backlogs --json
```

Per ticket, against a real clone, no model calls: `test_patch` must apply at `ref`, `verify_cmd`
must FAIL there, and at `merge_sha` the test content must be present and `verify_cmd` must PASS.
A backlog under `--min-tickets` (default 6) is marked unusable, and the gate exits non-zero when
nothing is usable so a pilot script cannot proceed on an empty eligible set.

**No published backlog meeting this bar exists yet.** `bench/backlogs/` carries only its schema and
the test fixture; the only candidate pool is `bench/pilot-backlogs/`, gitignored and never pushed.
Curating a real fail-to-pass backlog of at least six mined tickets is the gate on every figure this
directory could ever publish, and it is out of scope for the mechanism itself.

## Cost figures and account type

Every cost figure comes from `total_cost_usd` on the session's `result` event, which is API-list-rate
denominated regardless of how the CLI is authenticated. On a subscription those dollars are a proxy
for quota burn; on an API key they are the invoice. A published figure would be a percentage, so it
is identical in both worlds.

## What has actually been run, and what it showed

The one live, both-arms-measured pilot run to date used a 2-ticket backlog
(`bench/pilot-backlogs/shiploop-mini`, mined from shiploop's own history, gitignored). **Neither arm
cleared either ticket against the mechanical oracle**, 0 of 2 on both sides. No magnitude is
published from that run, for the same reason no favourable one would be either: a result is either
publishable or it is not, regardless of which direction it points, and a 2-ticket pilot is too small
to support a figure either way. Full disclosure: `bench/KNOWN-LIMITS.md`.

## Known open gap

There is no network namespace around either arm. Git remotes are stripped, `gh` is shadowed by a
purely local shim, and ambient `GH_TOKEN`/`GITHUB_TOKEN`/etc. are scrubbed from every spawned
session's environment — but a worker's own `Bash` tool could still reach the network directly (a
bare `curl`, for instance). This is a known, disclosed limitation, not something either arm's tool
list ever tried to close: see `bench/KNOWN-LIMITS.md`.

## Tests

`templates/govern/test/test-bench-{schema,cap,arms,rollup,selection,validate}.sh`, fixture-driven,
zero spawns except through canned streams. They resolve the hub as `$DIR/../../..` and skip (exit
77) anywhere else, so they are listed in `tools/hub-context-tests.txt` and run by the
`hub-context-tests` CI job from the checkout, where a skip is a hard failure.

```bash
for t in templates/govern/test/test-bench-*.sh; do bash "$t"; done
```
