# Tickets

The work queue. **Work items only** — bugs, gaps, missing capabilities, follow-ups; anything to
fix/build later. NOT a learnings file (transient knowledge → `learnings.md`) and NOT a fixed-bug
writeup (durable lesson → `CLAUDE.md`).

Each ticket is its own numbered `## #N — Title` block. **Numbers are stable IDs while a ticket is
open** — never renumber an open ticket (in-flight PRs/commits reference it). Gaps from
resolved-and-deleted tickets are expected. Numbering is **per-queue**: this file and the parked queue
(`queue/tickets-parked.md`) are each their own serial `## #N` list; a new ticket takes **this file's own
highest `## #N` + 1**.

**Resolved = a fix PR is opened** (not merged). DELETE the entry in the same session the PR opens
(git history + the PR are the record); reference the PR# in the deletion commit. Before deleting,
promote any durable lesson to `CLAUDE.md`. Use `/resolve <N>` to do this the disciplined way.

The governor reads this file: severity-orders the open tickets (High > Medium > Low > unknown), works
the top one, then deletes it on resolve. Keep entries in the shape below so the parser finds them.

---

### Optional per-ticket fields

- **`Model:`** — pin the model the governor uses for THIS ticket's worker (first attempt only).
  Values: `haiku` (mechanical rename, doc edit, single-file lookup fix) · `sonnet` (standard search
  + edit tickets — the workhorse default when a High-tier isn't warranted) · `opus` (judgment-heavy
  refactors, architectural moves, hard tickets). If absent, the governor uses `GOVERN_WORKER_MODEL`
  (default `opus`). Any retry unconditionally escalates to `GOVERN_WORKER_MODEL` — cheap tier is a
  first-shot bet, never a retry ceiling. Unknown values are ignored (fail-safe). File with
  `scripts/govern/file-ticket.sh --model sonnet "..."`.

---

## #4 — README landing page never reaches existing workspaces via /shiploop:update

**Severity:** Low
**Model:** sonnet

Where: shiploop/scaffold.sh (component_readme) + shiploop/commands/update.md (Phase 3 bump loop)
Observed: the README landing-page feature (component_readme) only runs under `--component all` or `--component readme`. /shiploop:update Phase 3 bumps only mechanism components (core-scripts worktrees govern githooks commands workflows) + seeds + settings-merge, and README is not in MECH_COMPONENTS (--diff-only drift set). So existing workspaces scaffolded before the feature never gain a root README on update. Also component_readme reads ROOT_PM from $PM (default npm) and repos from --repos, but update passes neither, so an update-generated README would show wrong PM + generic repo list.
Fix direction: (1) component_readme: when --pm/--repos are absent, source scripts/lib/workspace.sh and read ROOT_PM + REPOS for accurate content. (2) update.md Phase 3: add `readme` to the bump loop (safe — component_readme never overwrites an existing README).
Done when: running /shiploop:update in a workspace with no root README creates an accurate `<Project> on Shiploop` README (correct PM + sub-repos); a workspace with an existing README is left untouched; a workspace with no ROOT_PM resolvable still produces a sane default.
Ref: session 2026-07-11 — README feature shipped (commit 9828a35); update-gap surfaced while answering whether /shiploop:update creates a README.

---

## #9 — Harness self-improvement: promote safe proposals from run-20260711-033250

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260711-033250. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `queue/tickets.md`: document `**Depends on:** #K[, #J...]` as a first-class "Optional per-ticket field" (next to the existing `Model:` entry, ~line 22-31) — state that this exact phrase is what `govern::ticket_deps()` (`scripts/govern/lib/common.sh:1095-1116`) parses and what the #119 pre-spawn gate (`run-loop.sh:673-688`) enforces, and that "Ref:"/"siblings"/other prose is not machine-read — why: #7 (commit `49c3c8c`) declared its real blocking prerequisites on #5/#6 as prose siblings only, never the literal phrase, so the gate silently no-op'd and #7 was picked/resolved (shiploop#75) before #5/#6 landed — the exact case the supervisor flagged after the fact. The enforcement already exists; it was just undocumented.
- `scripts/govern/file-ticket.sh`: add a `--depends-on N[,M...]` flag (same pattern as the existing `--model`/`--flow`/`--flow-op` flags, ~line 42-66) that emits a `**Depends on:** #N, #M` line into the filed ticket's leading field block — why: gives a ticket-filer a structured, typo-proof way to declare a blocking prerequisite instead of hand-writing prose that must exactly match `govern::ticket_deps`'s regex, removing the single point of failure that caused #7's ordering miss.
- `scripts/govern/lint-tickets.sh`: add an advisory (WARN-only, non-blocking, exit 0) pass alongside the existing duplicate-heading check that flags when a ticket's body/`Ref:` line names another still-open ticket via relationship language ("sibling", "interface contract", "consumes", etc.) but that number never appears in `govern::ticket_deps`'s parsed output for it — e.g. "#N mentions #K as related but has no `Depends on:` declaration — confirm #K isn't a blocking prerequisite" — why: would have surfaced the #7→#5/#6 mismatch to a human before a worker was ever spawned.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-11 03:55 — run run-20260711-033250 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #10 — Harness self-improvement: promote safe proposals from run-20260711-033247

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260711-033247. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `scripts/govern/spawn-worker.sh`: add a `GOVERN_FIX_CI` prompt-override block (mirrored on the existing `GOVERN_RESOLVE_CONFLICT` block at spawn-worker.sh:214-236) instructing a CI-fix-redispatch worker that the PR already exists, not to redo the ticket, and to query `gh pr checks`/`gh run view --log-failed` to diagnose the actual CI failure before fixing — currently `GOVERN_FIX_CI` is set by run-loop.sh:275 but never read anywhere in spawn-worker.sh, so the redispatched worker gets the plain first-attempt prompt with no idea CI is red or why, and just re-verifies locally and resubmits (the traced cause of ticket #5's `PR#76(CI-red-left-open)` outcome) — why: this is the direct, code-confirmed root cause, not a one-off worker mistake.
- `scripts/govern/run-loop.sh` (`merge_pr_for_ticket`, ~line 273-276): before each CI-fix redispatch, capture the failing check name(s) via `gh pr checks "$pr" --repo "$(govern::repo_slug "$repo")" --json name,bucket`, then (a) pass them into the worker prompt via a new `GOVERN_FIX_CI_DETAIL` var, and (b) append them to the `"CI-red-left-open"` log line / `pr_summary` so the state note surfaces "which check failed" to the operator without opening GitHub — why: right now neither the redispatched worker nor the operator has any CI-failure detail; both have to dig on GitHub manually.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-11 03:56 — run run-20260711-033247 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #11 — Harness self-improvement: promote safe proposals from run-20260711-033248

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260711-033248. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `scripts/govern/lint-tickets.sh` (+ new `govern::lint_dependency_phrasing` helper in `scripts/govern/lib/common.sh`): flag a ticket whose body references another ticket number alongside dependency language ("sibling", "owned by", "interface contract", "dependency:", "built on", "blocked by") but has no literal `**Depends on:** #N` line — why: tickets #6 and #7 both said they depended on #5 ("OWNED by sibling ticket #5", "DEPENDENCY: ..."), but neither used the phrase `depends on` that `govern::ticket_deps` (`common.sh:1107`) requires, so the existing #119 pre-spawn gate (`run-loop.sh:674-690`, built specifically to prevent this class of problem) never fired and both merged while #5 stayed open.
- `scripts/govern/file-ticket.sh`: add a `--depends-on <N[,N…]>` flag parallel to the existing `--model`/`--flow`/`--flow-op` flags, emitting a normalized `**Depends on:** #N` line — why: the only way to trigger the dependency gate today is to hand-type the exact phrase from memory; a first-class flag makes correct syntax the default, which matters most for LLM-filed tickets (as #5/#6/#7 were).
- `queue/tickets.md` header (near line 13) or `governor/worker-prompt.md`: document the required `**Depends on:** #N` syntax next to the existing "sibling ticket"/"interface contract" filing convention — why: this run's filing template was clearly disciplined but never mentioned the one phrase that's actually machine-read.
- `governor/supervisor-prompt.md` (schema ~line 26-28) + `scripts/govern/escalations-emit-pending.sh` (lines 36-41): add a structured `orderingRisks: [{ticket, blockedOn, note}]` field alongside the free-text `concerns` array, and promote non-empty entries into durable `## Open` items in `governor/escalations.md` — why: this run's supervisor already spotted the exact risk in prose, but it only lives in this run's ephemeral review.md/pending-escalations.json, which the next run's own review.md overwrites — the reconciliation check needed when #5 lands could be silently lost.
- `scripts/govern/lib/common.sh` (`govern::ticket_deps` gate consumed by `run-loop.sh:674-690`): once a dependency is declared, also confirm the dependency's PR actually merged (reuse `govern::pr_state`, already used by `govern::waits_refresh`), not just that the ticket entry was deleted — why: `queue/tickets.md`'s own convention defines "Resolved = PR opened" (not merged), so a correctly-declared dependency could still race an unmerged foundation through a narrower version of the same gap.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-11 03:57 — run run-20260711-033248 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #12 — Harness self-improvement: promote safe proposals from run-20260711-035801

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260711-035801. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- scripts/govern/run-loop.sh: in the `red)` case (~lines 907–913) of the merge-repo PR walk, attach a `.escalation` object to `$report` and set `status="parked"` (not `"failed"`) — exactly like the adjacent `unmergeable)`/`error)`/`external-blocked)` cases — so a PR that's still CI-red after the fix-worker retry gets a real `## Open` entry in `governor/escalations.md` instead of silently landing in `state.jsonl` as `failed` with no escalation. This is what happened to ticket #5 (`shiploop#76` left open on red CI, no escalation filed).
- scripts/govern/run-loop.sh: same fix also closes a second-order bug — the `#60` consecutive-failure circuit breaker (`consecutive_fails`, line ~700) is only checked when `-z "$resumed"`, but a red-CI ticket always has an open PR to resume, so it currently bypasses the circuit breaker entirely and would silently re-dispatch a fresh CI-fix worker on every future run indefinitely. Parking it removes it from selection via the existing escalation-exclusion path, so no separate change to the `resumed` branch is needed.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-11 04:06 — run run-20260711-035801 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #13 — Workers verify on macOS while CI runs Linux — inject failing-CI-log excerpts on retry + portability guidance in worker prompt

**Severity:** Medium
**Model:** sonnet

Where: shiploop/ sub-repo — worker prompt assembly (templates/govern/spawn-worker.sh worker instructions) and/or CI docs in templates/seed/CLAUDE.md

Observed: during the v1.9.0 runner build, ticket #5 burned BOTH its governor attempts on a Linux-only CI failure (BSD stat -f %m succeeds-with-garbage on GNU stat, so the worker's macOS-local test run passed while CI failed; the retry worker then fixed an unrelated test issue because it still could not reproduce the failure). Cost: 2 failed outcomes, one manual fix dispatch with a hand-extracted CI diagnosis. The harness gives workers no guidance that CI runs ubuntu while dev machines are macOS, and no nudge to read the failing CI job log before re-verifying locally.

Fix direction: (a) worker prompt gains a portability clause — target env is Linux CI; for bash, prefer GNU-first constructs with BSD fallback (stat/sed/date are the classic splits); (b) on a CI-red retry, the re-dispatched worker's prompt should include the failing job's extracted error lines (gh run view --log-failed | relevant grep) so it fixes the ACTUAL failure instead of guessing from a local run that passes; (c) optionally a lint for known BSD-only flag patterns in templates/.

Done when: worker prompt carries the portability + read-CI-log-first instructions; the CI-red re-dispatch path injects failing-check log excerpts; a note in templates/seed/CLAUDE.md anti-patterns.

Ref: PR anshss/shiploop#76 history (2 red runs, fix commit b72c82e); learnings from run-20260711-033247/035801

---

## #14 — Port --parallel from hub to workspace run-loop.sh and make N=4 the default

**Severity:** High
**Model:** sonnet

Where: scripts/govern/run-loop.sh (workspace copy) + shiploop/templates/govern/run-loop.sh (hub) + .claude/commands/govern.md + shiploop/commands/govern.md

Observed: `--parallel[=N]` is fully implemented in the HUB template `shiploop/templates/govern/run-loop.sh` (flag parse ~line 60-105; orchestrator `govern::_parallel_run` ~line 695-732; FIFO reaper `govern::_parallel_reap_one` ~line 678-693; per-ticket claim locks + bookkeep lock provide the safety model). It is ENTIRELY ABSENT from the workspace copy `scripts/govern/run-loop.sh` — 1299 lines vs the hub's 1497, and `grep -c parallel` finds no flag parsing at all. This is workspace<-hub drift (the anti-pattern named at the top of root CLAUDE.md). Consequence: the operator has been hand-launching 4 concurrent `run-loop.sh` processes in separate terminals to get fan-out (evidence: logs/govern/run-20260711-0332{47,48,50,51} launched within 4 seconds of each other), which is exactly what `--parallel` automates.

Additionally `--parallel` is undocumented in BOTH `/govern` command files — it appears only in shiploop/SKILL.md:97 — so a user reading the slash command never discovers it.

Fix direction:
(1) Port the `--parallel` orchestrator from `shiploop/templates/govern/run-loop.sh` down into `scripts/govern/run-loop.sh`. Prefer a straight port of the hub diff over re-deriving it (root CLAUDE.md anti-pattern: check whether the hub is already ahead and port its diff down).
(2) Make parallel the DEFAULT with N=4 when no explicit `--parallel`/`GOVERN_PARALLEL` is given and no single ticket target was named. Provide `--serial` (or `--parallel=1`) to opt back into one-at-a-time. Keep `--parallel=N` > `GOVERN_PARALLEL` > default precedence exactly as the hub documents it.
(3) Document the flag, the new default, and `--serial` in BOTH `.claude/commands/govern.md` and `shiploop/commands/govern.md` (the `$ARGUMENTS` section that currently lists only empty / a number / --dry-run / --exclude).

Done when: `bash scripts/govern/run-loop.sh --dry-run` reports parallel mode with a cap of 4 by default; `--serial` forces sequential; `--parallel=N` and GOVERN_PARALLEL still behave per the hub's documented precedence; both govern.md command files document all three; `bash -n` passes on every touched script; hub and workspace copies do not drift further apart (apply the same doc change to the hub command file).

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component C1

---

## #15 — Worker prompt: make the worker a router (delegate reconnaissance to cheap subagents)

**Severity:** High
**Model:** sonnet

Where: shiploop/templates/governor/worker-prompt.md (hub, canonical) and governor/worker-prompt.md (workspace copy — keep both in sync)

Observed: shiploop's token-saving thesis is applied to the wrong session. The OPERATOR session has a ROUTER POSTURE hook (scripts/router-posture-reminder.sh), a delegation rule in root CLAUDE.md, and a model-sizing guide. The WORKER session — which is 98% of all token spend — has none of it. `governor/worker-prompt.md` mentions subagents exactly 5 times (lines ~97-103) and every one is a WARNING about what a subagent cannot do (write the validation REPORT.md), never an instruction to delegate. Workers run at `--permission-mode bypassPermissions` with full tool access, so they CAN spawn subagents; they are simply never told to.

Measured consequence (governor/ticket-history.jsonl): a resolved ticket is a ~22M-token session that is 98% cacheRead — i.e. ~200+ turns of a context that grows all session as the single monolithic agent explores, edits, builds, tests and PRs in one context. Starting prompt is only ~7k tokens, so the cost is turn count x accumulated context, not prompt size.

Fix direction: add a ROUTER POSTURE section to the worker prompt, adapted from scripts/router-posture-reminder.sh:35-49:
- Classify each sub-task: trivial (one edit / one command / known one-file lookup) -> do inline; heavier (multi-file investigation, codebase sweep, diagnosis, reading a long log or build output) -> delegate to a subagent and keep only the verdict.
- HARD RULE, preserving the existing constraint at worker-prompt.md:97-103: **delegate reconnaissance, never delegate the commit, the PR, or the report write.** A subagent runs under a restrictive policy and cannot write the report; the worker must persist any structured text a subagent returns.
- Size the child model: haiku = mechanical/extract/lookup/log-reading; sonnet = search/investigation/multi-file reads; inherit only for judgment-heavy synthesis. A fan-out of N similar children is almost never inherit-tier.
- Do NOT read large files into the worker's own context; have a child read and return the conclusion.

Done when: the hub worker-prompt.md carries the router-posture section with the delegate-reconnaissance/never-delegate-writes rule and child model-sizing guidance; the workspace copy governor/worker-prompt.md carries the identical section; the existing subagent-cannot-write-the-report constraint is preserved and explicitly reconciled with the new delegation guidance (they must not read as contradictory).

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component W1

---

## #16 — Add a per-attempt token budget kill switch for workers (only wall-clock exists today)

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/spawn-worker.sh (hub) + scripts/govern/spawn-worker.sh (workspace); knob documented alongside GOVERN_WORKER_TIMEOUT

Observed: the only ceiling on a worker is `GOVERN_WORKER_TIMEOUT` (default 3600s wall clock, spawn-worker.sh ~line 321). There is NO token ceiling. A worker that wanders can burn 22M+ tokens before the wall clock stops it (governor/ticket-history.jsonl: tickets #3 and #6 each ~22M tokens / ~$9.7). This is also the missing safety rail that would make cheap-tier-first sizing safe: without a bounded probe, a haiku attempt that is out of its depth costs a full session before anyone finds out.

Fix direction: add `GOVERN_WORKER_MAX_TOKENS` (suggest a conservative default, and 0 = unlimited to preserve current behavior for anyone who wants it). The worker is launched at spawn-worker.sh ~line 406 as `claude -p ... ` with output teed to a per-run JSONL; that JSONL carries cumulative usage. Monitor it (same supervision loop that already enforces the wall-clock timeout and kills the process tree) and terminate the attempt when cumulative tokens exceed the budget. Record the termination reason distinctly from a wall-clock timeout — `budget-exceeded` must be a distinguishable outcome, because ticket #(S3, evidence-based escalation) needs to tell "ran out of budget while still exploring" apart from other failures in order to escalate the right axis.

Done when: GOVERN_WORKER_MAX_TOKENS is honored and documented; exceeding it kills the worker process tree exactly like the existing timeout path; the outcome is recorded with a distinct `budget-exceeded` reason in the worker report and state.jsonl; default preserves existing behavior for anyone who does not set it; `bash -n` passes; hub and workspace copies stay in sync.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component W2

---

## #17 — Worker prompt hygiene: move {{TICKET_BLOCK}} last, drop duplicate CLAUDE.md read, dedupe repeated rules

**Severity:** Low
**Model:** haiku

Where: shiploop/templates/governor/worker-prompt.md + governor/worker-prompt.md (keep in sync); prompt assembly at shiploop/templates/govern/spawn-worker.sh:92-99 and scripts/govern/spawn-worker.sh:92-99

Observed: three small, independent inefficiencies in the worker prompt.
(1) `{{TICKET_BLOCK}}` sits at LINE 6 of the 197-line worker-prompt.md, and spawn-worker.sh:94 substitutes the ticket text into that position. Prompt caching works on prefixes, so putting the one per-ticket-varying string at the very top means ~4,800 of the ~5,000 boilerplate words sit downstream of it and can never form a shared cached prefix across tickets. NOTE: the realistic saving is small (within a session the boilerplate is cached after turn one regardless) — this is a correctness/tidiness fix, not a major lever. Do not over-claim it in the PR.
(2) The root CLAUDE.md is ALREADY auto-loaded into the worker's context (the worker's cwd is a worktree of the meta-repo root, so CLAUDE.md is standard project memory), yet worker-prompt.md:9 additionally instructs the worker to `Read` the root CLAUDE.md — a second, tool-call-billed read of content already present.
(3) Duplicated instructions: "validate locally before a PR" appears in both worker-prompt.md:12 and governor/preferences.md:16, and both are concatenated into the same prompt (spawn-worker.sh:96-99). The `ticket-<N>` branch-naming rule is restated at worker-prompt.md:16,19,87,112,163 plus preferences.md:40.

Fix direction: (1) move the `{{TICKET_BLOCK}}` placeholder to the END of worker-prompt.md so the stable boilerplate forms a cacheable prefix — verify the prompt still reads coherently (the ticket is now context at the bottom, so any earlier prose that says "the ticket above" must be reworded). (2) Change worker-prompt.md:9 to instruct reading only the relevant SUB-REPO CLAUDE.md, noting the root one is already loaded. (3) Collapse the duplicated validate-locally and branch-naming statements to one authoritative mention each.

Done when: {{TICKET_BLOCK}} is the last section of worker-prompt.md and the surrounding prose reads correctly with the ticket at the bottom; the redundant root-CLAUDE.md read instruction is gone; validate-locally and the branch rule each appear once; spawn-worker.sh substitution still produces a well-formed prompt (verify with `bash scripts/govern/spawn-worker.sh --dry-run` or equivalent); hub and workspace copies stay in sync.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component W3

---

## #18 — Add reasoning effort as a first-class sizing knob (GOVERN_WORKER_EFFORT + ticket Effort: field)

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/spawn-worker.sh + scripts/govern/spawn-worker.sh (model/effort assembly, ~lines 60-80 dry-run block and ~285-315 live block); shiploop/templates/govern/file-ticket.sh + scripts/govern/file-ticket.sh (flag parsing, ~lines 36-66); queue/tickets.md + shiploop/templates/seed/tickets.md ("Optional per-ticket fields" section, ~lines 22-31)

Observed: model tier and reasoning effort are INDEPENDENT controls, but shiploop only ever sets the model (`--model "$model"` at spawn-worker.sh:410). Every worker therefore runs at the session-default effort, and there is no rung on the ladder between "sonnet" and "opus at ~3.5x the price on the dominant cacheRead line". Raising effort is far cheaper than raising tier, so the correct escalation ladder raises effort BEFORE tier — impossible today because the knob does not exist.

Fix direction:
(1) Add `GOVERN_WORKER_EFFORT` (values: low|medium|high|xhigh|max; default preserves today's behavior when unset — i.e. pass no effort flag at all rather than inventing a default).
(2) Add an `**Effort:**` optional per-ticket field, parsed exactly like the existing `**Model:**` field (case-insensitive, markdown-emphasis-tolerant, anchored to the ticket's leading field block — mirror the existing extraction at spawn-worker.sh:38-41). Unknown values are dropped with a warning, fail-safe, same as Model:.
(3) Add `--effort <tier>` to file-ticket.sh alongside the existing `--model`/`--flow`/`--flow-op` flags.
(4) Document `Effort:` in the "Optional per-ticket fields" block of BOTH queue/tickets.md and shiploop/templates/seed/tickets.md, next to the existing Model: entry.
(5) Log the resolved effort in the same log line that already reports the resolved model and its source.

IMPORTANT: verify how the installed `claude` CLI actually accepts a reasoning-effort argument before wiring it (check `claude --help`). If the CLI exposes no such flag in this environment, implement the field + plumbing but make the spawn a no-op pass-through and say so explicitly in the PR description rather than inventing a flag that does not exist.

Done when: GOVERN_WORKER_EFFORT and a ticket `Effort:` field both resolve and are logged with their source; `--effort` files a ticket carrying the field; both tickets.md files document it; unknown values fail safe; default behavior is unchanged when nothing is set; `bash -n` passes; hub and workspace copies stay in sync.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S1

---

## #19 — Log the sizing DECISION (model/effort/attempt) alongside the cost already recorded, and fix null capture

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/govern-bookkeep.sh + scripts/govern/govern-bookkeep.sh (the writer of governor/ticket-history.jsonl rows); govern-health.sh consumers (~lines 113-148) must keep working

Observed: governor/ticket-history.jsonl already records `tokens` and `costUsd` per ticket, and govern-health.sh already aggregates them (totals, averages, self-referential vs product split). But the rows record the COST and not the DECISION — there is no `model`, no `effort`, no attempt number. Sample rows:
  {"ticket":6,"status":"resolved","tokens":{...,"total":22930331},"costUsd":9.65,...}
You can see ticket #6 cost $9.66 but NOT what tier produced that. That makes the data unlearnable: the question "does this class of ticket actually succeed at sonnet?" has no answer, so any scope->tier sizing table must stay hand-tuned forever.

Second defect: `costUsd` and `tokens` are NULL on 2 of the 6 existing rows — including BOTH of ticket #5's failed attempts. Failures are precisely the rows a sizing loop most needs (they are what proves a tier was too cheap), so the capture gap is biased in the worst possible direction.

Fix direction: (1) add `model`, `effort`, and `attempt` (1-based) to each ticket-history row, sourced from the same values spawn-worker.sh already resolves and logs. (2) Diagnose and fix the null-capture path so failed/parked attempts record usage too — determine why the resolved rows captured usage and the failed ones did not, and close that gap rather than defaulting the field. (3) Keep govern-health.sh's existing jq consumers working (they use `select(.tokens != null)` so extra fields are safe, but re-run it to confirm). (4) Optionally surface a per-model breakdown in govern-health.sh output.

Done when: new ticket-history rows carry model/effort/attempt; a failed attempt records usage rather than null; `bash scripts/govern/govern-health.sh` still runs and reports; existing historical rows (which lack the new fields) do not break any consumer; `bash -n` passes; hub and workspace copies stay in sync.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S5

---
