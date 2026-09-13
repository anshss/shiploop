# Lever event contract

Authoritative wire shape for the three instrumentation events. The governor emitter and every
reader built on top of it are built against THIS FILE. Neither half may change a field name
without changing it here first.

## Location

`logs/govern/<run>/lever-events.jsonl`: one JSON object per line, append-only.

**Run-less fallback, and it is the interactive lane's normal case.** `govern::emit_lever_event`
resolves its file as `${GOVERN_LEVER_EVENTS_FILE:-${GOVERN_RUN_DIR:-$LOG_ROOT}/lever-events.jsonl}`,
so an emitter with no `GOVERN_RUN_DIR` in scope lands at `logs/govern/lever-events.jsonl`: flat,
beside the run directories, not inside one. A live interactive session is exactly that case, since
nothing exports `GOVERN_RUN_DIR` there (the autonomous dispatch loop that used to is retired). A
reader can still count and name these rows by event type, but it cannot attach them to one arm or
run without guessing which — guessing (newest, only, nearest timestamp) would attach a real saving
to an arbitrary arm, so a correct reader discloses them uncredited instead of credited.

**Not `state.jsonl`.** That file is a per-ticket outcome log (`{ticket,status,note}`), tailed by
cursor in `govern-supervise.sh` and read raw by any reviewer prompt built from a run. Interleaving
lever events there adds rows those consumers must learn to skip. A sibling file has no existing
consumers.

## Common fields (every event)

| Field | Type | Notes |
|---|---|---|
| `event` | string | one of the three names below |
| `ts` | integer | unix seconds, `date +%s` at emit |
| `ticket` | integer \| null | the ticket being worked, null for orchestration-side |
| `session` | string | transcript basename without `.jsonl`, e.g. `worker`; identifies which session the credit attaches to |
| `tier` | string \| null | model tier in force for that session (`opus`/`sonnet`/`haiku`), null if unknown |

A reader that does not recognise `event` skips the line. A line that fails to parse is counted
and skipped, never fatal.

## Events

```jsonl
{"event":"output-suppression","ts":1788800004,"ticket":108,"session":"worker","tier":null,"withheldBytes":48213,"withheldLines":612,"outcome":"pass"}
{"event":"watchdog-kill","ts":1788800000,"ticket":108,"session":"worker","tier":"sonnet","ctxTokens":184320,"turns":97,"reason":"context-cap"}
{"event":"resume","ts":1788800001,"ticket":108,"session":"worker","tier":"sonnet","checkpointTokens":12400,"freshStartTokens":86100}
```

- `watchdog-kill`: `ctxTokens` and `turns` are the values at the instant the watchdog terminates.
  `reason` is free text.

  **DUAL-LANE. Two emitters, one event stream.** The headless lane emits it from
  `templates/govern/spawn-worker.sh` (its `emit_watchdog_kill`), run-scoped under
  `logs/govern/<run>/`. The interactive lane emits it from the
  `templates/hooks/agent-watchdog-guard.sh` PreToolUse hook, on its wall-clock deny path, run-less at
  `logs/govern/lever-events.jsonl` (see Location above). Same event name and the same
  `ctxTokens` / `turns` / `reason` field names on both, deliberately: the two lanes produce ONE
  stream a reader can group, not two dialects it has to reconcile. Before this, a bench crediting
  the watchdog lever saw only half the fleet's kills, and the interactive half read as "never
  fired" rather than "unmeasured".

  Reason strings: `wall-clock-timeout` (an elapsed-time cap) is emitted by both lanes and groups
  across them. `context-cap` (a cumulative-token cap) is HEADLESS-ONLY: the interactive lane has no
  token-volume cap, deliberately, so no interactive row ever carries that reason. `turns` counts
  assistant turns the same way on both lanes, a line count of `"type":"assistant"` over the
  transcript. On the interactive lane `ctxTokens` is a reading reported alongside the kill, never
  the thing that caused it.

  Three extra fields ride along on the interactive lane only. A reader skips fields it does not
  know, so adding them costs nothing:

  | Field | Type | Notes |
  |---|---|---|
  | `lane` | string | `interactive` from the hook. Absent on the headless lane |
  | `agentType` | string | the child's agent type, `unknown` when the payload omits it |
  | `agentId` | string | the child's `agent_id`, the only stable identifier a hook sees |

  Two common fields are necessarily `null` on the interactive lane, and honest nulls are the
  deliberate choice over guesses: `ticket` (a hook sees an `agent_id`, never the ticket handed to
  the child in a prompt it does not read) and `tier` (PreToolUse carries no model field for the
  child, and inferring one from the parent would name the wrong model; the reader's own
  `driverTier` fallback already covers a null tier).
- `resume`: both sides computed at resume time from state the governor already holds; they are
  unrecoverable afterward. `checkpointTokens` = what the resume actually loads (injected notes
  plus structured handoff).
  `freshStartTokens` = the failed attempt's **context-reconstruction spend only**: its input
  plus `cache_creation_input_tokens`, EXCLUDING output tokens. This is deliberately narrower
  than the failed attempt's total spend. A retry has to redo the actual work either way; the
  only thing resuming avoids is re-reading its way back to context. Crediting total spend here
  would hand the resume lever the failed attempt's output tokens as savings, which is a lever
  biased toward shiploop, and this rule exists precisely to leave no such entry
  in the ledger. When in doubt this number is under-counted, never over-counted.
- `output-suppression`: emitted by `verify-filter.sh` when it withholds a PASSING command's output
  from the transcript. `withheldBytes` / `withheldLines` are measured from the capture file at the
  instant of suppression, immediately before the EXIT trap deletes it. This is the only moment the
  bytes exist: by design they never enter a transcript, so nothing downstream can recover them.

  **Pass only, deliberately.** A failing run is passed through, bounded at the tail by
  `GOVERN_VERIFY_FILTER_MAX_LINES`, so its withheld remainder is a partial saving. That saving is
  real and it is left UNCREDITED, because the claim this lever measures is "successful output stays
  out of the transcript" and under-counting is the standing rule for every lever here.

  **Coverage is structurally partial and must be disclosed wherever it is printed.** Wrapping a
  command in `npm run vf` is OPT-IN, and `templates/hooks/router-posture-guard.sh` only nudges via
  non-blocking advice. So this lever measures suppression that HAPPENED, never suppression that
  could have happened, and an uncredited session is not evidence that nothing was withheld.

  A reader that wants to PRICE this lever should convert bytes to tokens at roughly 4 bytes per
  token and credit the result ONCE per event, never per later turn: crediting once is a
  deliberately loose floor, because the real saving is that those bytes would otherwise have been
  re-sent on every later turn, which is the entire reason the wrapper exists.

## Deliberate exclusions

Mechanisms that exist, fire in production, and are **not** lever events. Each is listed here so a
future reader finds the decision instead of assuming an oversight and adding an emitter.

- **`agent_progress_alarm`** (`templates/hooks/agent-progress-guard.sh`) stays on the fleet event
  log (`GOVERN_EVENTS`) and is NOT promoted to a lever event. A lever bench credits must REMOVE
  tokens from the counterfactual, and this one removes none. Its `TeammateIdle` branch cannot block
  by construction (there is no stop to hold open), so it terminates nothing and truncates nothing.
  Its `SubagentStop` branch blocks a stop, which makes the child work LONGER, not shorter.
  Crediting it would be crediting an observation as a saving. The exclusion is locked by case 14 of
  `templates/govern/test/test-agent-progress-guard.sh`, which asserts the alarm produces a fleet
  event and no lever event, so an emitter cannot be added quietly without moving this entry and the
  matching one in `bench/KNOWN-LIMITS.md`.

## Emitter rules

- Failure-proof: emission never aborts a dispatch. Write-or-skip, `|| true`, no `set -e` exposure.
- Pure log-format addition. No new `claude` CLI flag, so no help-probe gate is needed
  (root CLAUDE.md rule 12 applies only to CLI invocations).
- Govern bash constraints (root CLAUDE.md rule 11): a function whose last statement is a bare
  `[[ c ]] && cmd` must end `return 0`; no dependent locals in one `local` statement.
- ON by default at runtime (`GOVERN_LEVER_EVENTS=0` is the kill switch): this is pure log-format
  instrumentation with a proven never-abort contract, not a mechanism that changes dispatch
  behavior, so root CLAUDE.md rule 12's usual new-mechanism-defaults-off is satisfied at the TEST
  layer instead, via one `export GOVERN_LEVER_EVENTS=0` in `templates/govern/test/assert.sh`
  (fixtures must not accumulate event files).

## Reader rules

- Credit an event-derived lever ONLY in runs that carry `lever-events.jsonl`. Runs without it are
  uninstrumented, not zero-saving.
- The report prints per-lever corpus coverage: `watchdog: credited in N of M runs, older runs
  uninstrumented`. A mixed corpus must never silently imply full coverage.
