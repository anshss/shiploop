# Known limits

Led by the least flattering true facts, per the operator's own instruction. If a number in
`README.md` or `METHODOLOGY.md` looks better than this file, this file is right and the number
needs another look.

## There is no published (6+ ticket) live backlog yet

`bench/backlogs/` holds only the test fixture. Building a real SWE-bench-shaped backlog (a merged
PR whose diff cleanly separates into a source fix and test-only changes, with the fail-to-pass
property holding at the pinned ref) is real curation work, not yet done, at the design's own
6-ticket usability bar (`bench/validate-backlog.sh --min-tickets`, default 6).

The one live run to date used a **2-ticket pilot backlog**, `bench/pilot-backlogs/shiploop-mini/`
(gitignored, never published), mined from two of shiploop's own past commits against shiploop's own
repo — a real fail-to-pass pair each, validated offline by `bench/validate-backlog.sh` before the
live run touched a single dollar. It is below the design's own bar for a *published* backlog and is
reported as a small pilot, not the full benchmark. A wider backlog (more tickets, ideally against an
external repo so shiploop is never grading its own commit messages) is the next real piece of work
here, not a nice-to-have.

## The offline guard closes git remotes, not the network

`bench::assert_offline` (bench/run.sh) strips every git remote from every clone and asserts none
survive before any arm spawns. That closes the two mechanisms this codebase's own scripts use to
reach a real repo (`git push` to a remote, `gh pr create`/`merge` inferring `--repo` from one). It
does **not** sandbox raw network syscalls issued from a worker's Bash tool: nothing here stops a
worker from running `curl` or `git clone` against a real host, or adding a brand-new remote and
pushing to it, if it chose to. The mitigations in place are all indirect — no working credential for
a real target exists in the spawned environment (GH_TOKEN/GITHUB_TOKEN/GH_ENTERPRISE_TOKEN/GH_HOST/
GH_REPO are scrubbed from every spawned session), the ticket text never names a real org/repo, and
neither arm gets a curated tool list any more that could have removed WebFetch/WebSearch — but none
of that is a kernel-level sandbox. A future tightening should run each arm in an actual network
namespace or firewalled container; this design does not.

A real `gh` CLI that is authenticated on the host is not made unreachable by anything here either:
`gh`'s auth is host-scoped, not workspace-scoped, so it could in principle answer a call naming a
real repo explicitly, from any cwd. The shiploop arm never lets the real `gh` execute at all — its
own directory shadows `gh` on PATH first (`bench::install_local_gh`) — so this risk is theoretical
for that arm specifically. The vanilla arm never calls `gh` at all in its expected flow (it commits
directly, no PR), so the same real-`gh`-on-PATH risk is likewise dormant there, not eliminated.

## The local `gh` shim is narrow by construction, and its bypasses are benchmark-only

`bench/local-gh.sh` implements exactly the `gh` surface this repo's shipped governor scripts call in
a single-repo, no-external-actor run: `pr create/list/checks/view/merge`, one `api` path, and a
no-op `pr update-branch`. Everything else exits 1. It works entirely off a flat JSONL ledger and
local git operations against one known repo directory — no push, no network, ever.

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
(it makes shiploop look slightly more expensive than a workspace with a real remote would), never in
its favor, and it is a benchmark-only artifact: a real installed workspace has a real remote and
this friction does not exist there.

## `await-ci`, if the session reaches for it, genuinely polls; it is not shortcut

If the with-shiploop session's own choice of dispatch reaches `resolve-ticket.sh` /
`await-ci.sh`, it does **not** set `GOVERN_SKIP_CI` (an internal optimization for a caller that
just confirmed green itself, not a top-level bypass). `await-ci.sh` really calls the local
`gh pr checks`/`gh pr view` twice, `GOVERN_CI_NONE_GRACE` seconds apart (default 6s), before it
verifies "checkless" and lets the merge proceed. That is real wall-clock seconds per ticket that a
genuinely CI-less installed workspace would also pay — it is not simulated away, and it is not free,
but it is honest: a repo with no CI provider configured gets the identical `none`-verified path in
production.

## Lever attribution counts occurrences; it does not price them

Section "Attribution inside the treatment arm" (`README.md`) reads `lever-events.jsonl` against an
explicit five-name allow-list, and separately counts a malformed line and an unrecognized event
name — never silently dropping either. It does **not** convert any of those counts into a token or
dollar credit: there is currently no live per-class token-estimate table anywhere in this
repository (a would-be constant for exactly that was calibrated on the wrong worker shape and was
deleted rather than carried forward unfixed — see `bench/LEVER-EVENTS.md`'s `scripted-action` entry).
A run with no `lever-events.jsonl` at all is reported as uninstrumented, never as a measured zero.

A live interactive session (the shape the with-shiploop arm's advisor and its worker subagents run
under) exports no `GOVERN_RUN_DIR` of its own for a mechanism it invokes outside `bench::arm_shiploop`'s
own scope, so an event like `watchdog-kill` from `templates/hooks/agent-watchdog-guard.sh`'s
PreToolUse hook can land in the flat, unscoped `logs/govern/lever-events.jsonl` rather than the
run-scoped file bench reads. Where that happens, the count is real but cannot be attached to one
cell without guessing which — guessing (newest run, only run, nearest timestamp) would attach a real
event to an arbitrary arm, so a correct reader discloses it uncredited to any arm rather than
guessing.

## The idle-progress alarm is a named exclusion, not an unmeasured lever

`templates/hooks/agent-progress-guard.sh` raises `agent_progress_alarm` on the fleet event log. It
is deliberately NOT a lever event and this design credits it nothing, which is a decision and not a
gap. A lever this design would credit must REMOVE tokens from the counterfactual, and this one
removes none: the `TeammateIdle` branch cannot block by construction (there is no stop to hold
open), so it terminates nothing and truncates nothing, and the `SubagentStop` branch blocks a stop,
which makes the child work LONGER, not shorter. Crediting it would be crediting an observation as a
saving. Locked by case 14 of `templates/govern/test/test-agent-progress-guard.sh` and recorded in
the deliberate-exclusions section of `bench/LEVER-EVENTS.md`.

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
past the pinned `ref` — true for the pilot, since it was mined from shiploop's own history — one of
those refs can point at the exact commit the ticket was mined from, or a release tag cut after it.
`git log --all` / `git branch -a` / `git tag` then lists it, and `git show <sha>` prints the real fix
verbatim. This was FOUND live, mid-run, by inspecting what a worker actually ran. `bench::prepare_workdir`
now deletes every ref except `refs/heads/main`, expires the reflog, and runs `git gc --prune=now`
immediately after checkout — verified by hand: `git cat-file -e <the-real-fix-sha>` fails afterward.
**Any backlog mined from a repo that is not fully static (most real ones) should assume this was a
live risk until this fix, and should re-audit their own clone step if they predate it.**

## The pilot's own ticket bodies are more prescriptive than a real issue report

Both pilot tickets' bodies were written by summarizing the real commit message that fixed them,
which — because a commit message explains its own fix — ended up describing the SHAPE of the
correct change rather than only the symptom. A real upstream issue report is usually more naive than
a post-hoc commit message. This does not hand over test names or exact code (the golden-test-patch
oracle still applies at verify time only), but it likely makes both arms' job easier than a
genuinely blind bug report would, in a way that is NOT quantified here. Treat the pilot's absolute
success rate as upper-bound-flattering for this reason, independent of anything else in this file.

## The honest live run: both arms scored 0/2 on the mechanical oracle

The live A/B run (`bench/pilot-backlogs/shiploop-mini`, 2 tickets, model default, git-leak fix
applied) finished with **neither arm clearing either ticket** by `verify_cmd` + the golden
`test_patch`:

- **flows-grammar**: both arms wrote a real fix; both arms' own test additions conflict with the
  golden patch's exact context lines, so `git apply` fails (sentinel 90) for both — the documented,
  intended behavior when an arm edits a file the patch also touches, not a harness bug. A
  source-level read of the shiploop arm's merged fix shows it implements the same mechanism the real
  historical fix did; the exact wording of its own added test cases differs enough to break a
  byte-exact patch apply.
- **validation-gate**: the shiploop arm's worker was PARKED before it could merge anything. This
  ticket's own body — which explains a validation-gate recognizer bug by quoting the exact trigger
  phrases as an illustrative example — tripped the CURRENT (pre-fix) validation gate on the ticket
  text itself: the harness refused to auto-resolve because "the worker gave no live-test evidence."
  A real, if unintended, demonstration that the gate does substring-match on ticket text, and it
  makes this specific ticket unusable for a clean pass/fail measurement. A backlog ticket about the
  validation gate should never quote a validation-triggering phrase in its own body.

Because neither arm cleared either ticket, **no resolution-rate or token/cost REDUCTION percentage
can be honestly reported from this run**: a reduction is only meaningful between two arms that did
comparable work to a comparable (successful) end.

The raw spend each arm put into those two tickets was recorded, and it is **not published** either.
The direction is: the harness arm spent MORE tokens than the single long session, and less money —
the latter confounded by the arms not being on the same model (next section). The magnitudes are
withheld for the same reason every favourable magnitude in this directory is withheld: nothing in
the current corpus is instrumented well enough to quote, and a figure is either publishable or it is
not, whichever way it points.

**Read that as the deliberate symmetry it is.** Adverse results are described here in words rather
than deleted, so the absence of bad numbers is never mistakable for the absence of bad results. The
bad result stands on the record: both arms failed the oracle, and on tokens the harness lost.

## The honest run's arms were not on the same model, contrary to the design's own requirement

`bench::arm_shiploop` never set `GOVERN_WORKER_MODEL` in the run that produced this result, so the
governor's own per-ticket model sizing chose the model for each worker (observed: sonnet for one
ticket, opus for the other). The vanilla arm's single session ran on `claude -p`'s own default,
observed as opus throughout. The resulting cost comparison therefore partially reflected a
MODEL-CHOICE difference (shiploop's own cheap-tier dispatch feature, which is real product
behavior) tangled with the architecture difference the run was meant to isolate. This is not a bug
to fix by equalizing tiers — the rebuilt design's own rail is the opposite: let the control run on
the operator's own tier and let the treatment route freely, and always name which tier each arm
ran on in the report, so a reader can see this confound rather than have it hidden by forced
equality.

## Run scope: `GOVERN_RUN_DIR` is set by the arm, nothing is stamped for a modeling tool any more

`bench::arm_shiploop` still mints its own per-arm run directory and exports `GOVERN_RUN_DIR` before
spawning, so `lever-events.jsonl` lands somewhere the attribution reader can find it. It no longer
calls a version- or driver-model-stamping function on that directory: the two stamps that mechanism
used to write (`shiploop-version`, `driver-model`) existed to feed a corpus-modeling reader, and this
design's own reader gets the model directly off the session's `result` event and forwarded subagent
messages instead of a sibling stamp file. `govern::stamp_run_version` / `govern::stamp_driver_model`
(`templates/govern/lib/common.sh`) themselves are unchanged and still called from
`spawn-worker.sh`'s own dispatch path — they are a general governor mechanism, not bench's to
retire, and whether they still have a live consumer outside bench is tracked separately.
