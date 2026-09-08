# Lever event contract

Authoritative wire shape for the five instrumentation events in
`.specs/2026-09-08-bench-multi-lever-design.md` section 4b. The governor emitter and the
`replay.mjs` reader are built against THIS FILE. Neither half may change a field name without
changing it here first.

## Location

`logs/govern/<run>/lever-events.jsonl`: one JSON object per line, append-only.

**Not `state.jsonl`.** That file is a per-ticket outcome log (`{ticket,status,note}`), read raw
into the review prompt by `govern-improve.sh` and tailed by cursor in `govern-supervise.sh`.
Interleaving lever events there pollutes the improve prompt and adds rows those consumers must
learn to skip. A sibling file has no existing consumers.

## Common fields (every event)

| Field | Type | Notes |
|---|---|---|
| `event` | string | one of the five names below |
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
{"event":"scripted-action","ts":1788800002,"ticket":108,"session":"driver","tier":null,"class":"version-bump"}
{"event":"escalation","ts":1788800003,"ticket":108,"session":"worker","failedTier":"sonnet","failedTokens":240500}
```

- `watchdog-kill`: `ctxTokens` and `turns` are the values at the instant the watchdog terminates.
  `reason` is free text.
- `resume`: both sides computed at resume time from state the governor already holds; they are
  unrecoverable afterward. `checkpointTokens` = what the resume actually loads (injected notes
  plus structured handoff).
  `freshStartTokens` = the failed attempt's **context-reconstruction spend only**: its input
  plus `cache_creation_input_tokens`, EXCLUDING output tokens. This is deliberately narrower
  than the failed attempt's total spend. A retry has to redo the actual work either way; the
  only thing resuming avoids is re-reading its way back to context. Crediting total spend here
  would hand the resume lever the failed attempt's output tokens as savings, which is a lever
  biased toward shiploop, and section 4a of the spec exists precisely to leave no such entry
  in the ledger. When in doubt this number is under-counted, never over-counted.
- `scripted-action`: `class` keys into the per-class token estimate table in `replay.mjs`. An
  unknown class is counted and credited zero, and named in the report.
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

  The reader converts bytes to tokens at `SUPPRESSION_BYTES_PER_TOKEN` (4) and credits the result
  ONCE. Crediting once is a deliberately loose floor: the real saving is that those bytes would have
  been re-sent on every later turn, which is the entire reason the wrapper exists.

- `escalation`: emitted when a failed cheap-tier attempt escalates. `failedTokens` is what the
  failed attempt burned; replay SUBTRACTS it from routing credit. Carries `failedTier` instead of
  `tier`.

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
