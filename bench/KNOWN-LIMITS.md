# Known limits

Led by the least flattering true facts, per the operator's instruction on ticket #104. If a number
in `README.md` or `METHODOLOGY.md` looks better than this file, this file is right and the number
needs another look.

## There is no published (6+ ticket) live backlog yet

`bench/backlogs/` holds only the test fixture. Building a real SWE-bench-shaped backlog (a merged
PR whose diff cleanly separates into a source fix and test-only changes, with the fail-to-pass
property holding at the pinned ref) is real curation work that this ticket did not have time to do
at the design's own 6-ticket usability bar (`bench/validate-backlog.sh --min-tickets`, default 6).

The honest live run this ticket produced used a **2-ticket pilot backlog**,
`bench/pilot-backlogs/shiploop-mini/` (gitignored, never published), mined from two of shiploop's
own past commits against shiploop's own repo — a real fail-to-pass pair each, validated offline by
`bench/validate-backlog.sh` before the live run touched a single dollar. It is below the design's
own bar for a *published* backlog and is reported as a small pilot, not the full benchmark. A wider
backlog (more tickets, ideally against an external repo so shiploop is never grading its own commit
messages) is the next real piece of work here, not a nice-to-have.

## The offline guard closes git remotes, not the network

`bench::assert_offline` (bench/run.sh) strips every git remote from every clone and asserts none
survive before any arm spawns. That closes the two mechanisms this codebase's own scripts use to
reach a real repo (`git push` to a remote, `gh pr create`/`merge` inferring `--repo` from one). It
does **not** sandbox raw network syscalls issued from a worker's Bash tool: nothing here stops a
worker from running `curl` or `git clone` against a real host, or adding a brand-new remote and
pushing to it, if it chose to. The mitigations in place are all indirect — no working credential for
a real target exists in the spawned environment (GH_TOKEN/GITHUB_TOKEN/GH_ENTERPRISE_TOKEN/GH_HOST/
GH_REPO are scrubbed from every spawned session), the tool list excludes WebFetch/WebSearch, and the
ticket text never names a real org/repo — but none of that is a kernel-level sandbox. A future
tightening should run each arm in an actual network namespace or firewalled container; this run does
not.

A real `gh` CLI that is authenticated on the host is not made unreachable by anything here either:
`gh`'s auth is host-scoped, not workspace-scoped, so it could in principle answer a call naming a
real repo explicitly, from any cwd. The shiploop arm never lets the real `gh` execute at all — its
own directory shadows `gh` on PATH first (`bench::install_local_gh`) — so this risk is theoretical
for that arm specifically. The vanilla arm never calls `gh` at all in its expected flow (it commits
directly, no PR), so the same real-`gh`-on-PATH risk is likewise dormant there, not eliminated.

## The local `gh` shim is narrow by construction, and its bypasses are benchmark-only

`bench/local-gh.sh` implements exactly the `gh` surface this repo's shipped governor scripts call in
a single-repo, `--serial`, no-external-actor run: `pr create/list/checks/view/merge`, one `api`
path, and a no-op `pr update-branch`. Everything else exits 1. It works entirely off a flat JSONL
ledger and local git operations against one known repo directory — no push, no network, ever.

To keep that surface small, `bench::arm_shiploop` sets three things that are real safety mechanisms
in production and are **only** safe to skip here because the offline guard makes them structurally
moot:

- `_GOVERN_ASSUME_MERGE_ALLOWED=1` skips the external-author/fork/branch-pattern auto-merge guard.
  Safe here because zero remotes means an external actor cannot exist. **Never** set this outside a
  guaranteed-zero-remote sandbox.
- `GOVERN_PR_TICKET_REF=1` skips the ticket-id scrub on the (pre-seeded, always-private) bench repo.
- A pre-seeded `governor/.repo-visibility` cache marks the repo private so `govern::repo_is_public`
  never calls `gh repo view` — which the shim does not implement (`gh repo view` always exits 1).

If bench ever grows a mode where the scaffolded workspace is allowed a real remote (e.g. to test the
merge-guard itself), these three knobs must be re-examined together, not left on by inertia.

## A worker may still try `git push` and waste a few turns

The scaffolded workspace's CLAUDE.md gets one appended line saying not to `git push` (there is
nowhere to push to). Nothing enforces that a worker reads and follows it. If it tries anyway, the
push fails immediately and harmlessly (no remote configured) and the worker moves on — at the cost
of a small number of wasted turns/tokens. This is a bias **against** the shiploop arm's own number
in the live run (it makes shiploop look slightly more expensive than a workspace with a real remote
would), never in its favor, and it is a benchmark-only artifact: a real installed workspace has a
real remote and this friction does not exist there.

## `await-ci` genuinely polls; it is not shortcut

The shiploop arm does **not** set `GOVERN_SKIP_CI` (that knob is `run-loop.sh`'s own internal
optimization when it just confirmed green itself — not a top-level bypass). `await-ci.sh` really
calls the local `gh pr checks`/`gh pr view` twice, `GOVERN_CI_NONE_GRACE` seconds apart (default 6s),
before it verifies "checkless" and lets the merge proceed. That is ~12-18 real wall-clock seconds
per ticket that a genuinely CI-less installed workspace would also pay — it is not simulated away,
and it is not free, but it is honest: a repo with no CI provider configured gets the identical
`none`-verified path in production.

## A mixed-model session biases the COST figure (not the token one) slightly in shiploop's favor

`bench/replay.mjs` prices the measured ship-side cost and the modeled vanilla-side overhead/credit
at different granularities. `sessionCost()` (`replay.mjs:282-317`) prices a session's real cost per
model, walking `sess.modelUsage` and applying each model's own tier rate to its own tokens: a
session that escalated from a cheaper model to a pricier one is billed at the accurate blend.
`dominantTier()` (`replay.mjs:330-345`) instead resolves ONE tier for the WHOLE session (the model
with the largest token volume) and that single tier's rate prices ALL of that session's modeled
overhead-read and re-prime-credit (`replay.mjs:482-484`, consumed at lines 491-492 and 499-501).

A session's later, heavier-context turns tend to carry the largest accumulated cache-read volume,
which tends to pull `dominantTier` toward whichever model handled those later turns. When that is
the pricier escalated tier, the entire session's modeled overhead is priced at the pricier rate,
including turns that were actually run on a cheaper model earlier in the same session. That inflates
the modeled vanilla cost, which biased the COST reduction slightly in shiploop's favor.

**This did not touch the TOKEN reduction.** The token path (`vanTokens = shipTokens +
overheadTokens - creditTokens`) sums raw token counts and never multiplies by a rate, mixed-model or
otherwise, so it is immune to this by construction. Full mechanism and the "Flatters shiploop"
classification: `bench/METHODOLOGY.md`. A cost reduction must never be quoted with the same
confidence as a token reduction; `README.md`'s "Tokens vs. cost" section states why.

**FIXED 2026-09-08 (#108).** `dominantTier()` is removed. The modeled side is now priced at the
session's own input-side token mix blended across the tiers that actually ran it
(`sessionInputRate()`), so the whole-session single-tier rounding described above no longer happens.
For a single-model session the two rules agree to the cent, which is why the frozen fixtures and the
published rows reproduce unchanged. What survives from this entry is the weaker claim, and it still
stands: a cost figure depends on the rate table and on the corpus's model mix, and a token figure
does not. Never quote a cost reduction with the same confidence as a token reduction.

## The headline is a composite of several counterfactuals, not one session

Since #108 the reported saving sums per-lever components, and those levers do not all share one
counterfactual. Carry and routing are measured against "one accumulating session on the driver's
tier", which is the arm's stated definition. Cache-prefix, watchdog, resume and skip-the-model are
measured against "the same harness WITHOUT that lever": a single session would never have spawned a
second worker, so it would not have paid the cache write the prefix lever credits, nor the restart
the resume lever credits.

This is deliberate (the levers exist and their spend is real) and it is the design the multi-lever
spec asked for, but it means the headline is **the harness's total avoided spend**, not a strict
one-session A/B. The strict one-session comparison is still computed and still printed on every arm
as `coreModel` / "carry-only legacy model". When a reader wants the conservative apples-to-apples
figure, that is the one, and it is always lower.

## Four levers are credited only where the corpus carries instrumentation

`watchdog`, `resume-not-restart`, `skip-the-model` and `escalation-correction` are read from
`logs/govern/<run>/lever-events.jsonl` (contract: `bench/LEVER-EVENTS.md`). Runs dispatched before
that file existed carry none, and the emitter ships **default OFF** (`GOVERN_LEVER_EVENTS=0`), so
on any corpus in existence today those four levers report `uninstrumented` and contribute nothing. That is an understatement of the harness, not a measurement that it saves
nothing there, and the report prints the coverage count next to every one of them. A corpus mixing
instrumented and uninstrumented runs reports a number weighted toward the uninstrumented ones,
because the levers can only be credited where the events exist.

`output-suppression` is weaker still: it has no event in the wire contract at all, and the bytes it
withholds are by construction absent from every transcript. It is listed in the lever table with a
zero and the reason, so it can never be mistaken for a measured zero.

## Two instrumented levers are under-counted on purpose, and one is partial

`resume-not-restart` credits only context reconstruction (the failed attempt's input plus cache
creation, output excluded), because a retry redoes the work either way and only the re-reading is
avoided. `skip-the-model` credits only a worker's first-turn context (45,000 tokens, the rounded-
down 25th percentile of 502 observed first turns), not the whole session a deterministic apply
actually replaced. Both understate. `escalation-correction` fires only where a retry changed tier,
not on infra or CI retries at the same tier, so it corrects some wasted cheap-tier spend and not
all of it. None of the three is a measurement of the lever's true size; each is a bound in the
direction that does not flatter shiploop, except the escalation one, which is a correction that
does not go far enough and therefore leaves a little credit in place that a fuller model would
remove.

## The harness-overhead charge is bounded by what the corpus recorded

Spec section 4a charges orchestration-side transcripts into the shiploop arm, which is the fix for
METHODOLOGY's old "largest known bias". It can only charge what exists. On a corpus where the
governor wrote no transcript of its own model calls, every run is `overhead-uncovered`, the charge
is zero, and the shiploop arm's cost is a stated LOWER bound rather than a measurement. The report
prints the covered/uncovered split for exactly this reason. The interactive session that dispatched
the run is not counted by this path and never will be: it writes no transcript into `logs/govern`.

## The replay ("best-case") number's corpus is thin for the current version

No transcript event carries the shiploop *package* version — only the Claude Code CLI version
(`claude_code_version` on the session's `init` event) and the model. The package version instead
comes from a sibling file next to the transcript: `run-loop.sh` stamps every run directory it
creates with `run-.../shiploop-version`, the workspace's synced hub version, at dispatch time
(`govern::stamp_run_version`, `templates/govern/lib/common.sh`). The write is best-effort — an
unreadable or absent version marker never blocks a dispatch, it just leaves that run unstamped.

`bench/replay.mjs` uses the stamp to scope its default corpus: it keeps only the runs stamped with
the newest version present, reports how many runs and sessions that kept versus excluded (split
into older-stamped and unstamped-legacy, since those are different situations), and prints which
version it selected. `--all` restores the full, unscoped sweep across every version a workspace has
ever run; `--since` is the older, coarser proxy this replaces for a version-scoped read (filtering
by each run directory's own `run-YYYYMMDD-HHMMSS-<pid>` timestamp against a caller-supplied cutoff,
in practice a release commit timestamp) and still composes with either mode.

This does not retroactively version-tag history: a run from before the stamp shipped, or a
workspace whose `scaffold.sh` never wrote a version marker, has no `shiploop-version` file and is
counted as unstamped-legacy, reachable only via `--all`. If NOTHING in a corpus is stamped (a pure
pre-stamp workspace), there is no "newest version" to select, so the default falls back to the full
sweep automatically and says so, rather than reporting a phantom zero-run corpus. See `README.md`
for the exact cutoff, session count, and date range behind the published figure, itself entirely
unstamped history predating this mechanism.

## Golden-test-patch quality is bounded by whoever mines the backlog

`bench/validate-backlog.sh` proves the mechanical fail-to-pass property (patch applies at `ref`,
`verify_cmd` fails there, the test is present and passes at `merge_sha`). It cannot prove that
`test_patch` is semantically test-only in intent, only that the diff it was handed touches only
files the backlog author selected. A careless backlog author could still hand-pick a "test" file
that happens to also carry a source change if they generated the split by hand instead of by path
filter. Every backlog in this repo so far (the fixture, and the mined pilot) built `test_patch` by
filtering the real merged diff to test-file paths only, which is mechanical and auditable, but the
mechanism does not stop a differently-authored backlog from getting this wrong.

## A local-path clone leaked the answer, and it was caught mid-run

`bench::prepare_workdir`'s `git clone` of a LOCAL path (the common case when a backlog is mined
from a repo already on the machine, as the pilot backlog here is) brings every other ref along:
branches, remote-tracking branches, AND tags. If the source repo is still under active development
past the pinned `ref` — true for this pilot, since it was mined from shiploop's own history — one
of those refs can point at the exact commit the ticket was mined from, or a release tag cut after
it. `git log --all` / `git branch -a` / `git tag` then lists it, and `git show <sha>` prints the
real fix verbatim. This was FOUND live, mid-run, by inspecting what a worker actually ran (it used
`git grep`/`git show` on unrelated hashes, not the leaking one, in the run this shipped with — but
the exposure was real and the fix landed before the published honest number was measured, not
after). `bench::prepare_workdir` now deletes every ref except `refs/heads/main`, expires the
reflog, and runs `git gc --prune=now` immediately after checkout — verified by hand: `git cat-file
-e <the-real-fix-sha>` fails afterward. **Any backlog mined from a repo that is not fully static
(most real ones) should assume this was a live risk until this fix, and should re-audit their own
clone step if they predate it.**

## The pilot's own ticket bodies are more prescriptive than a real issue report

Both pilot tickets' bodies were written by summarizing the real commit message that fixed them,
which — because a commit message explains its own fix — ended up describing the SHAPE of the
correct change (e.g. "add coverage for the id-charset and status-enum checks, including a negative
case") rather than only the symptom. A real upstream issue report is usually more naive than a
post-hoc commit message. This does not hand over test names or exact code (the golden-test-patch
oracle still applies at verify time only), but it likely makes both arms' job easier than a
genuinely blind bug report would, in a way that is NOT quantified here. Treat the pilot's absolute
success rate as upper-bound-flattering for this reason, independent of anything else in this file.

## The honest live run: both arms scored 0/2 on the mechanical oracle

The live A/B run (`bench/pilot-backlogs/shiploop-mini`, 2 tickets, model default, git-leak fix
applied) finished with **neither arm clearing either ticket** by `verify_cmd` + the golden
`test_patch`:

- **flows-grammar**: both arms wrote a real fix; both arms' own test additions to
  `test-flows-lint.sh`/`test-flows-parser.sh` conflict with the golden patch's exact context lines,
  so `git apply` fails (sentinel 90) for both — the documented, intended behavior when an arm edits
  a file the patch also touches, not a harness bug. A source-level read of the shiploop arm's merged
  fix shows it implements the same mechanism the real historical fix did; the exact wording of its
  own added test cases differs enough to break a byte-exact patch apply.
- **validation-gate**: the shiploop arm's worker was PARKED before it could merge anything.
  Ironically, **this ticket's own body — which explains the validation-gate recognizer bug by
  quoting the exact trigger phrases as an illustrative example ("Done when: a PASS/FAIL table from
  an actual run against the sandbox")** — tripped the CURRENT (pre-fix) validation gate on the
  ticket text itself: `run-loop.sh` refused to auto-resolve because "the worker gave no live-test
  evidence." This is a real, if unintended, demonstration that the existing gate does substring-
  match on ticket text, but it makes this specific ticket unusable for a clean pass/fail bench
  measurement. A backlog ticket about the validation gate should never quote a validation-triggering
  phrase in its own body.

Because neither arm cleared either ticket, **no resolution-rate or token/cost REDUCTION percentage
can be honestly reported from this run** — a reduction is only meaningful between two arms that did
comparable work to a comparable (successful) end. What IS reportable, and is reported in
`README.md`, is the raw token/cost SPEND each arm put into the same two tickets before both came up
short — a cost comparison on unresolved work, not a savings claim.

## The honest run's arms were not on the same model, contrary to the ticket's own requirement

`bench::arm_shiploop` never sets `GOVERN_WORKER_MODEL`, so the governor's own per-ticket model
sizing chose the model for each worker (observed: sonnet for one ticket, opus for the other). The
vanilla arm's single session ran on `claude -p`'s own default, observed as opus throughout. The
resulting cost comparison therefore partially reflects a MODEL-CHOICE difference (shiploop's
own cheap-tier dispatch feature, which is real product behavior) tangled with the architecture
difference the run was meant to isolate. Pin `GOVERN_WORKER_MODEL` to match the vanilla arm's
observed default before trusting a future run's cost delta as an apples-to-apples number.

## Small "ticket" fragments neither dispatched ticket ever named

Every real `run-loop.sh` invocation observed during this ticket's live runs wrote a handful of
tiny (single-digit-KB, near-zero-token) `ticket-5`, `ticket-7`, `ticket-8`, `ticket-9` (and, on a
resume, `ticket-301`/`ticket-401`) directories under `logs/govern/run-*/` with attempt-log-shaped
JSON, for ticket numbers never named in `--serial`. They were traced far enough to confirm they are
NOT test-suite contamination (no such content exists anywhere in `templates/govern/test/`) and
contribute negligible tokens (~150 each) and null cost, so they do not materially affect the numbers
here — but their exact source inside the governor (a self-check the dispatcher runs at startup is
the leading guess) was not identified before this ticket's time ran out. Filed as a new ticket
rather than solved here.
