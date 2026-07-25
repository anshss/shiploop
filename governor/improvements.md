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

## 2026-07-11 03:57 — run run-20260711-033248 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-11 03:57:** 5 safe proposal(s) → ticket **#11**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

The plan file is written. Since this is a read-only harness-improvement review (not an implementation task), here is the required deliverable directly:

- `scripts/govern/lint-tickets.sh` (+ new `govern::lint_dependency_phrasing` helper in `scripts/govern/lib/common.sh`): flag a ticket whose body references another ticket number alongside dependency language ("sibling", "owned by", "interface contract", "dependency:", "built on", "blocked by") but has no literal `**Depends on:** #N` line — why: tickets #6 and #7 both said they depended on #5 ("OWNED by sibling ticket #5", "DEPENDENCY: ..."), but neither used the phrase `depends on` that `govern::ticket_deps` (`common.sh:1107`) requires, so the existing #119 pre-spawn gate (`run-loop.sh:674-690`, built specifically to prevent this class of problem) never fired and both merged while #5 stayed open.
- `scripts/govern/file-ticket.sh`: add a `--depends-on <N[,N…]>` flag parallel to the existing `--model`/`--flow`/`--flow-op` flags, emitting a normalized `**Depends on:** #N` line — why: the only way to trigger the dependency gate today is to hand-type the exact phrase from memory; a first-class flag makes correct syntax the default, which matters most for LLM-filed tickets (as #5/#6/#7 were).
- `queue/tickets.md` header (near line 13) or `governor/worker-prompt.md`: document the required `**Depends on:** #N` syntax next to the existing "sibling ticket"/"interface contract" filing convention — why: this run's filing template was clearly disciplined but never mentioned the one phrase that's actually machine-read.
- `governor/supervisor-prompt.md` (schema ~line 26-28) + `scripts/govern/escalations-emit-pending.sh` (lines 36-41): add a structured `orderingRisks: [{ticket, blockedOn, note}]` field alongside the free-text `concerns` array, and promote non-empty entries into durable `## Open` items in `governor/escalations.md` — why: this run's supervisor already spotted the exact risk in prose, but it only lives in this run's ephemeral review.md/pending-escalations.json, which the next run's own review.md overwrites — the reconciliation check needed when #5 lands could be silently lost.
- `scripts/govern/lib/common.sh` (`govern::ticket_deps` gate consumed by `run-loop.sh:674-690`): once a dependency is declared, also confirm the dependency's PR actually merged (reuse `govern::pr_state`, already used by `govern::waits_refresh`), not just that the ticket entry was deleted — why: `queue/tickets.md`'s own convention defines "Resolved = PR opened" (not merged), so a correctly-declared dependency could still race an unmerged foundation through a narrower version of the same gap.

None of these touch hard-stops, run bounds, the permission gate, or the merge allowlist — all are additive lints/flags/schema fields that tighten an already-intentional dependency mechanism.

The plan/findings are saved at `/Users/anshs/.claude/plans/govern-improve-you-are-reviewing-merry-curry.md`.

## 2026-07-11 04:06 — run run-20260711-035801 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-11 04:06:** 2 safe proposal(s) → ticket **#12**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

**GOVERN-IMPROVE output:**

- scripts/govern/run-loop.sh: in the `red)` case (~lines 907–913) of the merge-repo PR walk, attach a `.escalation` object to `$report` and set `status="parked"` (not `"failed"`) — exactly like the adjacent `unmergeable)`/`error)`/`external-blocked)` cases — so a PR that's still CI-red after the fix-worker retry gets a real `## Open` entry in `governor/escalations.md` instead of silently landing in `state.jsonl` as `failed` with no escalation. This is what happened to ticket #5 (`shiploop#76` left open on red CI, no escalation filed).
- scripts/govern/run-loop.sh: same fix also closes a second-order bug — the `#60` consecutive-failure circuit breaker (`consecutive_fails`, line ~700) is only checked when `-z "$resumed"`, but a red-CI ticket always has an open PR to resume, so it currently bypasses the circuit breaker entirely and would silently re-dispatch a fresh CI-fix worker on every future run indefinitely. Parking it removes it from selection via the existing escalation-exclusion path, so no separate change to the `resumed` branch is needed.

## 2026-07-25 05:53 — run run-20260725-053915 (resolved/parked/failed observed)

ExitPlanMode isn't available in this context, so I'll deliver the review output directly, as the GOVERN-IMPROVE task requires.

I read this run's full ticket queue and the relevant harness scripts before proposing anything. Both friction patterns the supervisor flagged this run — the #9/#11 duplicate proposals, and the #13/#17/#18/#19/#20/#22/#25/#26 same-file cluster with no declared Depends-on — are already tracked by open tickets #27–#30. Re-proposing those fixes would itself be the duplication anti-pattern under review, so I didn't. What's genuinely uncovered is that nothing in the pipeline *scripts* duplicate-ticket or same-file-conflict detection — it's all ad-hoc human/LLM judgment today. Output:

- scripts/govern/govern-improve.sh: when assembling this reviewer's context, append a compact digest of currently-open tickets (title, severity, and `Where:` target files only — no body) sourced from `queue/tickets.md` — why: this run's supervisor notes described friction (#9/#11 duplicates, the #13/#17/#18/#19/#20/#22/#25/#26 same-file cluster) that turned out to already be tracked by #27-#30, but the reviewer had no way to know that without re-reading the entire ticket queue from scratch; a cheap open-ticket index lets future reviews skip re-proposing already-tracked fixes and spend their budget on genuinely new friction instead.
- scripts/govern/govern-improve-triage.sh: before filing a new "promote safe proposals from run-<id>" ticket, check whether an already-open ticket also carries the "Auto-promoted from governor/improvements.md by govern-improve-triage.sh" marker and proposes overlapping fixes (same target file(s) in its bullet list) — if so, append the new run's additional bullets to that existing ticket's body instead of filing a new `## #N` — why: this is the exact mechanism that produced #9 and #11 as near-duplicates (independently auto-promoted from two different runs, proposing the same Depends-on/lint work); today the only fix is a human/reviewer noticing after the fact and filing a merge ticket (#30) — without a filing-time check the pattern will keep recurring every time two runs' reviewers spot the same gap independently.
- scripts/govern/lint-tickets.sh (+ a new helper in scripts/govern/lib/common.sh, parallel to govern::ticket_deps): add an advisory WARN-only check that flags open tickets whose `Where:` lines share a target file but declare no `Depends on:` link (in either direction) between them — why: this run's supervisor note manually spotted that #13/#17/#18/#19/#20/#22/#25/#26 all target spawn-worker.sh/worker-prompt.md/run-loop.sh with no declared Depends-on, risking collisions once #14's parallel-by-default mode lands ahead of #23's locality-batching; today that detection is entirely delegated to the supervisor LLM's prose judgment (per governor/supervisor-prompt.md's "Duplicates / overlap" guidance) with no scripted backstop — a lint pass makes it a durable, always-on signal instead of something that has to be noticed fresh each run.

One incidental note: one background research agent's output was flagged by the harness as containing "instruction-shaped" text — on inspection it was just the agent quoting literal strings from the codebase (`--permission-mode plan`, `bypassPermissions`) while describing how `govern-improve.sh` and `govern-supervise.sh` invoke their reviewer/supervisor subprocesses. Nothing injected, no action taken on it.
