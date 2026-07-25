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

## #19 — Log the sizing DECISION (model/effort/attempt) alongside the cost already recorded, and fix null capture

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/govern-bookkeep.sh + scripts/govern/govern-bookkeep.sh (the writer of governor/ticket-history.jsonl rows); govern-health.sh consumers (~lines 113-148) must keep working

Observed: governor/ticket-history.jsonl already records `tokens` and `costUsd` per ticket, and govern-health.sh already aggregates them (totals, averages, self-referential vs product split). But the rows record the COST and not the DECISION — there is no `model`, no `effort`, no attempt number. Sample rows:
  {"ticket":6,"status":"resolved","tokens":{...,"total":22930331},"costUsd":9.65,...}
You can see ticket #6 cost $9.66 but NOT what tier produced that. That makes the data unlearnable: the question "does this class of ticket actually succeed at sonnet?" has no answer, so any scope->tier sizing table must stay hand-tuned forever.

Second defect: `costUsd` and `tokens` are NULL on 2 of the 6 existing rows — including BOTH of ticket #5's failed attempts. Failures are precisely the rows a sizing loop most needs (they are what proves a tier was too cheap), so the capture gap is biased in the worst possible direction.

Fix direction: (1) add `model`, `effort`, and `attempt` (1-based) to each ticket-history row, sourced from the same values spawn-worker.sh already resolves and logs. (2) Diagnose and fix the null-capture path so failed/parked attempts record usage too — determine why the resolved rows captured usage and the failed ones did not, and close that gap rather than defaulting the field. (3) Keep govern-health.sh's existing jq consumers working (they use `select(.tokens != null)` so extra fields are safe, but re-run it to confirm). (4) Optionally surface a per-model breakdown in govern-health.sh output.

Done when: new ticket-history rows carry model/effort/attempt; a failed attempt records usage rather than null; `bash scripts/govern/govern-health.sh` still runs and reports; existing historical rows (which lack the new fields) do not break any consumer; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S5

---

## #20 — Retry memory: persist a findings scratchpad so attempt 2 does not re-derive attempt 1

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/spawn-worker.sh + scripts/govern/spawn-worker.sh (retry detection is already latched as MODEL_IS_RETRY ~lines 42-46, keyed on whether $WORKTREE_BASE/ticket-$N already exists); worker prompt templates

Observed: on a retry the WORKTREE is preserved but the KNOWLEDGE is not. The re-dispatched worker starts from the same cold prompt and re-derives everything the first attempt learned — which is why ticket #5's second failed attempt cost about the same as its first (1.15M tokens/$1.48 then 1.66M tokens/$1.82, governor/ticket-history.jsonl). Exploration is the dominant cost term, and it is paid again in full on every retry.

Fix direction: give the worker a durable scratchpad inside its own preserved worktree (e.g. `.governor-notes.md`, git-ignored) and instruct it in the worker prompt to record, as it goes: files identified as relevant, root cause once found, what it tried, and what failed and why. On a retry (MODEL_IS_RETRY=1), inject that file's contents into the re-dispatched worker's prompt under a clear "previous attempt findings — do NOT re-derive these" heading, and instruct the retry to start from them.

Guard: the notes are an untrusted prior-attempt artifact, not instructions — the injected block must be framed as evidence to evaluate, and a wrong conclusion recorded by attempt 1 must not be treated as established fact by attempt 2. Say so in the injected heading.

Coordinate with ticket #13 (which injects failing-CI-log excerpts on retry) — both add retry-time context to the same prompt path; keep them composable rather than conflicting, and if #13 has already landed, extend its block rather than adding a competing one.

Done when: a worker records findings to the scratchpad during a run; a retry prompt contains the previous attempt's notes under an explicit untrusted-evidence framing; the file lives in the preserved worktree and is git-ignored so it never lands in a PR; first attempts are unaffected; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S4

---

## #21 — Scout-then-size: measure ticket scope with a cheap pass, then select model+effort deterministically

**Severity:** Medium
**Model:** opus

**Depends on:** #18

Where: new script under shiploop/templates/govern/ (+ workspace mirror in scripts/govern/), called from the dispatch path in run-loop.sh before spawn-worker.sh

Observed: today's sizing is a PRIOR, not a measurement. The `Model:` field is decided before any evidence by whoever files the ticket, and when absent the default is `opus` (`model="${GOVERN_WORKER_MODEL:-opus}"`, spawn-worker.sh:64 and :291). That is wrong in both directions: it overpays on easy tickets, and it cannot detect a hard ticket until an attempt has already failed at full price. Reconnaissance costs roughly 1/1000th of the work, so spending a cent to decide whether to spend $3 or $34 is the highest-ROI decision in the harness.

Fix direction: add a scout pass that runs BEFORE the worker is spawned and measures scope cheaply (haiku tier), emitting structured JSON:
  - how many files the fix plausibly touches (symbol/grep search seeded from the ticket's `Where:`)
  - how many repos are involved
  - whether tests already cover the touched area
  - whether git history contains a precedent commit for the same file/area (a precedent means easy)
  - local edit (function body) vs structural change (signature / schema / API contract)
  - whether the ticket's fix direction is concrete or vague

Then select (model, effort) with a DETERMINISTIC bash scoring function over that JSON — auditable and tunable, NOT a second LLM judgement call:
  | measured scope                                            | model  | effort |
  | 1 file, local, precedent + test exist                     | haiku  | low    |
  | <=5 files, 1 repo, concrete fix direction                 | sonnet | medium |
  | cross-repo, or contract/schema change, or no test, or vague| opus  | high   |

Precedence: an explicit ticket `Model:`/`Effort:` field always WINS over the scout (the human/brain override must remain authoritative). The scout only decides when the fields are absent — replacing the blanket `opus` default, not the operator.

Cache the scout's verdict onto the run so a retry does not re-scout from scratch, and record it so ticket #(S5) can log which scope class produced which outcome.

Guard: scout output is untrusted model output feeding a dispatch decision — validate the JSON shape and clamp to known enum values; on any parse failure or timeout, fall back to today's behavior (GOVERN_WORKER_MODEL) and log the fallback loudly. Never let a malformed scout silently downgrade a hard ticket to haiku.

Done when: the scout runs pre-dispatch and emits validated JSON; the scoring function selects model+effort deterministically from it and is unit-testable in isolation (add a test under templates/govern/test/); an explicit ticket Model:/Effort: overrides the scout; malformed/absent scout output falls back safely and loudly; the chosen tier and the scope class are logged; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S2

---

## #22 — Evidence-based retry escalation: classify the failure signature instead of always jumping to opus

**Severity:** Medium
**Model:** opus

**Depends on:** #16

Where: shiploop/templates/govern/spawn-worker.sh + scripts/govern/spawn-worker.sh (the retry-escalation block at ~lines 291-313); retry dispatch in run-loop.sh

Observed: every retry unconditionally escalates to `GOVERN_WORKER_MODEL` (default opus) and DISCARDS the ticket's `Model:` field — spawn-worker.sh:299-313, on the stated reasoning that "a cheap-tier bet that didn't land the first time shouldn't be re-bet". That reasoning does not hold for the most common real failure class in this workspace: ticket #13 documents that ticket #5 burned BOTH governor attempts on a Linux-vs-macOS PORTABILITY failure (BSD `stat -f` vs GNU `stat`), where the model tier was never the problem. Re-betting that at opus is pure waste — measured at $3.30 across #5's two failed attempts.

Fix direction: classify the failure signature and escalate the axis that actually failed:
  | failure signature                              | correct response                                   |
  | CI failed on portability/env (see #13)         | SAME tier; inject the CI log; retry                |
  | hit the token budget while still exploring     | scope was underestimated -> raise tier             |
  | produced a coherent but wrong fix              | judgment failure -> raise tier AND effort          |
  | gh/network/infra error                         | retry identical; do NOT escalate at all            |

Depends on the `budget-exceeded` outcome introduced by the token-budget ticket, which is what distinguishes "ran out of room while exploring" from other failures. Coordinate with ticket #13 (CI-log injection on retry) and ticket #10 (GOVERN_FIX_CI is set by run-loop.sh:275 but never read by spawn-worker.sh, so the CI-fix worker currently gets a plain first-attempt prompt) — this ticket owns the ESCALATION POLICY; #13 and #10 own the CI-context injection. Do not duplicate their work; if they have not landed, keep the classifier's CI branch simple and leave a clear seam.

Escalation must also raise EFFORT before TIER where the classifier indicates judgment was marginal rather than absent, once the effort knob exists.

Safety: this touches a governor retry rail. Preserve the existing invariant that a retry never silently DOWN-grades below the tier its first attempt used unless the classifier positively identifies an infra/portability cause. Keep the current behavior as the fallback whenever the signature is unrecognized — an unknown failure escalates exactly as it does today.

Done when: the classifier categorizes a failed attempt from its recorded outcome + logs; each category maps to the documented response; an unrecognized signature falls back to today's escalate-to-GOVERN_WORKER_MODEL behavior; the decision and its reason are logged; a test under templates/govern/test/ covers each branch; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component S3

---

## #23 — Locality batching: group tickets by predicted file scope so one worker fixes a whole group

**Severity:** Medium
**Model:** opus

**Depends on:** #14

Where: new grouping step in shiploop/templates/govern/run-loop.sh (+ workspace mirror) between ticket selection and the --parallel fan-out; likely a helper in templates/govern/lib/common.sh

Observed: exploration is the dominant cost term (a resolved ticket is ~22M tokens, 98% cacheRead — governor/ticket-history.jsonl). Three tickets that all touch `scripts/govern/` currently mean THREE workers each paying full discovery cost on the same code: three repo loads, three CLAUDE.md reads, three architecture explorations. One worker fixing all three pays that once. On the dominant term this approaches a 3x saving for that group.

This also makes parallelism SAFER, not just cheaper: today N concurrent workers are selected purely by severity order with no regard for whether they touch the same files, so two workers can race on the same file and produce conflicting branches. Grouping by locality means the fan-out runs over DISJOINT groups by construction.

Fix direction: before fanning out, partition the eligible ticket set into locality groups using the tickets' `Where:` fields (and, if ticket #(S2, the scout) has landed, its measured file list — prefer that signal when available since `Where:` is prose). Dispatch ONE worker per group with all of that group's ticket blocks in its prompt, and have it produce one branch/PR per group. `--parallel=N` then means N GROUPS, not N tickets.

Batching and parallelism pull against each other — past a point, bigger groups reduce wall-clock gains. Expose the aggressiveness as an explicit knob (e.g. GOVERN_BATCH_MAX, max tickets per group, with 1 = today's behavior of one ticket per worker) rather than hard-coding a policy. Default should be conservative.

Hard constraints: (a) the existing per-ticket claim lock and bookkeep lock semantics must still hold — a group claims all its tickets or none; (b) the `**Depends on:**` gate (govern::ticket_deps, lib/common.sh:1270) must still be enforced, and two tickets in a dependency relationship must NOT be silently co-batched in a way that violates ordering — either co-batch them in dependency order within the single worker, or keep them in separate groups; (c) a group that partially fails must report per-ticket outcomes, not collapse to one verdict, or bookkeeping will mark unfixed tickets resolved.

Done when: eligible tickets are partitioned into disjoint locality groups; one worker handles a group and reports per-ticket outcomes; GOVERN_BATCH_MAX controls group size with 1 preserving today's behavior; dependency-related tickets are never co-batched out of order; claim/bookkeep locking is preserved for every ticket in a group; a test under templates/govern/test/ covers the partitioning and the per-ticket outcome mapping; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component C2

---

## #24 — Deterministic pre-gate: skip spawning an agent for codemod-able or already-fixed-upstream tickets

**Severity:** Low
**Model:** sonnet

Where: new pre-dispatch check in shiploop/templates/govern/run-loop.sh (+ workspace mirror), before the worker is spawned

Observed: every ticket gets a full agent session regardless of whether it needs one. Two classes of ticket can be resolved or eliminated with ZERO LLM tokens:
(1) Mechanical/codemod tickets — version bumps, config stamps, lint fixes, mechanical renames.
(2) Already-fixed-upstream tickets — the workspace<->hub drift anti-pattern documented at the top of root CLAUDE.md: a ticket whose `Where:` names a root `scripts/govern/*` mechanism script may ALREADY be fixed in `shiploop/templates/`, because this workspace dogfoods shiploop as its own sub-repo and another fleet may have ported the identical fix upstream. The anti-pattern instructs a human to diff the workspace copy against the hub template before authoring a fresh fix, but NOTHING enforces it — so a worker can spend a full session (~$10) rediscovering a fix that already exists.

Fix direction: add a cheap deterministic pre-dispatch check.
(a) Upstream-drift check: when a ticket's `Where:` names a path that exists in BOTH scripts/govern/ (or scripts/worktree/) and shiploop/templates/, diff the two. If the hub is ahead on that file, do not spawn a fresh-fix worker — surface it to the operator as "port the hub diff down instead" (an escalation or a distinct ticket note), which is exactly what root CLAUDE.md already prescribes.
(b) Codemod detection: keep this NARROW and conservative — a false positive that "resolves" a ticket without fixing it is far worse than a missed opportunity. Prefer flagging a ticket as codemod-able for operator confirmation over auto-applying anything. Do NOT build a general auto-fix engine.

Scope note: (a) has the clear ROI and a concrete, already-documented rule behind it. If (b) cannot be made safe and narrow, implement (a) alone and explicitly decline (b) in the PR description — that is an acceptable outcome for this ticket.

Done when: a ticket whose target file is behind its hub template is detected pre-dispatch and surfaced rather than worked from scratch; the check is deterministic (no LLM call); it cannot mark a ticket resolved on its own; false-positive behavior is fail-open (when unsure, spawn the worker as today); `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component C3

---

## #25 — Persistent repo map: cache an architecture digest per repo so every ticket stops re-exploring

**Severity:** Low
**Model:** sonnet

Where: new generator script under shiploop/templates/govern/ (+ workspace mirror); digest injected via the worker prompt assembly in spawn-worker.sh:92-99

Observed: exploration is the dominant cost term and it is paid fresh on every ticket. Twenty tickets against the same repo currently pay twenty identical discoveries of the same directory layout, entry points, and conventions. Nothing is cached between workers.

Fix direction: generate a compact per-repo architecture digest (cheap tier — this is exactly a haiku job): top-level layout, entry points, where tests live, build/test commands, key modules and their responsibilities. Persist it (e.g. under governor/ or .claude/shiploop/) keyed per repo, and inject it into the worker prompt.

Freshness: stamp the digest with the repo HEAD it was generated from and regenerate when the repo has drifted materially since (or on an explicit refresh command). A STALE map is worse than no map — it sends workers to files that moved. Prefer conservative regeneration and mark the digest with its generation commit so a worker can tell how fresh it is.

Size discipline: this content is injected into every worker prompt, so it is a standing per-ticket cost. Keep it tight (a page, not a dump) — the point is to replace exploration, not to relocate it into the prompt. If the digest cannot be kept small, it is not worth injecting; say so rather than shipping a bloated one.

Done when: a digest can be generated per repo and is stamped with its source commit; it is injected into the worker prompt; a stale digest is detected and regenerated or flagged; the digest is size-bounded; generation uses a cheap tier; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component T1

---

## #26 — Precedent injection: hand the worker the analogous prior commit for its target area

**Severity:** Low
**Model:** sonnet

Where: worker prompt assembly in shiploop/templates/govern/spawn-worker.sh:92-99 (+ workspace mirror); helper likely in templates/govern/lib/common.sh

Observed: git history is a free, entirely unused corpus. When a ticket targets a file or area that has been changed before in a similar way, the worker still explores from scratch instead of pattern-matching against how it was done last time. Converting open-ended exploration into "here is the analogous change, follow its shape" attacks the dominant cost term (turns per session).

Fix direction: for the ticket's `Where:` paths, find the most relevant prior commit(s) — e.g. `git log --oneline -n <k> -- <path>` plus the diff for the best match — and inject a bounded excerpt into the worker prompt under a clear "precedent — how a similar change was made here before" heading. Deterministic selection (recency + path overlap) is fine and preferable to an LLM ranking pass; this must stay cheap or it defeats its own purpose.

Bounds: cap the injected diff size hard (a large diff costs more than the exploration it saves). If no good precedent exists, inject nothing — an irrelevant precedent is worse than none because it anchors the worker on the wrong pattern. Frame the block as evidence to consider, not as a template to copy blindly: the precedent may itself have been superseded.

Done when: a relevant prior commit is located deterministically for a ticket's target paths and injected as a size-bounded excerpt; no precedent found means no block injected; the block is framed as non-authoritative evidence; injection is skippable via a knob; `bash -n` passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency review; .plans/2026-07-25-shiploop-token-efficiency.md component T2

---

## #28 — --dry-run leaves a real ticket claim lock behind, blocking the next live run

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/run-loop.sh (+ scripts/govern/run-loop.sh) — the ticket claim-lock acquisition path, and whatever releases it on exit

Observed: `bash scripts/govern/run-loop.sh 14 --dry-run` acquired a REAL per-ticket claim lock at governor/.locks/ticket-14 (holder file containing its pid) and never released it on exit. The subsequent LIVE run for the same ticket then aborted with "#14 already claimed by another driver — skipping" and did no work — even though the dry-run process (pid 63313) had already exited. Confirmed by inspection: governor/.locks/ticket-14/holder contained 63313, and `ps -p 63313` showed the process dead, while a genuinely-live sibling worker's lock (ticket-15, holder 66563) was correctly held by a running process.

Two distinct defects:
(1) A `--dry-run` must be side-effect-free. It reports what it WOULD do (the log line is literally "[dry] would ..."), so it must not take a real claim lock that outlives it. Either skip claim acquisition entirely in dry mode, or acquire-and-release before exit.
(2) The stale-lock reclaim did not fire for a lock whose holder pid is provably dead. run-loop.sh advertises a "stale-reclaimed" concurrency mode, but here a dead holder still blocked a fresh run, forcing a manual `rm -rf governor/.locks/ticket-14`. A dead-pid holder should be reclaimed automatically — note the operator is explicitly warned NOT to delete locks by hand (#183), so the automatic path has to work or that warning traps them.

Fix direction: (a) in dry mode, do not acquire the per-ticket claim lock (or release it before exit, including on early exit paths — use a trap). (b) In the claim path, when the lock exists, check whether the holder pid is still alive; if it is dead, reclaim it and log "stale-reclaimed" rather than skipping the ticket. Preserve the #183 safety property: NEVER reclaim a lock whose holder is alive.

Done when: `run-loop.sh <N> --dry-run` leaves no governor/.locks/ticket-<N> behind (verify with ls after a dry run); a lock whose holder pid is dead is automatically reclaimed by the next run with a clear log line; a lock whose holder is ALIVE is still respected and still skips; a test under templates/govern/test/ covers dead-holder reclaim and live-holder respect; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 — hit while dry-running ticket #14 before launching the token-efficiency fan-out; cost one no-op govern run and a manual lock removal.

---

## #29 — govern::ticket_deps harvests ticket numbers from PROSE, creating false dependencies

**Severity:** Medium
**Model:** sonnet

Where: scripts/govern/lib/common.sh (govern::ticket_deps, ~line 1270) + shiploop/templates/govern/lib/common.sh; gate consumer run-loop.sh:684

Observed: while filing the token-efficiency ticket set, `govern::ticket_deps 22` returned `16 13 10` when ticket #22 declares only `**Depends on:** #16`. The extra numbers came from PROSE in the body: "Coordinate with ticket #13 (CI-log injection on retry) and ticket #10 (...)". The likely mechanism is that the body ALSO contains the sentence "Depends on the `budget-exceeded` outcome introduced by the token-budget ticket" — a prose sentence beginning with the literal phrase "Depends on" — which the scan appears to treat as a dependency declaration and then harvest nearby `#N` references from.

Impact: a ticket that merely MENTIONS other tickets can become hard-gated on them by the #119 pre-spawn gate (run-loop.sh:684). That silently defers work, and in the worst case two tickets that reference each other in prose could deadlock. This is the INVERSE of the defect tickets #9/#11 already cover (they add a lint for prose deps that were never DECLARED); this one is undeclared prose becoming a REAL dependency. Both should be considered together — the parser is too loose in one direction and unenforced in the other.

Note: in this instance the over-gating was benign/conservative (#22 genuinely does coordinate with #13 and #10, so waiting is safe) and was deliberately left in place. The defect is that it happened by accident rather than by declaration.

Fix direction: anchor the `Depends on:` scan strictly — require the marker at the START of a line (optionally bold-wrapped) and harvest `#N` only from THAT line, not from following prose. Confirm the exact current matching behavior first (this was observed, not root-caused, during a bookkeeping pass). Add a test under templates/govern/test/ with a ticket whose body contains both a real `**Depends on:** #K` line and unrelated prose `#N` mentions, asserting only #K is returned.

Done when: prose `#N` mentions never become dependencies; a properly declared `**Depends on:**` line still parses (including multiple comma-separated numbers); the `**Blocks:**` implicit-blocker path is unaffected; a regression test covers prose-vs-declaration; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 token-efficiency filing — observed on ticket #22 (deps resolved to 16 13 10 against a single declared #16).

---

## #30 — Tickets #9 and #11 duplicate each other — same Depends-on work proposed twice

**Severity:** Low
**Model:** haiku

Where: queue/tickets.md — open tickets #9 and #11

Observed: #9 and #11 were both auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) after two different govern runs (run-20260711-033250 and run-20260711-033248), and they propose substantially the SAME work:
  - both propose documenting `**Depends on:** #K` as a first-class optional per-ticket field in queue/tickets.md
  - both propose adding a `--depends-on N[,M...]` flag to scripts/govern/file-ticket.sh
  - both propose a lint pass flagging prose dependency language with no declared `Depends on:` line
#11 additionally carries two proposals #9 does not (a supervisor `orderingRisks` schema field, and having the dependency gate confirm the dependency's PR actually MERGED rather than just that the ticket entry was deleted).

Impact: two workers can be dispatched to implement the same three changes, wasting a full session each and producing conflicting PRs on the same files (queue/tickets.md, file-ticket.sh, lint-tickets.sh). This becomes materially more likely now that the governor runs tickets in parallel by default.

Root cause worth noting: the auto-triage promoter appears to have no dedup against ALREADY-OPEN promoted tickets, so the same recurring proposal gets re-promoted on each run that surfaces it. That de-dup gap may deserve its own fix beyond merging these two entries.

Fix direction: merge #9 and #11 into a single ticket that carries the union of their proposals (keeping #11's two extra items), and delete the other. Then consider whether govern-improve-triage.sh should dedup a proposal against open tickets before promoting it.

Done when: only one open ticket covers the Depends-on documentation + `--depends-on` flag + dependency lint work, with #11's two additional proposals preserved; the redundant entry is deleted with a commit message naming the merge; a decision is recorded (ticket or CLAUDE.md note) on whether triage-time dedup is worth adding.

Ref: session 2026-07-25 — spotted while deduping the token-efficiency ticket set against the existing queue.

---

## #31 — Nothing verifies a ticket's 'Done when' criteria before bookkeeping marks it resolved and deletes it

**Severity:** Medium
**Model:** sonnet

Where: scripts/govern/govern-bookkeep.sh + shiploop/templates/govern/govern-bookkeep.sh (the resolve/delete path); worker report schema in spawn-worker.sh / governor/worker-prompt.md

Observed: "resolved" is currently defined operationally as "the worker opened a PR and CI went green", with NO check that the ticket's own stated acceptance criteria were met. The `Done when:` field is written for a human/LLM reader and is never machine-verified, nor even re-presented for confirmation, before the ticket is DELETED from queue/tickets.md. Once deleted, an unmet criterion can never resurface — the ticket is gone.

CORRECTION on this ticket's original filing: it was first filed citing #15 and #27 as confirmed instances, on the grounds that each updated only the hub template `shiploop/templates/**` and not the workspace copy. That was a MIS-DIAGNOSIS by the filer. Harness work in this workspace is hub-first by design: the workspace copy is refreshed through the `/shiploop:update` channel, NOT hand-edited in the same PR. Both workers followed the documented convention correctly; the offending "hub and workspace copies stay in sync" clause in those tickets' Done-when was itself mis-specified (it has since been corrected across the #14-#31 set). So this ticket currently has NO confirmed instance of a worker falsely asserting completion.

It is filed anyway because the structural gap is real and independent of that bad example: nothing anywhere compares the delivered diff against the ticket's stated criteria before the ticket is destroyed. Severity is Medium rather than High precisely because the motivating evidence did not survive scrutiny — treat "does this actually happen?" as the first question to answer, and if a survey of recent resolutions finds no real instance, DECLINE this ticket in the PR description rather than building machinery for a hypothetical.

Note the second-order lesson worth capturing either way: a mis-specified `Done when` clause is indistinguishable, from the outside, from a worker that ignored a correct one. Whatever is built here should make that distinction visible rather than assuming the ticket text is always right.

Fix direction: require the worker's structured report to include an explicit per-criterion self-assessment against the ticket's `Done when:` clauses (each clause: met / not-met / not-applicable, with a one-line evidence pointer), and have bookkeeping REFUSE to delete a ticket that reports any clause not-met — parking it with an escalation instead. This deliberately does not attempt to machine-parse arbitrary prose criteria; it makes the worker assert compliance clause-by-clause and makes a false assertion an auditable lie in the report rather than a silent omission.

Consider additionally: a cheap independent verifier pass (haiku) that re-reads the ticket's Done-when against the actual diff before the resolve is committed. Weigh cost against value — the whole point of this work set is to REDUCE spend, so a verifier must be cheap and must not run on every ticket if a self-assessment suffices.

Done when: EITHER this ticket is declined in its PR description with evidence that no real instance of a falsely-asserted completion exists in the recent resolution history — an acceptable and expected outcome — OR: a worker report carries a per-clause Done-when self-assessment; bookkeeping refuses to delete a ticket with any not-met clause and parks it with an escalation naming the clause; the refusal path is covered by a test under templates/govern/test/; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 — caught while verifying shiploop#82; workspace copy lacked the section the ticket required, yet the ticket was resolved and deleted.

---

## #32 — govern-health.sh has no budget-exceeded bucket in its status breakdown

**Severity:** Low

Where: scripts/govern/govern-health.sh (workspace) + templates/govern/govern-health.sh (hub), ~line 125 (the jq status-bucket object) and ~line 198 (the human-readable summary).
Observed: ticket #16 added a `budget-exceeded` outcome status (distinct from `timeout`) to state.jsonl / ticket-history.jsonl, and wired it into run-loop.sh's own DONE summary + streak logic, but govern-health.sh's ROI dashboard only buckets `timeout` (and `failed`) — a budget-exceeded ticket is simply omitted from that specific breakdown (not miscounted, just invisible there).
Fix direction: add a `budget-exceeded` bucket alongside the existing `timeout` bucket in the jq status-count object and the human-readable summary line, mirroring how `timeout` is already surfaced.
Done when: govern-health.sh's status breakdown and human summary both surface a budget-exceeded count; a test under templates/govern/test/ covers it; bash -n passes; hub and workspace copies stay in sync.

---
