# Governor improvements

Self-improvement proposals appended by `govern-improve.sh` after a run that hit friction. Each is a
concrete, scoped change to the harness — the operator reviews and applies (or files as a ticket).
Safety rails are never auto-changed; if one caused friction it's flagged `OPERATOR DECISION`.

_(empty — the governor appends here)_

## 2026-07-11 03:55 — run run-20260711-033250 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-11 03:55:** 3 safe proposal(s) → ticket **#9**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

No `ExitPlanMode` tool is available in this session, so I'll deliver the GOVERN-IMPROVE output directly per its contract (the analysis is saved to the plan file at `/Users/anshs/.claude/plans/govern-improve-you-are-reviewing-radiant-shore.md` for reference).

- `queue/tickets.md`: document `**Depends on:** #K[, #J...]` as a first-class "Optional per-ticket field" (next to the existing `Model:` entry, ~line 22-31) — state that this exact phrase is what `govern::ticket_deps()` (`scripts/govern/lib/common.sh:1095-1116`) parses and what the #119 pre-spawn gate (`run-loop.sh:673-688`) enforces, and that "Ref:"/"siblings"/other prose is not machine-read — why: #7 (commit `49c3c8c`) declared its real blocking prerequisites on #5/#6 as prose siblings only, never the literal phrase, so the gate silently no-op'd and #7 was picked/resolved (shiploop#75) before #5/#6 landed — the exact case the supervisor flagged after the fact. The enforcement already exists; it was just undocumented.
- `scripts/govern/file-ticket.sh`: add a `--depends-on N[,M...]` flag (same pattern as the existing `--model`/`--flow`/`--flow-op` flags, ~line 42-66) that emits a `**Depends on:** #N, #M` line into the filed ticket's leading field block — why: gives a ticket-filer a structured, typo-proof way to declare a blocking prerequisite instead of hand-writing prose that must exactly match `govern::ticket_deps`'s regex, removing the single point of failure that caused #7's ordering miss.
- `scripts/govern/lint-tickets.sh`: add an advisory (WARN-only, non-blocking, exit 0) pass alongside the existing duplicate-heading check that flags when a ticket's body/`Ref:` line names another still-open ticket via relationship language ("sibling", "interface contract", "consumes", etc.) but that number never appears in `govern::ticket_deps`'s parsed output for it — e.g. "#N mentions #K as related but has no `Depends on:` declaration — confirm #K isn't a blocking prerequisite" — why: would have surfaced the #7→#5/#6 mismatch to a human before a worker was ever spawned.

## 2026-07-11 03:56 — run run-20260711-033247 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-11 03:56:** 2 safe proposal(s) → ticket **#10**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

ExitPlanMode isn't available in this session, so I'll finalize directly with the required output format.

- `scripts/govern/spawn-worker.sh`: add a `GOVERN_FIX_CI` prompt-override block (mirrored on the existing `GOVERN_RESOLVE_CONFLICT` block at spawn-worker.sh:214-236) instructing a CI-fix-redispatch worker that the PR already exists, not to redo the ticket, and to query `gh pr checks`/`gh run view --log-failed` to diagnose the actual CI failure before fixing — currently `GOVERN_FIX_CI` is set by run-loop.sh:275 but never read anywhere in spawn-worker.sh, so the redispatched worker gets the plain first-attempt prompt with no idea CI is red or why, and just re-verifies locally and resubmits (the traced cause of ticket #5's `PR#76(CI-red-left-open)` outcome) — why: this is the direct, code-confirmed root cause, not a one-off worker mistake.
- `scripts/govern/run-loop.sh` (`merge_pr_for_ticket`, ~line 273-276): before each CI-fix redispatch, capture the failing check name(s) via `gh pr checks "$pr" --repo "$(govern::repo_slug "$repo")" --json name,bucket`, then (a) pass them into the worker prompt via a new `GOVERN_FIX_CI_DETAIL` var, and (b) append them to the `"CI-red-left-open"` log line / `pr_summary` so the state note surfaces "which check failed" to the operator without opening GitHub — why: right now neither the redispatched worker nor the operator has any CI-failure detail; both have to dig on GitHub manually.

`GOVERN_CI_FIX_TRIES` (one retry before parking) is a cost/safety bound, not a bug — **OPERATOR DECISION**, not touched.
