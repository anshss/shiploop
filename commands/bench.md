---
description: Replay this workspace's own governor logs and print its token and cost reduction against one long Claude Code session. Read-only, no model spend.
allowed-tools: Bash, Read
---

# /shiploop:bench

Computes **your** number, not the published one, from the transcripts your governor already wrote.

It reads `logs/govern/**/*.jsonl` and `governor/ticket-history.jsonl`, sums the measured billed
usage of every worker session, and models what the same tickets would have cost inside one
accumulating Claude Code session. Read-only. No `claude` process is spawned, nothing is written
into the workspace, and it spends nothing.

**The number it prints is a modeled counterfactual.** The shiploop arm is measured. The vanilla arm
never ran: it is a model. The tool says so on its own first line, and you should repeat that
wherever you quote it. Method, every assumption, and which arm each assumption flatters:
`bench/METHODOLOGY.md` in the hub.

## Phase 0 — Locate the hub

`bench/` ships with the hub and is never installed into a workspace, so resolve `HUB` first, in
priority order:

1. `${CLAUDE_PLUGIN_ROOT}` (plugin run)
2. `${GOVERN_UPSTREAM_HARNESS_DIR}` from `scripts/lib/workspace.sh` (operator's local fork clone)
3. `~/.claude/skills/shiploop/` (legacy clone-into-skills)
4. Glob `~/.claude/plugins/**/shiploop/bench/replay.mjs` (plugin-cache install)

If none resolve, STOP and print:

```
Cannot locate the shiploop hub, so bench/replay.mjs is not reachable.

Options:
  - Install as a plugin (recommended):
      /plugin marketplace add anshss/shiploop
      /plugin install shiploop@shiploop
  - Point at a local clone by exporting one of:
      CLAUDE_PLUGIN_ROOT=/path/to/shiploop            (env)
      GOVERN_UPSTREAM_HARNESS_DIR=/path/to/shiploop   (workspace.sh)
```

Confirm `$HUB/bench/replay.mjs` exists and `node --version` works. `node` is the only requirement.

## Phase 1 — Run it

Default, from the workspace root:

```bash
node "$HUB/bench/replay.mjs" --fleet "$PWD" --arm all
```

`$ARGUMENTS` passes through verbatim. The flags:

| Flag | Meaning |
|---|---|
| `--fleet <path>` | a workspace to read, repeatable. Omit it entirely and the tool discovers the current workspace and its siblings |
| `--arm 200k\|1m\|uncapped\|all` | which counterfactual session to model. Default `all` |
| `--scope all\|resolved` | count every ticket the loop paid for, or only the ones `ticket-history.jsonl` marks resolved. Default `all` |
| `--json` | machine-readable, same numbers |

A workspace with no `logs/govern` transcripts exits non-zero and says so. That is the correct
outcome, not a failure to explain away: there is nothing to replay until the governor has run.

## Phase 2 — Report

Relay the tool's output as it stands. Do not restate a percentage without the arm it belongs to,
and do not drop the modeled-counterfactual line. Three things in the output are worth pointing at
explicitly, because they are the parts a reader would otherwise have to be told:

- **Ticket 1 saves exactly 0%.** Nothing has been carried into it yet. The whole saving is context
  that one session accumulates and a fresh worker never loads, so the number is a property of
  backlog length, not of any one ticket.
- **The arm changes the number more than the corpus does.** Against a 200k session with compaction
  the reduction is far smaller than against a 1M one, because a 200k window cannot hold much carry
  in the first place. Quote the arm or quote nothing.
- **The reconciliation ratio** is the self-check. It is computed cost over the cost the CLI itself
  reported, per session. A median far from 1.000 means the rate table no longer matches what the
  user is actually billed, and every dollar figure in the report should be treated as stale.

If the user asks for the published figure rather than their own, say plainly that it comes from the
same tool over the author's fleets, name the arm, and point at `bench/METHODOLOGY.md`.
