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

## #13 — Workers verify on macOS while CI runs Linux — inject failing-CI-log excerpts on retry + portability guidance in worker prompt

**Severity:** Medium
**Model:** sonnet

Where: shiploop/ sub-repo — worker prompt assembly (templates/govern/spawn-worker.sh worker instructions) and/or CI docs in templates/seed/CLAUDE.md

Observed: during the v1.9.0 runner build, ticket #5 burned BOTH its governor attempts on a Linux-only CI failure (BSD stat -f %m succeeds-with-garbage on GNU stat, so the worker's macOS-local test run passed while CI failed; the retry worker then fixed an unrelated test issue because it still could not reproduce the failure). Cost: 2 failed outcomes, one manual fix dispatch with a hand-extracted CI diagnosis. The harness gives workers no guidance that CI runs ubuntu while dev machines are macOS, and no nudge to read the failing CI job log before re-verifying locally.

Fix direction: (a) worker prompt gains a portability clause — target env is Linux CI; for bash, prefer GNU-first constructs with BSD fallback (stat/sed/date are the classic splits); (b) on a CI-red retry, the re-dispatched worker's prompt should include the failing job's extracted error lines (gh run view --log-failed | relevant grep) so it fixes the ACTUAL failure instead of guessing from a local run that passes; (c) optionally a lint for known BSD-only flag patterns in templates/.

Done when: worker prompt carries the portability + read-CI-log-first instructions; the CI-red re-dispatch path injects failing-check log excerpts; a note in templates/seed/CLAUDE.md anti-patterns.

Ref: PR anshss/shiploop#76 history (2 red runs, fix commit b72c82e); learnings from run-20260711-033247/035801

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

Update (2026-07-26): the earlier cost objection ("paid unconditionally, 320k per ticket") has been re-derived and does NOT hold — see learnings.md. Against the measured mean 7,188,418-token session, an injected digest costs roughly 1-4% (a 2k digest over the measured median 37-turn session ≈ 74k ≈ 1%; a 3k digest over ~107 turns ≈ 320k ≈ 4%). Do not purge this on cost grounds. It remains a gated bet whose only real open question is whether the injection deletes more exploration than that 1-4% — an empirical question, not a foregone conclusion either way.

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

Update (2026-07-26): the earlier cost objection has been re-derived and does NOT hold — see learnings.md. An injected precedent excerpt costs roughly 1-4% of a mean 7.19M-token session at a 2-3k cap, so do not purge this on cost grounds; it remains a gated bet (on T1) whose only real question is whether the injection deletes more exploration than it costs.

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

ESCALATION (found later the same session): the leak is NOT limited to the per-ticket claim lock. A no-target `run-loop.sh --dry-run` also acquires the GLOBAL exclusive run lock (`governor/.govern.lock`) and leaves it behind on exit — observed live: holder `run=run-20260725-150606-41586 pid=41586`, process long dead, lock still present hours later. That is materially worse than a skipped ticket: a stale exclusive lock makes the NEXT `/govern` refuse to start at all with "another govern run holds $LOCK", i.e. a denial-of-service on the whole harness. And `CLAUDE.md` explicitly instructs operators NOT to delete that lock by hand (#183), so the documented guidance leaves them stuck. Severity should be read against that, not against the single-ticket case this ticket was originally filed for.

Fix direction: the actual defect is that the lock is never RELEASED. (a) Ensure the per-ticket claim lock is released on EVERY exit path in dry mode — including early exits and signals — via a trap. Keep acquiring it (per #104). (b) In the claim path, when the lock exists, check whether the holder pid is still alive; if it is dead, reclaim it and log "stale-reclaimed" rather than skipping the ticket. Preserve the #183 safety property: NEVER reclaim a lock whose holder is alive. (c) `test-claim-lock-dry.sh` must still pass unchanged — treat it as the guard against re-introducing the wrong fix.

Done when: `run-loop.sh <N> --dry-run` leaves no governor/.locks/ticket-<N> behind (verify with ls after a dry run); a lock whose holder pid is dead is automatically reclaimed by the next run with a clear log line; a lock whose holder is ALIVE is still respected and still skips; a test under templates/govern/test/ covers dead-holder reclaim and live-holder respect; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy under `scripts/govern/` or `governor/` is refreshed separately through the `/shiploop:update` channel, so do NOT hand-edit it in the same PR.

Ref: session 2026-07-25 — hit while dry-running ticket #14 before launching the token-efficiency fan-out; cost one no-op govern run and a manual lock removal.

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

## #52 — Parallel-by-default lets a killed ticket be attempted twice in one run — hub main CI red since v1.11.1

**Severity:** High

Where: shiploop/templates/govern/run-loop.sh (PARALLEL_DEFAULT fallback at ~line 134; the per-driver `excludes` set and the claim-lock release path); shiploop/templates/govern/test/test-timeout-classification.sh + test-budget-exceeded-classification.sh.

Observed: the hub's `main` CI has been RED since the v1.11.1 release commit (a3331a3). Run 30142058515 on that commit: `passed=108 failed=2 skipped=5 total=115`, failing `test-budget-exceeded-classification` and `test-timeout-classification`. Both fail the same way — a kill-before-verdict ticket is recorded TWICE (`expected: [timeout]`, `actual: [timeout\ntimeout]` in both state.jsonl and the cross-run history), i.e. the ticket was attempted twice inside one run. Verified pre-existing and NOT caused by the retry-escalation PR (#94), which shows `passed=109 failed=2 skipped=5 total=116` — the same two failures, +1 test, +1 pass.

Root cause (hypothesis, code-supported): v1.11.1 raised `PARALLEL_DEFAULT="${GOVERN_PARALLEL_DEFAULT:-4}"` in run-loop.sh, so a plain `bash run-loop.sh` now fans out into 4 drivers. Both tests invoke run-loop with NO `--serial`. The 'already attempted this run' exclusion (`excludes`) is per-driver IN-MEMORY state, so once a worker is killed by the wall-clock/token watchdog and its claim lock is released, a sibling driver in the same run can re-select the same ticket. It is timing-dependent: it reproduces reliably on Linux CI and intermittently on macOS under load (it also flakes when two suites run concurrently), which is why it was not caught before the release.

This costs a real worker per occurrence — a killed ticket is exactly the expensive kind to re-attempt — and it keeps hub CI red, which matters because the governor auto-merges this repo on green-or-no-checks: every PR against a red main must now be reasoned about by hand.

Fix direction: make the attempted-this-run exclusion CROSS-DRIVER (a run-scoped file under $RUNDIR that each driver appends to and consults before selecting, alongside the existing claim lock), so a killed/timed-out ticket is not re-selected by a sibling in the same run. Do NOT pin the two tests to `--serial` as the fix — that masks the defect (see the root CLAUDE.md anti-pattern on proving a fan-out shape with the existing tests). If a `--serial` pin is used at all, it must be in addition to the real fix and justified per test.

Done when: hub `main` CI is green; both tests pass on Linux CI without being pinned to --serial; a test covers 'a ticket whose worker was killed is not re-selected by a sibling driver in the same run'; `bash -n` passes; hub-first — land in shiploop/templates/** only.

---

## #55 — A named ticket SET gets neither locality batching nor the backlog gates — the operator's main workflow is the unprotected path

**Severity:** High
**Model:** sonnet

Where: shiploop/templates/govern/run-loop.sh — the batching gate (`if [[ "$BATCH_MAX" -gt 1 && "${#TARGETS[@]}" -eq 0 ]]`, ~line 1230) and the --parallel orchestrator's child shape (a child handed ONE explicit ticket).

Observed: the operator's stated primary workflow is "prompt inside the workspace to launch multiple tickets at once" — i.e. `run-loop.sh N N N --parallel` (or /govern with several ticket numbers). That path is the LEAST protected one:

(1) Locality batching (#23/#92) is gated on `${#TARGETS[@]} -eq 0`, so a NAMED set never groups. Verified live: with GOVERN_BATCH_MAX=3 set, `run-loop.sh 24 25 26 --parallel --dry-run` spawned three separate drivers, one per ticket, with no grouping — the same shape as before batching existed. Tickets #25 and #26 both edit spawn-worker.sh, so that dispatch would have put two concurrent workers on the same file: exactly the collision batching was built to prevent.

(2) Per the CLAUDE.md anti-pattern already recorded from #87, a child handed ONE explicit ticket is indistinguishable from an operator typing `run-loop.sh <N>` and therefore takes every explicit-target BYPASS: the #119 dependency gate, the cross-driver re-verify, and the #60 failure-streak circuit breaker. It also never reaches the periodic supervisor.

So the two protections added in v1.12.0 and v1.11.x both engage only on a bare backlog pull, while the workflow the harness is actually marketed for — "address these N tickets" — gets neither. This session is the evidence: every wave was dispatched as named tickets, and the operator (and later the assistant) hand-partitioned by file scope on every single one to avoid collisions, four separate times.

Fix direction: make a named SET behave like a bounded backlog rather than N independent single-ticket runs. Options to weigh in the PR: (a) allow batching when TARGETS is non-empty by partitioning the NAMED set into locality groups (the set is known up front, so grouping is strictly easier than in the backlog case); (b) have the --parallel orchestrator hand each child a FULL-driver run restricted to a subset (`--only`/`--include`) rather than one explicit ticket, so children keep the backlog gates; or (c) both. Preserve the genuine carve-out: exactly ONE named ticket should still stay sequential and unbatched — there is nothing to group and the operator clearly means "just this one".

Whatever shape is chosen, the dependency gate MUST apply to a named set: today naming two tickets where one depends on the other silently ignores the declared `Depends on:`.

Done when: `run-loop.sh A B C --parallel` groups A/B/C by locality when GOVERN_BATCH_MAX>1 and never puts two same-file tickets in concurrent workers; the #119 dependency gate is enforced for named sets; a single named ticket still bypasses grouping; a test under templates/govern/test/ covers named-set grouping and named-set dependency enforcement; bash -n passes; hub-first — land the change in `shiploop/templates/**` ONLY; the workspace copy is refreshed via `/shiploop:update`.

Ref: session 2026-07-25 — found while trying to exercise v1.12.0's batching on tickets #24/#25/#26; verified by dry-run that the named-set path ignores GOVERN_BATCH_MAX entirely.

---

## #56 — govern misclassifies a CLI usage error as a generic ticket failure — no diagnostic signal when a harness bump ships an unsupported flag

**Severity:** High
**Model:** sonnet

Where: scripts/govern/lib/ (signature/classification helpers — infra_error_signature, interrupted_error_signature, worker_killed, govern::extract_report) + the hub template equivalent under shiploop/templates/govern/lib/.

Observed: Tested against real claude 2.1.220 — running `"$claude_bin" -p x --definitely-not-a-real-flag >"$jsonl" 2>&1` exits 1 and writes a 53-byte file whose only line is plain text: `error: unknown option '--definitely-not-a-real-flag'`. Because the worker spawn redirects `2>&1` into `$jsonl`:
- govern::extract_report can't parse it (not JSON)
- stream_grep finds no `"type":"result"`
- worker_killed is false (rc=1, not >128)
- neither infra_error_signature nor interrupted_error_signature match

So it falls through to the generic synthesized `failed` report ("no valid report from worker") — the same bucket as an ordinary worker failure, with no distinguishing signal.

Impact: if a harness bump ever ships a CLI flag the fleet's installed `claude` binary doesn't support (version skew, a removed/renamed flag), EVERY worker in the run dies the same way and the operator sees N indistinguishable ticket failures with zero signal pointing at the actual cause (a CLI usage error, not a per-ticket problem). This is exactly the kind of failure that should halt the run loudly instead of quietly burning the entire backlog one ticket at a time.

Fix direction: add a usage-error signature matching a non-JSON first line combined with rc=1 (e.g. `^error: unknown option` / `^error: unknown command` / general "first line isn't JSON and doesn't match an interrupted/infra pattern") and classify it distinctly from the generic failed bucket — then have the run loop halt loudly (not just log another `failed` ticket), since a CLI usage error is a fleet-wide condition, not a per-ticket one.

Done when: a worker run against a CLI invocation that errors with a non-JSON usage-error line and rc=1 is classified with a distinct signature (not the generic "no valid report from worker" failed bucket); the run loop halts/escalates loudly instead of continuing to burn the backlog; a test under templates/govern/test/ covers the usage-error signature; bash -n passes; hub-first — land in shiploop/templates/govern/lib/** and port down via /shiploop:update.

Ref: session 2026-07-26 — confirmed live against claude 2.1.220 by invoking a nonexistent CLI flag and inspecting the resulting jsonl + classification path.

---

## #57 — Ad-hoc test runs polluted logs/govern/ with 227 fixture transcripts — WS_ROOT resolution has no guard against a stubbed claude_bin

**Severity:** High
**Model:** sonnet

Where: scripts/govern/lib/common.sh (WS_ROOT resolution, ~line 9) + scripts/govern/test/ (the fixture-stub test scripts) + logs/govern/ (the polluted tree itself).

Observed: 227 of 262 files under logs/govern/run-*/ticket-*/worker*.jsonl are test-fixture output, not real worker sessions — 120 match byte-for-byte the canned `printf` strings in fake-`claude` stubs in scripts/govern/test/*.sh (test-spawn-worker.sh:35,82; test-interrupted-classification.sh:44,110,186,274; test-infra-halt.sh:23,46; test-locality-batch.sh:154; test-pr-footer.sh:39; test-worker-log-runscope.sh:43; test-tokenjam-runid.sh:40), and 84 are zero-byte placeholders in the same run-dirs. They use fixture ticket IDs that never existed in the queue (1, 5, 7, 8, 9, 19, 67, 101-104, 201-203, 301-303), spread across 18 run-dirs (4 on 2026-07-11, 14 on 2026-07-25 — ongoing, not historical). A later measurement pass found 23 MORE fixture transcripts previously miscounted as real sessions: single-line stubs with round-number usage (`input_tokens:100, output_tokens:50, cache_read:0, cache_creation:0`) and no `message.id`, sourced verbatim from scripts/govern/test/test-budget-exceeded-classification.sh:40,64 and scripts/govern/test/test-history-sizing-fields.sh:54. These 23 sit in the already-identified polluted run-dirs (run-20260725-121346-8620/ticket-7, run-20260725-111730-97043/ticket-7, run-20260725-111729-96725/ticket-7) but had a `"type":"assistant"` line, so a naive scan for that marker counted them as real. The reliable way to tell a real session from a fixture is the presence of a genuine `msg_...` `message.id` — fixtures never carry one. Only 35 of 262 files are real sessions.

Root cause: common.sh:9 resolves WS_ROOT as a fixed relative path from the sourcing script's location ($GOVERN_LIB_DIR/../../..) rather than via a workspace marker or an explicit override guard. The test-*.sh scripts DO correctly export GOVERN_LOG_ROOT and are hermetic when run through their normal harness — so this pollution came from ad-hoc manual repros that wired a fake-claude stub via PATH without exporting GOVERN_LOG_ROOT/GOVERN_WS_ROOT, letting WS_ROOT silently fall through to the real workspace root.

Impact: corrupts any cost/turn analysis run over the log tree — it caused a real measurement pass to report a bogus 78% "workers never reached a model turn" rate, because the fixture files (many zero-byte or single-line stub output) were indistinguishable from real failed sessions to a naive scan, and a subset of those single-line stubs (see the 23 above) even carry a `"type":"assistant"` line, so distinguishing fixtures from real sessions requires checking for a genuine `msg_...` message.id, not just the presence of an assistant turn.

Fix direction: make fixture runs structurally unable to write to the real tree — e.g. have spawn-worker.sh/run-loop.sh detect a stubbed/fake claude_bin (or require an explicit opt-in env like GOVERN_ALLOW_REAL_LOG_WRITE) and refuse to write under the real $WS_ROOT/logs unless it's set; or have WS_ROOT resolution require a workspace marker file rather than a fixed relative offset. Also clean up the 227 already-identified polluted files (the fixture-ticket-ID run-dirs above) so the log tree reflects only real worker sessions going forward.

Done when: a fixture/stub claude_bin run cannot write under the real logs/govern/ tree without an explicit opt-in; the 227 identified fixture files are removed from logs/govern/; a test covers "stubbed claude_bin refuses to write to the real log root"; bash -n passes; hub-first where the fix lives in scripts/govern/lib/common.sh's logic — port via shiploop/templates/govern/lib/common.sh and down via /shiploop:update; the log cleanup itself is workspace-local (logs/govern/ has no hub counterpart).

Ref: session 2026-07-26 — found while auditing logs/govern/ for a cost/turn measurement pass; traced every fixture file to its originating test stub by byte-for-byte string match; corrected 204→227 after a later pass caught 23 single-line stubs (test-budget-exceeded-classification.sh, test-history-sizing-fields.sh) that had been miscounted as real sessions for lacking an obviously-fixture shape while still lacking a genuine message.id.

---

## #58 — A worker transcript was written with 682,025 leading NUL bytes, masking a complete real session from every text-based analysis

**Severity:** Low
**Model:** sonnet
**Effort:** low

Where: scripts/govern/spawn-worker.sh (the $jsonl redirect + attempt/retry file handling) + hub template equivalent shiploop/templates/govern/spawn-worker.sh.

Observed: logs/govern/run-20260711-033250/ticket-7/worker.jsonl begins with 682,025 `\x00` (NUL) bytes before valid JSONL content starts. The real content is intact underneath — 10 assistant turns and a genuine result record with num_turns:57, total_cost_usd:$3.54 — so this is not truncation, it's a NUL-padded PREFIX in front of a complete, valid transcript.

Impact: because of the NUL prefix, `grep` (and any other text-mode tool) treats the file as binary and silently skips it — `grep -a` is required to see through it. So the session is invisible to every text-based analysis of the log tree (cost/turn measurement, classification signature scanning, etc.) despite containing a fully valid, resolvable worker report. This is silent data loss: nothing errors, the file is just quietly excluded from every scan that doesn't special-case binary detection. It is also unknown whether the same mechanism can corrupt a transcript that the RUN LOOP ITSELF needs to parse for its own report/classification — if so this isn't just a telemetry gap, it's a correctness bug.

Likely mechanism: a sparse-file write (e.g. a seek-past-end or truncate-then-write pattern) or a concurrent-append interaction between an attempt/retry and the `>"$jsonl" 2>&1` redirect, where a later write lands at a large offset before the actual content is flushed, leaving the gap zero-filled by the filesystem.

Fix direction: downgraded — this is n=1 (from 2026-07-11), root cause unknown, and has not recurred since; a full seek/append-ordering hunt for a one-off is a bad trade. Do NOT chase the write bug. Instead add a cheap tripwire: a lint/check that flags any `worker*.jsonl` beginning with NUL bytes (e.g. a one-line check in the log-tree audit path, or a periodic sweep) so a recurrence is detected immediately instead of silently, without investing in reproducing the original mechanism.

Done when: a cheap check exists that flags any `worker*.jsonl` file beginning with NUL bytes, runs as part of routine log-tree auditing (or an equivalent periodic sweep), and is proven to catch the already-known offending file (logs/govern/run-20260711-033250/ticket-7/worker.jsonl) as a regression check; bash -n passes; hub-first — land in shiploop/templates/govern/spawn-worker.sh (or the appropriate lib) and port down via /shiploop:update.

Ref: session 2026-07-26 — found while auditing logs/govern/ for a cost/turn measurement pass; confirmed via `grep -a` and byte-offset inspection that the file is a complete, valid, high-cost real session buried under a NUL prefix.

---

## #59 — Verify --exclude-dynamic-system-prompt-sections actually pays, or purge it

**Severity:** Medium
**Model:** sonnet

Where: shiploop/templates/govern/spawn-worker.sh, shiploop/templates/govern/lib/common.sh.

Observed: v1.13.0 shipped the `--exclude-dynamic-system-prompt-sections` flag into `templates/govern/spawn-worker.sh` behind a capability probe (`GOVERN_EXCLUDE_DYNAMIC_PROMPT`, default on), but its own keep/purge gate was never run — we shipped an unmeasured lever. Measurement now exists to size it: prefix re-read is 23.4% of total session tokens (aggregate over 35 real sessions), turn-1 loaded context is median 46,591 tokens (band ~36k-53k), and `prefix_i` varies 22k-36k per ticket (CoV 0.24). Important nuance found: turn-1 `cache_read` values recur EXACTLY across unrelated tickets (23,909 appears identically in tickets 27, 18, 44, 13, 15, 16, 14), proving a deterministic shared block ALREADY caches across workers — so the flag's marginal benefit is only over the dynamic sections (cwd, env, memory paths, git status), which may be small.

Fix direction: run two workers concurrently in different worktrees with the flag on vs off, compare the second worker's turn-1 `cache_creation`.

Done when: a committed before/after measurement exists and the flag is either kept with evidence or removed.

Ref: session 2026-07-26 — found while auditing logs/govern/ for a cost/turn measurement pass; the 23,909 cache_read recurrence and the 23.4% prefix figure were derived over the 35 confirmed-real sessions identified while investigating #57.

---

## #62 — Consolidated harness self-improvement duplicate cluster: dedup consumer, Depends-on/Blocks mechanism, CI-fix redispatch context, escalation fix

**Severity:** High
**Model:** sonnet

Where: `scripts/govern/govern-improve-triage.sh` + `scripts/govern/file-ticket.sh` (workspace) AND their `shiploop/templates/govern/govern-improve-triage.sh` + `shiploop/templates/govern/file-ticket.sh` counterparts (hub). Secondary targets named below.

Observed: this is the consolidation of an 11-ticket duplicate cluster (#9, #10, #11, #12, #36, #39, #42, #47, #50, #51, #53), all auto-filed by `govern-improve-triage.sh` from separate `govern-improve.sh` runs, most proposing overlapping fixes to the same root gap. Per #51: 9 open duplicate "Harness self-improvement: promote safe proposals" tickets accumulated across 9 runs before this consolidation (#9, #10, #11, #12, #36, #39, #42, #47, #50), and a 10th (#53) makes explicit that the fix for the duplication was itself proposed 4 times (#30, #39, #42, #51/#53) and never landed.

**Root cause — detection exists, nothing consumes it.** `file-ticket.sh:160-188` already runs a cheap title-word-overlap check on every new ticket and prepends `⚠ possible duplicate of #M` when >50% of the new title's words match an existing open heading — confirmed firing correctly, purely advisory ("NEVER blocks filing, purely advisory" per its own comment). 7 such markers exist in the current queue (4 literal `⚠ possible duplicate of #9` tags on #47/#50/#51/#53, 3 more referenced in ticket prose). `govern-improve-triage.sh:117` files every "promote safe proposals" ticket straight through `file-ticket.sh` with zero pre-check against already-open tickets carrying the same marker. The gap is the CONSUMER, not the detector.

**Hub-vs-workspace drift verdict (verify-before-building):** diffed `scripts/govern/lib/common.sh` / `scripts/govern/file-ticket.sh` against `shiploop/templates/govern/{lib/common.sh,file-ticket.sh}` — **byte-identical, zero diff, on both files, right now.** `govern::prose_dep_warnings` exists in BOTH copies (`common.sh:1334`), wired into `lint-tickets.sh` in both. #38's and #39's claim that the workspace `common.sh` is "missing both blocks entirely" (sync drift) is **no longer true** — the workspace has since caught up (likely via a `/shiploop:update` bump after #38/#39 were filed). Neither side has a `--depends-on` flag in `file-ticket.sh` (`grep -c depends-on` = 0 on both) — that is the one genuinely-unshipped piece from the #9/#11/#38 thread. Do NOT re-diagnose drift here; there is none left to fix.

**#33/#34 dead-reference check:** #36 and #39 both instruct adding `**Depends on:** #35` to tickets #33 and #34. Checked `git log --oneline --all | grep -iE "#33|#34"`: both are RESOLVED, not lost — `ae36ed9 docs(tickets): resolve #33 (shiploop#90)` and `326aaca docs(tickets): resolve #34 (shiploop#89)`. Both instructions are moot; dropped below with this evidence rather than carried forward.

**Corrections to the pre-analysis this ticket was scoped from:**
- The `GOVERN_FIX_CI` prompt-injection block (mirroring `GOVERN_RESOLVE_CONFLICT`) is proposed by **#10 and #50 only** — #47 does NOT propose this block (verified: #47's 4 bullets are CI-baseline-worker-prompt guidance, lessonPatch persistence, a baseline-red pre-retry skip, and a README doc note — none of them add the GOVERN_FIX_CI block itself). Merge #10+#50's version, not a 3-way merge.
- The "widen file-ticket.sh's duplicate check from title-words to `Where:`/target-file overlap, auto-emit `Depends on:`" ask is **#51's**, not #50's (#50 has no such bullet; verified by re-reading both in full).
- #50's "atomic cross-driver exclude tracking" (the `excludes` variable is per-driver in-memory, letting a killed ticket be re-selected by a sibling under `GOVERN_PARALLEL_DEFAULT>1`) is the exact same root cause already tracked as **#52** (High severity, hub `main` CI red since v1.11.1 over this). Not duplicated here — left fully owned by #52.

## Inventory — every distinct ask from the 11 tickets

**A. The core consumer fix (highest priority — this is what makes the other 10 tickets stop recurring):**
- [ ] `govern-improve-triage.sh`: before calling `file-ticket.sh` to file a new "Harness self-improvement: promote safe proposals from run-X" ticket, check whether an open ticket already carries the same auto-promotion marker / matches `^Harness self-improvement: promote safe proposals` — if so, APPEND the new run's proposal bullets to that existing ticket's body instead of minting a new `## #N`. (#30, #39, #42, #51, #53 — proposed 5 times, 0 landed.)
- [ ] `select-ticket.sh`: WARN in the selection log when 2+ open tickets match `^Harness self-improvement: promote safe proposals` — a visible nudge toward consolidation on every cycle until the consumer fix above lands. (#42, #53 — both propose this.)

**B. Depends-on / Blocks mechanism (from #9, #11, #30, #36, #38):**
- [ ] Document `**Depends on:** #K[, #J...]` as a first-class "Optional per-ticket field" in `queue/tickets.md`'s header (next to the existing `Model:` entry) — state it is the literal phrase `govern::ticket_deps` parses and the #119 pre-spawn gate enforces. (#9, #11)
- [ ] Add a `--depends-on N[,M...]` flag to `file-ticket.sh` (parallel to the existing `--model`/`--effort`/`--flow` flags), emitting a normalized `**Depends on:** #N` line. **Confirmed still genuinely unshipped on both hub and workspace** — see drift verdict above. (#9, #11, #38)
- [ ] Prose-dependency lint flagging a ticket that states a dependency in prose ("sibling ticket #N", "blocked by #N") without a canonical `**Depends on:**`/`**Blocks:**` marker — **ALREADY SHIPPED** as `govern::prose_dep_warnings` (`common.sh:1334`), wired into `lint-tickets.sh`, covered by `test-lint-prose-deps.sh`, identical on both hub and workspace. No work needed; this bullet exists in #9/#11 only because they predate confirming it shipped (per #38). (#9, #11 — DECLINE, already shipped)
- [ ] `governor/supervisor-prompt.md` schema (~line 26-28) + `escalations-emit-pending.sh` (lines 36-41): add a structured `orderingRisks: [{ticket, blockedOn, note}]` field, and promote non-empty entries into durable `## Open` items in `governor/escalations.md` — a supervisor's free-text ordering-risk observation currently only lives in the run's ephemeral review.md/pending-escalations.json and is overwritten by the next run. (#11 — unique, not proposed elsewhere)
- [ ] `govern::ticket_deps` gate (consumed by `run-loop.sh:673-690`): once a dependency is declared, also confirm the dependency's PR actually MERGED (reuse `govern::pr_state`), not just that the ticket entry was deleted — "Resolved" in this queue's own convention means "PR opened," not merged, so a correctly-declared dependency can still race an unmerged foundation through a narrower version of the original gap. (#11 — unique)
- [ ] `queue/tickets.md` + `select-ticket.sh`: add a `**Blocks:** #N[, #M...]` optional field feeding the same exclusion path `## Open` escalations already use. **Verify before building**: `govern::ticket_deps` (`common.sh:1269-1310`) already parses a `**Blocks:**` marker as an implicit dependency, consumed by the #119 pre-spawn gate (`run-loop.sh:1169-1182`) — so the mechanism may already substantially exist; confirm what (if anything) is actually missing (e.g. `select-ticket.sh`-level selection-time visibility vs. spawn-time deferral) before implementing, and decline the redundant part if the #119 gate already covers it. (#36 — unique, needs verification)
- [ ] `run-loop.sh` (~line 754, where a worker's `crossRefs.overlaps`/`crossRefs.dependsOn` is read off its report): write that back as a `Blocks:`/`Depends on:` line on the referenced ticket, or file it as an `## Open` escalation, instead of only setting `anomaly=1` for a single supervisor glance. (#36 — unique)
- [ ] `lint-tickets.sh` (or `file-ticket.sh` at filing time): WARN when a ticket's body names a CLI flag/env var (`--foo`, `GOVERN_*`) or orchestrator language ("N drivers") that doesn't grep-match anything in this workspace's CURRENT `scripts/govern/*.sh` — prevents dispatching a worker at machinery that only exists in the hub template (or nowhere), a confused park/fail. (#36 — unique; note the #33/#34 example that motivated it is now moot, but the general check is still worth having)
- [ ] `lint-tickets.sh`: add a non-blocking WARN validating that every `**Depends on:** #N` / `**Blocks:** #N` / `Ref: #N` pointer resolves to a `## #N` heading still present in `queue/tickets.md` — catches exactly the #33/#34 stale-reference class this consolidation just had to hand-verify via `git log`. (#51 — unique)
- [ ] `file-ticket.sh`: extend the existing title-word-overlap duplicate check to ALSO compare the new ticket's `Where:`/target-file text against every open ticket's `Where:` field, and when two open tickets name overlapping files, auto-emit `**Depends on:** #<older>` instead of only the cosmetic `⚠ possible duplicate of #M` marker. (#51 — unique; corrected attribution, not #50)
- [x] ~~`queue/tickets.md`: add `**Depends on:** #35` to #33 and #34~~ — MOOT, both resolved (`ae36ed9`, `326aaca`). (#36, #39 — dropped)
- [x] ~~sync `common.sh`/`lint-tickets.sh`/`file-ticket.sh` from hub~~ — ALREADY DONE, files are byte-identical. (#39 — dropped)

**C. CI-fix redispatch context (from #10, #47, #50):**
- [ ] `spawn-worker.sh`: add a `GOVERN_FIX_CI` prompt-override block (mirroring the existing `GOVERN_RESOLVE_CONFLICT` block) telling a CI-fix-redispatch worker the PR already exists, not to redo the ticket, and to query `gh pr checks`/`gh run view --log-failed` to diagnose the ACTUAL CI failure before touching anything — currently `GOVERN_FIX_CI` is set by `run-loop.sh` but never read in `spawn-worker.sh`, so the redispatched worker gets the plain first-attempt prompt with no idea CI is red or why. (#10, #50 — same ask, independently proposed; NOT #47)
- [ ] `run-loop.sh` (`merge_pr_for_ticket`): before each CI-fix redispatch, capture the failing check name(s) via `gh pr checks ... --json name,bucket`, pass them into the worker prompt via `GOVERN_FIX_CI_DETAIL`, and append them to the `CI-red-left-open` log line / `pr_summary` so the operator sees which check failed without opening GitHub. (#10 — unique)
- [ ] `governor/worker-prompt.md`: add an explicit instruction to check CI baseline before declaring `resolved` — compare the PR's failing checks against `gh run list --branch main --limit 3` to determine whether a red check predates the worker's own change. (#47 — unique; distinct from the run-loop pre-retry skip below)
- [ ] `run-loop.sh` (`merge_pr_for_ticket` CI-fix redispatch): before spending the single `GOVERN_CI_FIX_TRIES` retry, check whether `origin/main`'s own latest CI run is already red (baseline-red); if so, skip the fix-dispatch and record `CI-red-baseline-preexisting` instead of `CI-red-left-open` — avoids burning the one retry on a doomed dispatch when the base itself is broken. (#47 — unique, explicitly flagged as distinct and valuable)
- [ ] `run-loop.sh` (CI-red downgrade path) / `govern-bookkeep.sh`: persist any `lessonPatch` a worker returned even when the ticket gets CI-downgraded to `failed`/`parked`, instead of silently dropping it because `govern-bookkeep.sh` only runs in the `status=="resolved"` branch. (#47, #50 — same ask, independently proposed)
- [ ] `governor/README.md`: document that a re-selected ticket with an already-open PR is adopted via `govern::find_pr` without spawning a new worker and is re-fed through `await-ci.sh` on the next run — undocumented today, so an operator might break the adoption path by intervening (e.g. deleting the worktree). (#47 — unique)
- [ ] `config-check.sh`: add a drift check between this workspace's `scripts/govern/test/*.sh` and the hub's `templates/govern/test/*.sh` (an ONGOING automated check, distinct from the one-time #35 bump) — the hub pins `--serial` on `test-budget-exceeded-classification`/`test-timeout-classification` as a band-aid for #52's race; a drift check would have caught the workspace copy missing that pin before CI (built fresh from hub templates) diverged from local verification (stale workspace copy). (#50 — unique)
- [ ] `governor/worker-prompt.md` or root `CLAUDE.md`: one-line note on the `templates/govern/` (canonical, synced via sync-templates.sh) vs `scripts/govern/` (this repo's live/dogfood copy — run tests from here, never `cd` into `templates/` directly) split — a worker guessed wrong and hit a dead end (`cd templates/govern/test: no such file or directory`). (#50 — unique)

**D. run-loop.sh escalation/circuit-breaker fix (from #12):**
- [ ] In the `red)` case of the merge-repo PR walk (~run-loop.sh:907-913), attach a `.escalation` object and set `status="parked"` (not `"failed"`) — matching the adjacent `unmergeable)`/`error)`/`external-blocked)` cases — so a PR still CI-red after the fix-worker retry gets a real `## Open` escalation entry instead of silently landing in `state.jsonl` as `failed`. This also fixes a second-order bug: the #60 consecutive-failure circuit breaker is only checked when `-z "$resumed"`, but a red-CI ticket always has an open PR to resume, so it currently bypasses the breaker entirely and would re-dispatch a fresh CI-fix worker indefinitely; parking removes it from selection via the existing escalation-exclusion path, so no separate fix to the `resumed` branch is needed. (#12 — unique)

**E. Subsumed / not carried forward (recorded, not duplicated):**
- #50's "atomic cross-driver exclude tracking" (per-driver in-memory `excludes` lets a killed ticket be re-selected by a sibling driver) — this is the identical root cause already owned by **#52** (High, hub `main` CI red since v1.11.1). Do not re-implement here; see #52.
- #38's diagnosis that the workspace `common.sh` lacks `govern::prose_dep_warnings`/the duplicate-title check — superseded; both are now present and byte-identical to the hub (see drift verdict above).

## Fix direction
Implement each unchecked item above as a normal harness PR, or explicitly decline it in the PR description if on closer inspection it isn't worth doing. This is **hub-first**: land every mechanism change in `shiploop/templates/govern/**` and let it flow down to this workspace via `/shiploop:update` — do not hand-edit `scripts/govern/**` in the same PR (the two copies are currently in sync; keep them that way through the sync channel, not a parallel edit).

Done when:
- [ ] `govern-improve-triage.sh` (hub + workspace, via sync) checks for an already-open "promote safe proposals" ticket before filing a new one, and appends instead of minting `## #N` — verified by filing two synthetic proposals and confirming only one ticket exists after both.
- [ ] `select-ticket.sh` logs a WARN when 2+ open tickets match `^Harness self-improvement: promote safe proposals`.
- [ ] `queue/tickets.md` documents `**Depends on:**` as a first-class field; `file-ticket.sh` supports `--depends-on N[,M...]`.
- [ ] Each remaining unchecked item in sections B–D above is either implemented (with a test under `templates/govern/test/`) or explicitly declined with reasoning in its PR description.
- [ ] `bash -n` passes on every touched script; hub and workspace copies remain byte-identical after landing (verified via `diff -r scripts/govern shiploop/templates/govern`).
- [ ] No new duplicate "promote safe proposals" ticket has been auto-filed since this lands (spot-check on the next few govern runs).

Ref: consolidation of #9, #10, #11, #12, #30, #36, #38 (evidence only, not deleted), #39, #42, #47, #50, #51, #53. See `git log --oneline --all | grep -iE "#33|#34"` for the #33/#34 resolution evidence (`ae36ed9`, `326aaca`).

---

## #63 — Worker timeout watchdog orphans a bare sleep process when spawn-worker.sh is killed via a pipe

**Severity:** Low
**Model:** sonnet
**Effort:** low

**Severity:** Low
**Model:** sonnet

Where: `scripts/govern/spawn-worker.sh` (the `GOVERN_WORKER_TIMEOUT` watchdog, ~lines 675-679) and its hub counterpart `shiploop/templates/govern/spawn-worker.sh`.

Observed: the worker timeout watchdog backgrounds a bare `sleep $to &`. When spawn-worker.sh is terminated via a plain pipe (rather than the SIGTERM path that runs `spawn_worker_cleanup`), that `sleep` is not reaped and survives as an orphan — a stray `sleep 3600` process left behind per spawn. Found incidentally while diagnosing PR #97's CI failures locally; it is PRE-EXISTING on `main` and unrelated to that PR's changes.

Impact: low but cumulative — a long governor run, or repeated local test invocations, accumulates orphaned `sleep` processes. Harmless individually; untidy at volume and can confuse process-tree assertions in orphan/teardown tests (which is how it surfaced).

Fix direction: record the watchdog's PID and kill it in `spawn_worker_cleanup` alongside `cpid`, and make the cleanup path cover pipe-termination as well as SIGTERM (trap on EXIT in addition to TERM/INT). Confirm against `test-orphan-teardown.sh`, which already asserts on orphan behaviour and is the natural place to add coverage.

Done when: terminating spawn-worker.sh by any path (SIGTERM, SIGINT, pipe close, normal exit) leaves no orphaned `sleep` watchdog; a test asserts it; `bash -n` clean; hub-first — fix lands in `shiploop/templates/govern/spawn-worker.sh` and flows down via `/shiploop:update`.

Ref: session 2026-07-26 — surfaced while diagnosing PR #97 CI failures; confirmed pre-existing on main, explicitly NOT caused by the `--exclude-dynamic-system-prompt-sections` probe.

---

## #64 — CI validates the plugin manifests but never cross-checks their version against VERSION — they silently drifted two releases behind

**Severity:** Medium
**Model:** sonnet
**Effort:** low

**Severity:** Medium
**Model:** sonnet

Where: `shiploop/.github/workflows/ci.yml` (job `validate-manifests`, ~lines 70-95); the files it must cross-check are `shiploop/VERSION`, `shiploop/.claude-plugin/plugin.json`, `shiploop/.claude-plugin/marketplace.json`, and `shiploop/CHANGELOG.md`.

Observed: `validate-manifests` checks only that the two manifests are valid JSON and that `plugin.json` has non-empty `name`/`version`. It never compares those versions against `VERSION` or against each other. As a result both manifests silently sat at `1.10.0` while `VERSION` and `CHANGELOG` advanced to `1.12.0` — two full releases of drift, published to the plugin marketplace, with CI green the whole time. Caught by hand while cutting v1.13.0 and fixed in that release, but nothing prevents an immediate recurrence on the next bump.

Impact: the marketplace advertises a stale version to every prospective user, and the drift is invisible to the only automated gate that looks at these files. This is the same class of defect as #44 (a release shipping a headline feature inert) — a Done-when that nothing verifies.

Fix direction: extend `validate-manifests` to assert `VERSION` == `plugin.json.version` == `marketplace.json.plugins[0].version`, and additionally that `CHANGELOG.md`'s top `## <version>` heading matches `VERSION`. Fail the job on mismatch. Keep it a pure text/JSON comparison so it needs no auth and stays fast.

Done when: CI fails on a PR that bumps `VERSION` without bumping both manifests; CI fails when the top CHANGELOG heading disagrees with `VERSION`; a green run proves all four agree at the current release; the check runs on every PR, not just release PRs.

Ref: session 2026-07-26 — found while cutting v1.13.0 (shiploop PR #98), which repaired the drift by hand. Related: the published v1.12.0 GitHub Release body also absorbed a stale `## Unreleased` CHANGELOG block, another symptom of release-time copy having no automated gate.

---

## #66 — file-ticket.sh header says retries escalate unconditionally, but resolve_sizing classifies them

**Severity:** Low
**Model:** haiku
**Effort:** low

**Severity:** Low
**Model:** haiku

Where: `shiploop/templates/govern/file-ticket.sh` (header comment, ~lines 23-30) and its workspace copy `scripts/govern/file-ticket.sh`.

Observed: the header documents `--model` as "pins the model the governor uses for THIS ticket's FIRST-attempt worker (any retry escalates to GOVERN_WORKER_MODEL unconditionally)", and repeats the same "retry-escalates-away" rule for `--effort`. That is stale. `spawn-worker.sh`'s `resolve_sizing` no longer escalates unconditionally: it calls `govern::retry_class` and branches, so an `infra` or `ci` failure retries at the SAME tier (logged as "retry class=... same tier, not escalated"), budget exhaustion raises the tier only, and a judgment failure raises tier and effort. `GOVERN_RETRY_CLASSIFY=0` reverts to the old always-escalate path.

Impact: low but real. This header is the reference an agent reads when filing a ticket with `--model`/`--effort`, so it teaches a wrong cost model: it implies any retry is guaranteed to cost top-tier, which discourages using a cheap first-attempt tier. It also already misled a doc pass, which propagated "retries escalate unconditionally" into the public README before the code was checked.

Fix direction: update both header comments to describe the classification (same tier for infra/CI, tier-only for budget, tier+effort for judgment, unconditional only when `GOVERN_RETRY_CLASSIFY=0`). While there, grep the rest of the tree for the same stale phrasing so no other doc repeats it.

Done when: no file in the hub or workspace claims retries escalate unconditionally without noting the classifier; the described behaviour matches `resolve_sizing`; hub-first, so the fix lands in `shiploop/templates/govern/file-ticket.sh` and flows down via `/shiploop:update`.

Ref: session 2026-07-26 — found while correcting the README's sizing claims (shiploop PR #103).

---
