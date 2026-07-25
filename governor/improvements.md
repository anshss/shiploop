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

## 2026-07-25 06:25 — run run-20260725-053951 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 06:25:** 4 safe proposal(s) → ticket **#36**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

No `ExitPlanMode` tool is available in this session, so I'll deliver the required GOVERN-IMPROVE output directly (findings saved to `/Users/anshs/.claude/plans/govern-improve-you-are-reviewing-piped-moth.md`).

I checked `governor/improvements.md` first — the same #9/#11/#30 friction was already reviewed once today (05:53 run) and produced three not-yet-ticketed proposals (open-ticket digest for the reviewer, a dedup-before-filing check in `govern-improve-triage.sh`, and a same-`Where:`-file lint). Re-proposing those would itself be the anti-pattern under review, so this covers only gaps those don't close, verified directly against the code:

- `queue/tickets.md` + `scripts/govern/select-ticket.sh`: add a `**Blocks:** #N[, #M...]` optional field, parsed the same tolerant way `select-ticket.sh` already parses `**Severity:**`, and have it feed the exclusion set the same way `## Open` escalations already do — why: nothing today stops #9 or #11 from being independently selected even though #30 already says they duplicate each other and should be merged first. The 05:53 proposals prevent *future* duplicate pairs; they don't give the *existing* #30 any teeth to actually block #9/#11 in the meantime.
- `scripts/govern/run-loop.sh` (~line 754, where a worker's `crossRefs.overlaps`/`crossRefs.dependsOn` is read off its report): write that back as a `Blocks:`/`Depends on:` line on the referenced ticket, or file it as an `## Open` escalation, instead of only setting `anomaly=1` for one supervisor glance — why: a worker has the freshest evidence of a real overlap while doing the work, and today that evidence is discarded after a single pass instead of durably blocking the ticket it names.
- `scripts/govern/lint-tickets.sh` (or `file-ticket.sh` at filing time): WARN (non-blocking) when a ticket's body names a CLI flag/env var (`--foo`, `GOVERN_*`) or "the orchestrator"/"N drivers" that doesn't grep-match anything in this workspace's current `scripts/govern/*.sh` — why: I confirmed directly that `#33`/`#34` describe `GOVERN_PARALLEL_DEFAULT`/`--parallel` orchestrator machinery that exists only in the hub template (`shiploop/templates/govern/run-loop.sh`), not in this workspace's copy (ticket #35 already flags the lag) — dispatching a worker at either ticket today would burn a session on a target that isn't there yet, likely a confused park/fail rather than a clean block.
- `queue/tickets.md`: add `**Depends on:** #35` to #33 and #34's field blocks (a data-only fix, zero script changes) — the existing `govern::ticket_deps` gate already honors literal "depends on #N" prose today, so this alone stops either from being dispatched before #35 (the hub-sync bump) lands.

None of these touch hard-stops, run bounds, the permission gate, or the merge allowlist — all are additive fields/lints/write-backs.

## 2026-07-25 06:41 — run run-20260725-060424 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 06:41:** 4 safe proposal(s) → ticket **#39**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

I've verified everything against the actual scripts (not just supervisor prose) and written the full analysis to the plan file at `~/.claude/plans/govern-improve-you-are-reviewing-mellow-globe.md`. The `ExitPlanMode` tool isn't wired up in this environment, so here's the final deliverable directly:

**Key discovery:** both of this run's friction points already have fixes built in the hub template (`shiploop/templates/govern/`) — they just haven't synced into this workspace's `scripts/govern/` copy (1402 vs 1708 lines in `lib/common.sh`, confirmed via `diff`).

```markdown
- `queue/tickets.md`: add `**Depends on:** #35` to tickets #33 and #34's field blocks now — a zero-script, data-only fix (ticket #36 already proposes this) — why: `govern::ticket_deps`/the #119 pre-spawn gate only honors the literal bold marker, so until this line lands either ticket could be selected and dispatched before #35 (the hub-sync bump) lands, burning a worker session on machinery this workspace's `scripts/govern` copy doesn't have yet.
- `scripts/govern/lib/common.sh`, `scripts/govern/lint-tickets.sh`, `scripts/govern/file-ticket.sh`: sync these from `shiploop/templates/govern/` (hub→workspace sync, e.g. `/shiploop:update`) — why: the hub template already implements `govern::prose_dep_warnings` (flags prose-only dependency phrasing like "sibling ticket #N" lacking a canonical `**Depends on:**`/`**Blocks:**` marker) and a duplicate-title advisory check in `file-ticket.sh` (flags `⚠ possible duplicate of #M` on >50% title-word overlap with an open ticket) — exactly the two mechanisms that would have caught this run's frictions (#33/#34's undeclared dependency, #38 re-filing #30's merge instruction). The workspace's `common.sh` is missing both blocks entirely — this is sync drift, not a missing feature; the fix already exists in this same repo.
- `scripts/govern/govern-improve.sh`: append a compact open-ticket digest (number, title, severity, `Where:` target files — no body) from `queue/tickets.md` when assembling this reviewer's context — why: confirmed absent from both the workspace and hub-template copy, so every improve run re-derives friction from scratch with no way to check "is this already tracked?" — the exact gap that let #38 restate #30's #9/#11-merge instruction.
- `scripts/govern/govern-improve-triage.sh`: before auto-filing a new "promote safe proposals" ticket, check whether an already-open ticket carries the same auto-promotion marker and targets overlapping files/tickets; if so, append the new bullets to that existing ticket's body instead of filing a new `## #N` — confirmed absent from both workspace and hub copy — why: this is the actual mechanism (two runs' reviewers independently auto-promoting overlapping fixes) that produced the #30/#38 duplicate pair.
```

None of these touch a safety rail, so no OPERATOR DECISION flags needed.

## 2026-07-25 07:15 — run run-20260725-063340 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 07:15:** 4 safe proposal(s) → ticket **#42**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

**GOVERN-IMPROVE output** (findings saved to `/Users/anshs/.claude/plans/govern-improve-you-are-reviewing-jiggly-journal.md`):

I checked `governor/improvements.md`'s full history before proposing anything — the #9/#11 duplicate, the #33 missing `Depends on: #35`, and the six-tickets-piling-up pattern have each been raised 2-3 times already since 2026-07-11 and never applied. Re-proposing them verbatim would be the exact amplification anti-pattern under review, so I verified *why* they keep recurring instead: I read `scripts/govern/govern-self-apply.sh` in full, and its `ALLOWED` allowlist (`select-ticket.sh await-ci.sh merge-pr.sh spawn-worker.sh run-loop.sh dry-run.sh`) structurally excludes every file these recurring proposals target (`lib/common.sh`, `file-ticket.sh`, `lint-tickets.sh`, `govern-improve.sh`, `govern-improve-triage.sh`, `queue/tickets.md`) — by design, since those are policy/bookkeeping files. That's the real root cause: these fixes were never eligible for auto-apply, and nothing surfaces that fact, so they get re-proposed instead of escalated.

- `governor/improvements.md` (via `govern-improve.sh`'s output contract): tag each proposal bullet `[self-apply-eligible]` or `[policy-file — needs human/ticket]` based on whether its target file is in `govern-self-apply.sh`'s allowlist — why: makes visible at proposal time which fixes are structurally stuck and need a human/ticket, instead of silently re-proposing the same policy-file fix run after run.
- `scripts/govern/govern-improve-triage.sh`: before filing a new "promote safe proposals from run X" ticket, check for an already-open ticket with the same auto-promotion marker and overlapping target files, and append instead of filing a new one — why: proposed 3 times now (05:53, 06:25, this run) and still unapplied; #9/#10/#11/#12/#36/#39 are the visible cost.
- `queue/tickets.md`: add `**Depends on:** #35` to ticket #33's field block — a one-line, zero-script, data-only fix an operator can apply directly right now.
- `scripts/govern/select-ticket.sh`: WARN in the selection log when 2+ open tickets match `^Harness self-improvement: promote safe proposals` — why: gives the run loop itself a nudge toward the merge the supervisor has now requested three runs in a row.

**OPERATOR DECISION**: `govern-self-apply.sh`'s allowlist deliberately excludes policy/bookkeeping files from auto-apply — the correct trade-off (those files shouldn't be agent-edited without review), but it's the direct reason the last six runs' top proposals never landed automatically. Not proposing to widen it — only to make "stuck behind the allowlist" visible.

## 2026-07-25 07:40 — run run-20260725-071539 (resolved/parked/failed observed)

I've completed the review and written the analysis to the plan file. Since this is a read-only GOVERN-IMPROVE proposal task (no ExitPlanMode tool is available in this context), here is the final deliverable per the required output format:

- `scripts/govern/file-ticket.sh`: port the duplicate-detection block from `shiploop/templates/govern/file-ticket.sh:165-188` (title-word-overlap check that appends "⚠ possible duplicate of #M" when a new ticket's title overlaps >50% with an existing open one) into the workspace copy, which has zero dedup logic today — this is the highest-leverage fix and already exists upstream (what #35 proposes; expedite it over #30/#38).

- `scripts/govern/lib/common.sh` + `scripts/govern/lint-tickets.sh`: port `govern::prose_dep_warnings` from the hub's `lib/common.sh` (absent from the workspace copy) and wire it into `lint-tickets.sh` (currently only checks `govern::duplicate_ticket_headings`) — flags tickets that reference another ticket in prose without a canonical `**Depends on:**` field, the exact gap #38 fell into.

- `scripts/govern/govern-improve-triage.sh`: before calling `file-ticket.sh` (line 116), check already-open tickets carrying an `AUTO-PROMOTED`/`AUTO-TRIAGE` marker for title/content overlap with the new proposal, reusing the same helper added to `file-ticket.sh` — today idempotency only checks within a single `improvements.md` block, never against sibling open tickets, which is how #9/#10/#11/#12/#36/#39 accumulated one-per-run.

- `scripts/govern/select-ticket.sh`: call `govern::ticket_deps()` (already implemented in `lib/common.sh:1099-1116`, currently unused by the selector) and skip/defer any ticket whose declared dependency is still open — right now `Depends on:` is parsed but never enforced at selection time.

- `scripts/govern/run-loop.sh`: append the worker's end-of-run `crossRefs.overlaps`/`crossRefs.dependsOn` self-report (per `worker-prompt.md:192-195`) to `governor/decisions-log.md` (currently empty) instead of discarding it after only setting `anomaly=1` — this signal is currently lost after one run.

- **OPERATOR DECISION**: `govern-self-apply.sh`'s `ALLOWED` allowlist structurally excludes `lib/common.sh`, `file-ticket.sh`, `lint-tickets.sh`, `govern-improve.sh`, `govern-improve-triage.sh`, and `queue/tickets.md` from auto-apply. This is why the above fixes have been proposed three times and never applied — but it's the correct rail, since these files control ticket-filing/dedup logic and the queue itself. Trade-off: closing this loop requires an operator to merge the sync ticket manually; not proposing to weaken the allowlist.

## 2026-07-25 11:47 — run run-20260725-112937-10735 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 11:47:** 4 safe proposal(s) → ticket **#47**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

Investigation complete. Here's the harness-improvement proposal for this run:

- `governor/worker-prompt.md`: Add an explicit instruction to check CI baseline before declaring `resolved` — compare the PR's failing checks against `gh run list --branch main --limit 3` (or equivalent) to determine whether a red check predates the worker's own change — why: ticket #46's worker rediscovered this exact lesson after the fact, but the harness discarded it before it reached CLAUDE.md; teaching it up front prevents every future worker from rediscovering it and wasting CI-fix cycles on unrelated upstream breakage.
- `scripts/govern/run-loop.sh` (resolved→failed CI-red downgrade path) / `scripts/govern/govern-bookkeep.sh`: persist any `lessonPatch` a worker returned even when the ticket gets CI-downgraded to failed (e.g. append to `governor/improvements.md`), instead of silently dropping it because `govern-bookkeep.sh` only runs in the `status=="resolved"` branch — why: this run is direct proof a genuinely useful lesson was generated and then lost; without this fix the harness keeps losing valid lessons every time a resolved ticket gets downgraded.
- `scripts/govern/run-loop.sh` (`merge_pr_for_ticket` CI-fix redispatch): before spending the single `GOVERN_CI_FIX_TRIES` retry, check whether `origin/main`'s own latest CI run is already red (baseline-red); if so, skip the fix-dispatch and record a distinct note like `CI-red-baseline-preexisting` instead of `CI-red-left-open` — why: if CI was already broken on main, the CI-fix worker is doomed by construction, burning the one retry and mislabeling the failure as the ticket's fault — exactly the scenario #46's worker diagnosed on its own.
- `governor/README.md`: document that a re-selected ticket with an already-open PR is adopted via `govern::find_pr` without spawning a new worker and is re-fed through `await-ci.sh` on the next run — why: this auto-retry-on-reselection behavior isn't documented, so an operator seeing "failed, worktree preserved" might intervene (e.g. delete the worktree) in a way that breaks that adoption path.

None of these touch safety rails (hard-stops, run bounds, permission gate, merge allowlist).

## 2026-07-25 12:12 — run run-20260725-111729-96725 (resolved/parked/failed observed)

This run itself was clean (ticket #23 resolved/merged). The friction is a harness gap: `govern-improve-triage.sh` has no dedup against already-open promotion tickets, and I confirmed 8 near-duplicate "Harness self-improvement: promote safe proposals" tickets currently sit open in `queue/tickets.md` (#9, #10, #11, #12, #36, #39, #42, #47) — a fix for this has already been self-proposed by the harness three separate times and never applied.

- `scripts/govern/govern-improve-triage.sh`: before calling `file-ticket.sh` (line 117), search `queue/tickets.md` for an already-open ticket whose heading matches `^## #\d+ — Harness self-improvement: promote safe proposals` (or carries the block's AUTO-PROMOTED marker); if one exists, append this run's safe bullets into that ticket's existing body instead of filing a new numbered ticket — why: this exact fix has been self-proposed three times (tickets #36, #39, #42) and never applied, directly causing the 8-ticket pile-up.
- `scripts/govern/govern-improve.sh`: include a compact open-ticket digest (number, title, severity, `Where:` target) in the reviewer's context when assembling a new run's proposals — why: confirmed absent from the script; its absence is why proposals keep restating already-filed fixes (#38 restating #30; #36/#39/#42 each re-proposing the same dedup fix).

No rail-touching items found.

## 2026-07-25 12:12 — run run-20260725-111730-97043 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 12:12:** 5 safe proposal(s) → ticket **#50**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

Both `ExitPlanMode` and `AskUserQuestion` are unavailable in this session, so this is evidently a headless/scripted invocation rather than an interactive plan-mode session — the actual deliverable here is the analysis text itself. Delivering it now, per the GOVERN-IMPROVE output contract:

- `scripts/govern/spawn-worker.sh`: add a `GOVERN_FIX_CI` handling block (mirroring the existing `GOVERN_RESOLVE_CONFLICT` block at spawn-worker.sh:239-261) that injects the PR number, an excerpt of the actually-failing CI job's log, and "a prior attempt already implemented this — your job is ONLY to fix the failing check" framing — this run's #19 worker had to rediscover the existing-PR-with-red-CI situation entirely from scratch, burning budget and hitting a stray `cd templates/govern/test: no such file or directory`. This exact gap is already named as open tickets #10/#13 in `scripts/govern/test/test-ticket-deps-prose.sh:31`; this run is a live, reproduced instance of it.
- `scripts/govern/run-loop.sh` (~line 1279, the CI-red downgrade branch `[[ "$status" == "resolved" ]] && status="failed"`): apply `.lessonPatch` even when status gets downgraded to `failed`/`parked`. Today `govern-bookkeep.sh` (the only place a `lessonPatch` gets written into CLAUDE.md) is invoked only from the `resolved)` branch at run-loop.sh:1385, so ticket #19's fully-diagnosed anti-pattern lesson ("attribute CI red against the base commit's own run, not yours") was silently dropped despite being captured in the worker's own report.json.
- `scripts/govern/run-loop.sh` (~line 285, the `excludes` variable): the "already-worked-this-run" exclude tracking is a plain per-process shell variable, not synchronized across parallel child drivers. Under the default `GOVERN_PARALLEL_DEFAULT=4` (run-loop.sh:134), a killed-before-verdict ticket can be double-processed, producing duplicate `timeout` entries — the actual root cause behind `test-budget-exceeded-classification`/`test-timeout-classification` failing in CI. Make the exclusion atomic (shared lock-guarded file all children re-read) instead of relying on each child's local variable.
- `scripts/govern/config-check.sh`: add a drift check between this workspace's `scripts/govern/test/*.sh` and the hub's `templates/govern/test/*.sh`. The hub's copy of the two failing tests already pins `--serial` as a band-aid for the race above; this workspace's copy doesn't have that pin yet, which is exactly why CI (built fresh from hub templates) failed while local verification (this workspace's stale copy) passed.
- `governor/worker-prompt.md` or root `CLAUDE.md`: add a one-line note on the `templates/govern/` vs `scripts/govern/` split (templates/ = canonical distributable copy synced via sync-templates.sh; scripts/ = this repo's own live/dogfood copy — run tests from scripts/, never `cd` into templates/ directly) — this run's worker guessed the wrong path and hit a dead end.

## 2026-07-25 12:17 — run run-20260725-120551-43436 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 12:17:** 3 safe proposal(s) → ticket **#51**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

Plan mode's exit tool isn't wired up in this context, so I'll deliver the actual GOVERN-IMPROVE output directly, per the task's own format contract.

- `scripts/govern/lint-tickets.sh`: add a non-blocking WARN pass (alongside the existing duplicate-heading check) that validates every `**Depends on:** #N` / `**Blocks:** #N` / `Ref: #N` pointer resolves to a `## #N` heading still present in `queue/tickets.md` — why: #36 and #39 (this run's own promoted tickets) both propose "add `Depends on: #35` to #33 and #34," but #33/#34 no longer exist in the open queue; nothing today would have caught either proposal referencing a closed ticket, so the same stale-reference mistake will keep recurring silently.

- `scripts/govern/file-ticket.sh`: extend the existing title-word-overlap duplicate check (which only compares the new ticket's title against other `## #N` headings) to also compare its `Where:`/target-file text against every open ticket's `Where:` field, and when two open tickets name overlapping files, auto-emit `**Depends on:** #<older>` into the new ticket's body instead of only the cosmetic `⚠ possible duplicate of #M` marker — why: #9, #11, and #38 all touch `common.sh`/`lint-tickets.sh`/`file-ticket.sh`, the exact files #35's hub-sync will overwrite, and none declares a dependency on #35; the file-overlap check that exists today (`common.sh:826-857`) is scoped only to sync-port escalations, not general open-ticket-vs-open-ticket collisions, so this class of risk is invisible outside that one path.

- `scripts/govern/govern-improve-triage.sh`: implement the dedup-before-filing check that #30, #39, and #42 have each already proposed and none has landed — before filing a new "promote safe proposals from run-X" ticket, check whether an open ticket already carries the same auto-promotion marker and append the new bullets to it instead of minting a new `## #N` — why: this is now empirically the highest-friction gap in the harness — it has produced 9 open duplicate tickets (#9, #10, #11, #12, #36, #39, #42, #47, #50) across 9 runs, and the duplicate-title advisory that would flag it at filing time (`file-ticket.sh`'s `⚠ possible duplicate of #M`) is confirmed firing correctly (visible on #47 and #50) but is purely cosmetic — nothing consumes it to actually merge or block, so it decorates the exact problem it detects without fixing it.

## 2026-07-25 12:23 — run run-20260725-111845-99416 (resolved/parked/failed observed)

> **AUTO-PROMOTED 2026-07-25 12:23:** 2 safe proposal(s) → ticket **#53**. 0 rail-touching/OPERATOR-DECISION proposal(s) held here behind the human gate (govern-improve-triage.sh, #274).

Plan mode isn't actually wired up in this context (ExitPlanMode isn't available), so I'll deliver the GOVERN-IMPROVE result directly as required by the task's output format.

- `scripts/govern/govern-improve-triage.sh`: before filing a new "Harness self-improvement: promote safe proposals from run X" ticket, scan `queue/tickets.md` for an already-open ticket whose title matches `^Harness self-improvement: promote safe proposals` and append this run's safe-proposal bullets to it instead of calling `file-ticket.sh` again — why: this gap has already produced 10 near-duplicate tickets (#9, #10, #11, #12, #36, #39, #42, #47, #50, #51), each triggering a separate full worker dispatch on largely the same proposals; the fix was already specified in ticket #42's own body (and independently in #30/#38) but has no owner because it keeps getting buried under a fresh "promote safe proposals" ticket instead of ever being selected.
- `scripts/govern/select-ticket.sh`: WARN in the selection log when 2+ open tickets match `^Harness self-improvement: promote safe proposals` (same shape as the existing `govern::sync_port_collision_tickets` exclusion added for #314) — why: gives the run loop a visible, repeating nudge toward consolidating the pile every cycle until the triage fix above lands, instead of the duplication silently growing run after run.
