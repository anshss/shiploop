---
description: Print the published shiploop benchmark result (backlog and arms named) and the exact command to run a fresh with-shiploop-vs-without-shiploop A/B locally. Never spends by default.
allowed-tools: Bash, Read
---

# /shiploop:bench

Two things, neither of which spends anything:

1. **The published result**, if one exists, with the backlog and both arms named.
2. **The exact command to run a fresh A/B yourself**, with its estimated cost, so running it stays
   an explicit, deliberate act rather than something this command does on your behalf.

## Phase 0 — Locate the hub

`bench/` ships with the hub and is never installed into a workspace, so resolve `HUB` first, in
priority order:

1. `${CLAUDE_PLUGIN_ROOT}` (plugin run)
2. `${GOVERN_UPSTREAM_HARNESS_DIR}` from `scripts/lib/workspace.sh` (operator's local fork clone)
3. `~/.claude/skills/shiploop/` (legacy clone-into-skills)
4. Glob `~/.claude/plugins/**/shiploop/bench/run.sh` (plugin-cache install)

If none resolve, STOP and print:

```
Cannot locate the shiploop hub, so bench/ is not reachable.

Options:
  - Install as a plugin (recommended):
      /plugin marketplace add anshss/shiploop
      /plugin install shiploop@shiploop
  - Point at a local clone by exporting one of:
      CLAUDE_PLUGIN_ROOT=/path/to/shiploop            (env)
      GOVERN_UPSTREAM_HARNESS_DIR=/path/to/shiploop   (workspace.sh)
```

## Phase 1 — The published result

**There is currently no published result.** `bench/backlogs/` holds only the test fixture; no
backlog meeting the design's own 6-ticket usability bar (`bench/validate-backlog.sh --min-tickets`,
default 6) has been curated yet. Say this plainly, and point at `bench/KNOWN-LIMITS.md` ("There is
no published (6+ ticket) live backlog yet") for the full reason — do not soften it into "results
coming soon" or invent a placeholder figure.

If this ever changes, the published result will be a committed `bench/results/<run-id>/results.jsonl`
(or an explicit path an operator names) this phase reads with:

```bash
node "$HUB/bench/rollup.mjs" <path-to-results.jsonl>
```

and relays verbatim: the headline sentence, which metric produced it, the backlog(s) and ticket
count behind it, and the model/tier each arm ran on. Never restate a percentage without the arm and
backlog it belongs to.

## Phase 2 — Run your own A/B

Print this verbatim, filled in with the values below, and STOP. Do not run it. Running a real A/B
spends real quota — that has to be the user's own explicit next command, never something this
command does on their behalf.

```bash
bash "$HUB/bench/run.sh" --reps 2
node "$HUB/bench/rollup.mjs"
```

**Estimated cost**, stated as an estimate and never as a bill: each real arm is one whole-backlog
session capped at `BENCH_SESSION_USD` (default equal to `BENCH_MAX_USD`, itself default $60 for the
whole run). With `--reps 2` over N backlogs that is up to `2 x N x 2 x $60` in the worst case if
every session ran to its own cap, which it will not in the ordinary case — the real cost is
whatever the backlog's own tickets take, bounded by the caps. Name `BENCH_MAX_USD` explicitly as the
hard ceiling on total spend for the run, and say that a dry run (`bash "$HUB/bench/run.sh" --dry-run`)
exercises the whole pipeline for zero dollars first, if the user wants to see the shape of the
output before spending anything.

Also name, plainly, what running it actually measures: one with-shiploop session (the advisor,
using the native Agent tool to spawn worker subagents through the installed doctrine) against one
without-shiploop session (the same checkout, no `.claude/`, the CLI's own default toolset), over
whichever backlog(s) `bench/backlogs/` currently has — today, only the test fixture, which
`bash "$HUB/bench/run.sh"` refuses to run for real (it exits non-zero and says why, rather than
spending on a fixture that could never be counted toward a published backlog).

## What changed here

This command used to replay a workspace's own `logs/govern/**` transcripts and model a
counterfactual vanilla session from them — read-only, no spend, an instant number. That path is
retired: several of shiploop's own levers work by making a model call *not happen*, and an absence
leaves no trace in a transcript to model from, so a single observed arm plus modeling could never
see the levers it was crediting. The only way to measure the combination is to run both arms for
real, which is exactly what Phase 2 above prints the command for, and exactly why this command no
longer produces a free number the way it used to.
