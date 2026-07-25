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

CORRECTION to this ticket's original fix direction: it first proposed "in dry mode, do not acquire the per-ticket claim lock". That is WRONG and must NOT be implemented — a dry driver taking the claim lock is DELIBERATE, added by ticket #104 so two concurrent dry drivers faithfully contend without opening real PRs, and it is covered by the regression test `templates/govern/test/test-claim-lock-dry.sh` (asserts both that a held peer claim makes a dry driver skip, and that two concurrent dry drivers claim a ticket exactly once). Removing dry-mode acquisition would regress #104 and fail that test. The premise "a dry run must be side-effect-free" is satisfied by acquire-AND-RELEASE, not by never acquiring — the lock is a pure mkdir/rmdir.

Fix direction: the actual defect is that the lock is never RELEASED. (a) Ensure the per-ticket claim lock is released on EVERY exit path in dry mode — including early exits and signals — via a trap. Keep acquiring it (per #104). (b) In the claim path, when the lock exists, check whether the holder pid is still alive; if it is dead, reclaim it and log "stale-reclaimed" rather than skipping the ticket. Preserve the #183 safety property: NEVER reclaim a lock whose holder is alive. (c) `test-claim-lock-dry.sh` must still pass unchanged — treat it as the guard against re-introducing the wrong fix.

Done when: `run-loop.sh <N> --dry-run` leaves no governor/.locks/ticket-<N> behind (verify with ls after a dry run); a lock whose holder pid is dead is automatically reclaimed by the next run with a clear log line; a lock whose holder is ALIVE is still respected and still skips; a test under templates/govern/test/ covers dead-holder reclaim and live-holder respect; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 — hit while dry-running ticket #14 before launching the token-efficiency fan-out; cost one no-op govern run and a manual lock removal.

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

## #35 — Workspace govern lib + test dir lag the hub — /shiploop:update bump is due

**Severity:** Medium

Where: scripts/govern/lib/common.sh, scripts/govern/*.sh, scripts/govern/test/ vs shiploop/templates/govern/**.

Observed: found while porting run-loop.sh down. The workspace is behind the hub on more than the one file this ticket covered: (1) scripts/govern/lib/common.sh lacks the hub's implicit-dependency support — `govern::ticket_deps` does not honor a blocker's `**Blocks:** #N, #M` line, so the hub's own test-pending-waits.sh section for it fails against the workspace lib (confirmed empirically: copying the hub test over made 2 assertions fail on the workspace copy, and they pass in the template tree); (2) the workspace is missing hub mechanism scripts govern-validations.sh, run-validation.sh, validations-pending-apply.sh — run-loop.sh's durable-validation adoption block is guarded on `-f` so it is a silent no-op here; (3) the workspace test dir is missing ~9 hub tests (test-valjob, test-valpending-emit, test-valpending-apply-race, test-govern-validations-listing, test-file-ticket-dup-flag, test-lint-prose-deps, test-escalation-body-ref, test-bookkeep-overlap-autostash-pop, test-flows-stamp-terminal).

This is the workspace<-hub drift anti-pattern at the top of root CLAUDE.md, one level up from a single file: the whole harness needs a component bump, not a hand-port per ticket. Blind-copying individual hub files is NOT safe (a hub test can exercise a hub-only lib feature and fail) — the components must move together.

Fix direction: run /shiploop:update (scaffold.sh --component per component) to bump govern lib + mechanism scripts + tests together, then run the full suite. Do NOT hand-port file-by-file. Note scripts/lib/workspace.sh is preserved by design and must keep this fleet's GOVERN_PARALLEL_DEFAULT=4.

Done when: `diff -r scripts/govern shiploop/templates/govern` shows no unexplained drift (workspace-specific files documented); the full govern suite is green in the workspace after the bump; the harness-version stamp matches the hub VERSION.

---

## #36 — Harness self-improvement: promote safe proposals from run-20260725-053951

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260725-053951. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `queue/tickets.md` + `scripts/govern/select-ticket.sh`: add a `**Blocks:** #N[, #M...]` optional field, parsed the same tolerant way `select-ticket.sh` already parses `**Severity:**`, and have it feed the exclusion set the same way `## Open` escalations already do — why: nothing today stops #9 or #11 from being independently selected even though #30 already says they duplicate each other and should be merged first. The 05:53 proposals prevent *future* duplicate pairs; they don't give the *existing* #30 any teeth to actually block #9/#11 in the meantime.
- `scripts/govern/run-loop.sh` (~line 754, where a worker's `crossRefs.overlaps`/`crossRefs.dependsOn` is read off its report): write that back as a `Blocks:`/`Depends on:` line on the referenced ticket, or file it as an `## Open` escalation, instead of only setting `anomaly=1` for one supervisor glance — why: a worker has the freshest evidence of a real overlap while doing the work, and today that evidence is discarded after a single pass instead of durably blocking the ticket it names.
- `scripts/govern/lint-tickets.sh` (or `file-ticket.sh` at filing time): WARN (non-blocking) when a ticket's body names a CLI flag/env var (`--foo`, `GOVERN_*`) or "the orchestrator"/"N drivers" that doesn't grep-match anything in this workspace's current `scripts/govern/*.sh` — why: I confirmed directly that `#33`/`#34` describe `GOVERN_PARALLEL_DEFAULT`/`--parallel` orchestrator machinery that exists only in the hub template (`shiploop/templates/govern/run-loop.sh`), not in this workspace's copy (ticket #35 already flags the lag) — dispatching a worker at either ticket today would burn a session on a target that isn't there yet, likely a confused park/fail rather than a clean block.
- `queue/tickets.md`: add `**Depends on:** #35` to #33 and #34's field blocks (a data-only fix, zero script changes) — the existing `govern::ticket_deps` gate already honors literal "depends on #N" prose today, so this alone stops either from being dispatched before #35 (the hub-sync bump) lands.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-25 06:25 — run run-20260725-053951 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #37 — govern test suite fails spuriously when run from inside a live governor session

**Severity:** Medium

Where: shiploop/templates/govern/test/test-spawn-worker-sweep.sh (+ templates/govern/test/assert.sh as the shared fix site).

Observed: a worker validating a hub change locally ran the full suite in a freshly scaffolded throwaway workspace and got passed=106 failed=1 skipped=5 total=112. The single failure was test-spawn-worker-sweep, with 4 assertions failing on 'sweep fires once after a cleanly-resolved worker' etc. Root cause is environmental, not a regression: the governor exports GOVERN_ALLOW_CONCURRENT=1 into every worker's environment, the test inherits it, and spawn-worker.sh then correctly logs 'post-worker orphan sweep SKIPPED — GOVERN_ALLOW_CONCURRENT=1 (time-window sweep is single-run-only) [#239]'. Running the same test with the variable unset does not help — it then blocks indefinitely on the live run's single-run lock. The same suite is green on PR CI (clean env).

Impact: every worker that follows doctrine and validates locally before opening a PR burns cycles diagnosing a phantom failure, and — worse — learns to discount a red test in that file, which would mask a real #239/#3001 regression.

Fix direction: make the test hermetic against inherited harness env. Cleanest is in the shared harness (assert.sh / mk_ws_stub): scrub or neutralize inherited GOVERN_* variables so a test's environment is defined by the test, not by whoever spawned it — with test-spawn-worker-sweep explicitly forcing GOVERN_ALLOW_CONCURRENT=0 and pointing the single-run lock at its own temp dir so it neither skips the sweep nor contends with a live run. Audit the other tests for the same inheritance exposure while there.

Done when: test-spawn-worker-sweep passes both inside a live governor session (GOVERN_ALLOW_CONCURRENT=1 exported) and in a clean env; it never blocks on a real run's single-run lock; no other test in the suite changes behavior based on inherited GOVERN_* env; bash -n passes; hub-first — land in shiploop/templates/** only.

---

## #38 — Rescope the prose-dependency-lint tickets — the lint already ships in the hub, only the --depends-on flag is missing

**Severity:** Low

Where: queue/tickets.md #9 / #11 (and #30, which already notes #9 and #11 duplicate each other) vs. shiploop/templates/govern/lib/common.sh + templates/govern/lint-tickets.sh.

Observed: while fixing the ticket_deps prose-harvesting defect, checked what #9/#11 actually still need. The hub ALREADY implements the core ask: govern::prose_dep_warnings exists in templates/govern/lib/common.sh (flags a ticket that states a dependency in prose but carries no canonical **Depends on:**/**Blocks:** marker), it is wired into templates/govern/lint-tickets.sh, and templates/govern/test/test-lint-prose-deps.sh covers it and passes. The workspace copy is simply stale — `grep -c prose_dep_warnings scripts/govern/lib/common.sh` returns 0 while the hub returns a hit. Verified genuinely-unbuilt residue: neither the hub nor the workspace file-ticket.sh has a --depends-on flag (`grep -c depends-on` = 0 in both).

Impact: #9 and #11 both budget a full worker for work that is ~80% already shipped upstream. That worker will rediscover the existing helper mid-run, or worse, re-implement a second copy of it under a different name.

Fix direction: refresh the workspace's scripts/govern from the hub through the /shiploop:update channel, then rescope #9/#11 (per #30, collapse them into one) down to the genuinely-missing pieces: the file-ticket.sh --depends-on N[,M...] flag that emits a normalized `**Depends on:** #N` line, and documenting `**Depends on:**` / `**Blocks:**` as first-class per-ticket fields in the queue/tickets.md header. This is also a concrete instance of what #24 (deterministic pre-gate for already-fixed-upstream tickets) is trying to automate.

Done when: the workspace copy carries prose_dep_warnings; #9/#11 are collapsed and rescoped to the --depends-on flag plus the field documentation, or closed if that is filed elsewhere.

---

## #39 — Harness self-improvement: promote safe proposals from run-20260725-060424

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260725-060424. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `queue/tickets.md`: add `**Depends on:** #35` to tickets #33 and #34's field blocks now — a zero-script, data-only fix (ticket #36 already proposes this) — why: `govern::ticket_deps`/the #119 pre-spawn gate only honors the literal bold marker, so until this line lands either ticket could be selected and dispatched before #35 (the hub-sync bump) lands, burning a worker session on machinery this workspace's `scripts/govern` copy doesn't have yet.
- `scripts/govern/lib/common.sh`, `scripts/govern/lint-tickets.sh`, `scripts/govern/file-ticket.sh`: sync these from `shiploop/templates/govern/` (hub→workspace sync, e.g. `/shiploop:update`) — why: the hub template already implements `govern::prose_dep_warnings` (flags prose-only dependency phrasing like "sibling ticket #N" lacking a canonical `**Depends on:**`/`**Blocks:**` marker) and a duplicate-title advisory check in `file-ticket.sh` (flags `⚠ possible duplicate of #M` on >50% title-word overlap with an open ticket) — exactly the two mechanisms that would have caught this run's frictions (#33/#34's undeclared dependency, #38 re-filing #30's merge instruction). The workspace's `common.sh` is missing both blocks entirely — this is sync drift, not a missing feature; the fix already exists in this same repo.
- `scripts/govern/govern-improve.sh`: append a compact open-ticket digest (number, title, severity, `Where:` target files — no body) from `queue/tickets.md` when assembling this reviewer's context — why: confirmed absent from both the workspace and hub-template copy, so every improve run re-derives friction from scratch with no way to check "is this already tracked?" — the exact gap that let #38 restate #30's #9/#11-merge instruction.
- `scripts/govern/govern-improve-triage.sh`: before auto-filing a new "promote safe proposals" ticket, check whether an already-open ticket carries the same auto-promotion marker and targets overlapping files/tickets; if so, append the new bullets to that existing ticket's body instead of filing a new `## #N` — confirmed absent from both workspace and hub copy — why: this is the actual mechanism (two runs' reviewers independently auto-promoting overlapping fixes) that produced the #30/#38 duplicate pair.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-25 06:41 — run run-20260725-060424 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #40 — --parallel orchestrator exits before every run-end block (self-improve, escalations emit, health, sync-port)

**Severity:** Medium

Where: scripts/govern/run-loop.sh (+ hub template shiploop/templates/govern/run-loop.sh) — `if [[ "$PARALLEL" -eq 1 ]]; then govern::_parallel_run; exit $?; fi`, immediately before the sequential `while :; do ... done` loop.

Observed: the orchestrator returns from govern::_parallel_run and `exit`s, so EVERY run-end block below the loop is skipped for the orchestrator's own run: the self-improvement review (govern-improve.sh) + improve-triage, the opt-in self-apply, the authoritative #337 pending-escalations emit (which is the #62 operator hand-off the launching /govern relay reads), the run-end govern-health ROI emit, and the sync-port auto-trigger. Children each run their own copies against their own run dirs, so the work is not entirely lost — but it is now N-way: N children each write governor/pending-escalations.json (last-writer-wins, so the operator hand-off reflects one arbitrary child's slice rather than the run), N children each fire sync-port at their own run-end, and the aggregated run id the operator sees in the log never gets an improvements block at all. With GOVERN_PARALLEL_DEFAULT>1 this is the DEFAULT run shape, so the self-improvement channel silently degrades exactly where it is most needed.

Fix direction: (a) suppress the run-end blocks in children (an env flag the orchestrator sets, e.g. GOVERN_CHILD_DRIVER=1) and run them ONCE in the orchestrator over the aggregated $RUNDIR/state.jsonl — the same shape the whole-run supervisor pool review already uses; or (b) keep children as-is but have the orchestrator re-emit pending-escalations + health last, so the operator hand-off is at least run-scoped. (a) is more faithful and matches how the pool supervisor pass was done.

Done when: a --parallel backlog run produces exactly ONE improvements block, ONE pending-escalations emit and ONE sync-port trigger for the aggregated run; a test asserts the counts under a 2-driver fan-out; hub and workspace copies stay identical.

---

## #41 — test-wrap-in-place.sh SIGINT section flakes under concurrent load

**Severity:** Low

Where: shiploop/templates/govern/test/test-wrap-in-place.sh (+ the workspace copy scripts/govern/test/), section 5 ("wrap exits nonzero after SIGINT" / "trap restored layout byte-identical" / "residue after SIGINT rollback" / "repo HEAD intact after SIGINT").

Observed: all four section-5 assertions failed once during a full-suite run executed while three other govern suites were running concurrently on the same machine, and passed on a re-run of the identical tree on an idle machine (and passed on a pristine HEAD worktree under the same load). The section sends SIGINT to a backgrounded scaffold and then asserts on the rollback; under CPU contention the signal evidently lands before the trap is armed (or before the work it rolls back has happened), so the assertions see an un-rolled-back / not-yet-started state rather than a real defect. CI runs the suite serially on a dedicated runner, so this has not been seen there — but it makes a local full-suite run an unreliable pre-PR gate, which is exactly when a developer runs it alongside other work.

Fix direction: make the SIGINT delivery deterministic instead of time-based — have the scaffold under test touch a sentinel file once its trap is armed and the wrap has started, and poll for that sentinel (bounded) before sending the signal, rather than sleeping a fixed interval. Keep the existing timeout as a backstop.

Done when: the section passes reliably with the suite running under artificial CPU load (e.g. several concurrent runs); no fixed sleep remains between the background launch and the kill.

---

## #42 — Harness self-improvement: promote safe proposals from run-20260725-063340

**Severity:** Low

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260725-063340. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `governor/improvements.md` (via `govern-improve.sh`'s output contract): tag each proposal bullet `[self-apply-eligible]` or `[policy-file — needs human/ticket]` based on whether its target file is in `govern-self-apply.sh`'s allowlist — why: makes visible at proposal time which fixes are structurally stuck and need a human/ticket, instead of silently re-proposing the same policy-file fix run after run.
- `scripts/govern/govern-improve-triage.sh`: before filing a new "promote safe proposals from run X" ticket, check for an already-open ticket with the same auto-promotion marker and overlapping target files, and append instead of filing a new one — why: proposed 3 times now (05:53, 06:25, this run) and still unapplied; #9/#10/#11/#12/#36/#39 are the visible cost.
- `queue/tickets.md`: add `**Depends on:** #35` to ticket #33's field block — a one-line, zero-script, data-only fix an operator can apply directly right now.
- `scripts/govern/select-ticket.sh`: WARN in the selection log when 2+ open tickets match `^Harness self-improvement: promote safe proposals` — why: gives the run loop itself a nudge toward the merge the supervisor has now requested three runs in a row.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-25 07:15 — run run-20260725-063340 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #44 — GOVERN_PARALLEL_DEFAULT is never set — parallel-by-default is not actually in effect

**Severity:** High
**Model:** sonnet

Where: scripts/lib/workspace.sh (workspace config sink) + shiploop/templates/seed/workspace.sh (the seed every new fleet is scaffolded from); consumed at scripts/govern/run-loop.sh:129

Observed: v1.11.0 shipped "full-driver parallel backlog mode" (#87) and the operator explicitly chose parallel-on-by-default with N=4. The mechanism, the `--parallel[=N]` / `--serial` flags, and the precedence ladder all landed correctly. But the DEFAULT VALUE was never wired:

  run-loop.sh:129 → PARALLEL_DEFAULT="${GOVERN_PARALLEL_DEFAULT:-1}"

and `GOVERN_PARALLEL_DEFAULT` is set NOWHERE — not in this workspace's scripts/lib/workspace.sh, and not in shiploop/templates/seed/workspace.sh. run-loop.sh itself documents that `--serial`, `--parallel=1` and `GOVERN_PARALLEL=1` all mean the same thing, so the effective default is SERIAL.

Consequence: every workspace on v1.11.0 — this one and every newly scaffolded fleet — still runs one ticket at a time unless the operator passes `--parallel` by hand. The headline behavior change of the release is inert. Note `/shiploop:update` deliberately PRESERVES workspace.sh and never overwrites it, so existing workspaces cannot pick this up from a template bump; the seed fix only helps NEW scaffolds, and existing ones need an explicit migration note.

This is also a confirmed instance of ticket #31 (nothing verifies a ticket's Done-when before it is marked resolved and deleted): #14's Done-when literally read "reports parallel mode with a cap of 4 by default", the run reported resolved=1, the PR auto-merged, and the ticket was deleted. Unlike #31's original (mis-specified) example, this criterion was correct and simply unmet — so #31 now HAS the real instance it was missing, and should be re-weighted accordingly.

Fix direction: (1) add `GOVERN_PARALLEL_DEFAULT` to shiploop/templates/seed/workspace.sh with a documented default (4 per the operator's choice) and an explanatory comment matching the style of the neighbouring GOVERN_* knobs. (2) Add the same line to THIS workspace's scripts/lib/workspace.sh. (3) Because /shiploop:update never overwrites workspace.sh, add a surfaced warning — the existing "new knobs landed in the hub" warning path in the update flow is the natural home — so upgrading fleets are told to add the knob rather than silently staying serial. (4) Consider whether run-loop.sh's own fallback should be 1 or something higher; leaving it 1 is the safe fail-closed choice, but then the seed MUST carry the real default.

Done when: a freshly scaffolded workspace runs parallel with cap 4 by default (verify via `run-loop.sh --dry-run` reporting parallel mode, not serial); this workspace does the same; `/shiploop:update` surfaces the missing knob to an existing workspace instead of leaving it silently serial; the operator can still opt out per-run with `--serial`; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR (workspace.sh itself is the documented exception — it is operator config, never template-overwritten).

Ref: session 2026-07-25 — found while auditing whether model+effort right-sizing is actually in effect after the v1.11.0 converge.

---

## #45 — Benchmark: measure shiploop's real cost reduction vs a regular Claude session on the same work

**Severity:** Medium
**Model:** opus

Where: new benchmark harness under shiploop/templates/govern/bench/ (or a top-level bench/ in the hub); consumes governor/ticket-history.jsonl and govern-health.sh

Observed: shiploop's core claim is that a project using it spends materially less than one that does not — via right-sized workers, agent orchestration inside the worker, and a compounding CLAUDE.md lesson loop. That claim is currently UNMEASURED. What exists (ticket-history.jsonl + govern-health.sh) reports shiploop's own absolute spend; nothing compares it against the counterfactual of doing the same work in an ordinary interactive Claude session.

Evidence that the claim needs real measurement rather than assertion: over the 2026-07-25 token-efficiency build, 13 recorded tickets cost 181.6M tokens / $102.45, averaging 14.0M / $7.88 — and the per-ticket average ROSE across the session (from $5.68 to $7.88) while the efficiency machinery was being built. Individual tickets ranged $0.34 to $33.66 — a ~100x spread on tiers chosen by hand. None of that tells you whether shiploop is cheaper than the alternative, because there is no control arm.

Fix direction: build a repeatable A/B benchmark.
- Define a fixed task set (N real tickets of varying difficulty, or a frozen synthetic set committed to the repo so runs are comparable over time).
- ARM A: shiploop governor — per-ticket right-sized headless worker, worker-as-router delegation, CLAUDE.md lessons available.
- ARM B: control — a single interactive/headless Claude session doing the same task set end to end, no governor, no per-ticket right-sizing, no lesson injection.
- Measure per arm: total tokens (split input/output/cacheRead/cacheCreation), wall-clock, tickets completed, and CORRECTNESS (CI green / acceptance criteria met) — a cheaper arm that ships worse work is not a win, so cost-per-SUCCESSFUL-ticket is the headline metric, not cost alone.
- Control for confounders: same base commit, same task text, same model availability, cache state noted. Run each arm more than once if variance is high (the 100x intra-arm spread above suggests it will be).

Report the result as a committed markdown artifact with the raw numbers, so the claim is auditable rather than marketing. If the benchmark shows shiploop is NOT cheaper for some task class, say so in the artifact — that finding is more valuable than a favorable number, and it tells you where the harness needs work.

Positioning constraint: report in TOKENS and WALL-CLOCK as the primary units. Dollar figures are secondary and must not become a per-ticket price hook — the intended framing is subscription economics, where the marginal cost of a run is near zero and the real currencies are rate limits and time.

Depends on the decision telemetry work (model/effort/attempt logged per ticket) to attribute arm-A costs to tiers; without it the benchmark can compare totals but cannot explain them.

Done when: a committed benchmark harness runs both arms over a fixed task set and emits a comparable report; the report includes cost-per-successful-ticket, not just raw spend; confounders and run count are documented; the result artifact is committed with raw numbers; an unfavourable result is reported honestly rather than suppressed.

Ref: session 2026-07-25 — operator asked for this directly after the v1.11.0 token-efficiency release, noting the reduction claim is still unproven.

---

## #47 — Harness self-improvement: promote safe proposals from run-20260725-112937-10735

**Severity:** Low

⚠ possible duplicate of #9

Where: scripts/govern/* and/or governor/* (per the proposals below).

Observed: govern-improve.sh proposed these SAFE/additive harness improvements after run run-20260725-112937-10735. Auto-promoted from governor/improvements.md by govern-improve-triage.sh (#274) so they are drained like any ticket instead of waiting on a manual promote-remember step (same remember-vs-mechanism class as #271).

Proposals (classified safe/additive — none touches a governor safety rail):
- `governor/worker-prompt.md`: Add an explicit instruction to check CI baseline before declaring `resolved` — compare the PR's failing checks against `gh run list --branch main --limit 3` (or equivalent) to determine whether a red check predates the worker's own change — why: ticket #46's worker rediscovered this exact lesson after the fact, but the harness discarded it before it reached CLAUDE.md; teaching it up front prevents every future worker from rediscovering it and wasting CI-fix cycles on unrelated upstream breakage.
- `scripts/govern/run-loop.sh` (resolved→failed CI-red downgrade path) / `scripts/govern/govern-bookkeep.sh`: persist any `lessonPatch` a worker returned even when the ticket gets CI-downgraded to failed (e.g. append to `governor/improvements.md`), instead of silently dropping it because `govern-bookkeep.sh` only runs in the `status=="resolved"` branch — why: this run is direct proof a genuinely useful lesson was generated and then lost; without this fix the harness keeps losing valid lessons every time a resolved ticket gets downgraded.
- `scripts/govern/run-loop.sh` (`merge_pr_for_ticket` CI-fix redispatch): before spending the single `GOVERN_CI_FIX_TRIES` retry, check whether `origin/main`'s own latest CI run is already red (baseline-red); if so, skip the fix-dispatch and record a distinct note like `CI-red-baseline-preexisting` instead of `CI-red-left-open` — why: if CI was already broken on main, the CI-fix worker is doomed by construction, burning the one retry and mislabeling the failure as the ticket's fault — exactly the scenario #46's worker diagnosed on its own.
- `governor/README.md`: document that a re-selected ticket with an already-open PR is adopted via `govern::find_pr` without spawning a new worker and is re-fed through `await-ci.sh` on the next run — why: this auto-retry-on-reselection behavior isn't documented, so an operator seeing "failed, worktree preserved" might intervene (e.g. delete the worktree) in a way that breaks that adoption path.

Fix direction: implement each proposal above as a normal harness PR (a PR on the meta-repo itself), or explicitly decline it in the PR description if on closer look it is not worth doing.

Done when: each safe proposal above is implemented via a harness PR or explicitly declined.

Ref: governor/improvements.md block "2026-07-25 11:47 — run run-20260725-112937-10735 (resolved/parked/failed observed)". 0 rail-touching / OPERATOR DECISION proposal(s) from the same block were intentionally EXCLUDED by the classifier and remain human-gated in improvements.md — a harness-self-change auto-merges on the harness repo (no PR-level CI), so it must stay behind the human gate (#274).

---

## #48 — Workers load the full slash-command surface they never use — pass --disable-slash-commands

**Severity:** Medium
**Model:** haiku

Where: shiploop/templates/govern/spawn-worker.sh — the `claude -p` invocation (~line 470-476, alongside the existing --strict-mcp-config / --setting-sources flags)

Observed: MEASURED, not inferred. A worker's baseline context — before the ticket prompt, before reading any file — is ~33,000 tokens (measured empirically: `claude -p "..." --strict-mcp-config --setting-sources user --model haiku` reports cache_creation 15,314 + cache_read 17,703). Adding `--disable-slash-commands` brings that to ~30,400, a saving of ~2,600 tokens.

That prefix is re-read on EVERY turn. Per TokenJam telemetry over 30 days, average context re-read per turn is ~130k tokens across 110,146 turns, so ~2,600 tokens is ~2% of a turn's re-read, paid on every turn of every worker. It also avoids a proportional slice of cache-WRITE cost, which telemetry shows is 32% of total spend on only 4.8% of tokens (writes price ~12.5x reads).

Honest sizing: this is a ~2% lever, not a large one. It is worth doing because it is a one-flag change with near-zero risk, not because it is transformative. Do NOT let the PR description overstate it.

Verified non-levers, recorded so nobody re-tries them: `--allowedTools` does NOT reduce the prefix (measured 34,253 vs 33,017 baseline — it gates permission, not what loads). `--bare` errors out without explicitly re-provided context (`is_error: true`, all-zero usage) and additionally skips hooks and LSP, so it is NOT a drop-in and would need its own scoped investigation.

Fix direction: pass `--disable-slash-commands` on the worker spawn, behind a knob (e.g. GOVERN_WORKER_SLASH_COMMANDS=1 to restore) so an operator whose worker prompt genuinely invokes a skill can opt back in. BEFORE enabling by default, verify the worker prompt and operator doctrine never instruct a worker to invoke a slash command / skill — grep governor/worker-prompt.md and governor/preferences.md for `/` command invocations. If any exist, either rewrite them to use Bash/git/gh directly or leave the flag opt-in and say so in the PR.

Done when: workers spawn with --disable-slash-commands by default; a knob restores the old behavior; the worker prompt is confirmed not to depend on slash commands; a before/after baseline measurement is recorded in the PR description; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy is refreshed separately through `/shiploop:update`.

Ref: session 2026-07-25 — measured directly against the installed claude CLI while auditing worker prefix size; prompted by a sibling fleet's finding that workers load tools/skills/plugins they cannot use.

---

## #49 — Check the base branch is CI-green before dispatching workers — a red baseline fails every worker in the wave

**Severity:** High
**Model:** sonnet

Where: shiploop/templates/govern/run-loop.sh — the run-start preflight block (the same once-per-run region #90 established), before any worker is spawned

Observed: MEASURED today. Ticket #46 was dispatched while `main` was CI-red. Its change touched exactly one markdown file and could not possibly have failed the suite, but its PR (shiploop#91) inherited the broken baseline, went red, and the ticket was recorded `failed` — after a full worker session. The worker did correct work and was charged for discovering an unrelated pre-existing breakage.

Under parallel execution (now the DEFAULT as of v1.11.1, cap 4), this scales: a red baseline means every concurrent worker in the wave opens a PR that cannot go green, so a whole fan-out is wasted rather than one ticket. The governor already polls CI *after* a PR exists (await-ci.sh, up to 30 min per PR), so it currently discovers the problem at the most expensive possible moment — after N workers have each done a full session.

A `gh run list --branch main --limit 1` costs one API call and nothing in tokens.

Fix direction: in the run-start preflight (once per run, not once per driver — reuse the #90 seam), query the base branch's latest CI conclusion. If it is a FAILURE, do not dispatch: abort the run with a clear message naming the failing run URL, or park with an escalation. Fail OPEN, not closed, on anything ambiguous — no `gh` auth, no CI configured, no runs yet, an in-progress run, or an API error must all proceed exactly as today. This check exists to catch an unambiguous red, never to block a fleet whose CI is simply absent (many repos have no checks at all — the harness already has a documented "green-or-no-checks" merge policy and this must be consistent with it).

Add a knob to skip it (e.g. GOVERN_SKIP_BASE_CHECK=1) for operators who intentionally work on a red baseline — for example, when the ticket being worked IS the fix for the red CI. Consider auto-detecting that case: if the only eligible ticket names the failing area, proceeding is correct.

Done when: a run whose base branch is unambiguously CI-red refuses to dispatch workers and reports the failing run URL; absent/ambiguous/in-progress CI proceeds unchanged (fail-open); a knob overrides; the check runs once per run, not once per parallel driver; a test under templates/govern/test/ covers red-blocks, no-checks-proceeds, and api-error-proceeds; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy is refreshed separately through `/shiploop:update`.

Ref: session 2026-07-25 — ticket #46 failed solely because main was red at the time of dispatch (main went red at a3331a3 / v1.11.1, fixed at 17c0b58).

---
