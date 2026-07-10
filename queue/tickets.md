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

## #3 — flows lint parses flow blocks inside HTML comments — false-positive Stop-hook block + in-comment mutation

**Severity:** Medium
**Model:** sonnet

Where: scripts/govern/lib/flows.sh — govern::flow_ids / govern::flow_block / govern::flow_set_field

Observed: the flow block parser matches '^## <id>' headings with no multi-line HTML-comment awareness. The scaffolded validation/flows.md carried two commented-out example flows (<!-- ... ## deploy.example ... -->); the lint parsed them as real flows, their placeholder backend/** globs tripped the zero-match FAIL, flow_set_field auto-degraded Status→STALE INSIDE the comment blocks (dirtying the file), and the Stop hook (ticket-sweep-reminder.sh) blocked every session end — mislabeling the flows-lint output as a missing-evidence-summary (#252) error. Workaround applied: examples removed from flows.md (commit e466250).

Done when: (1) the parser tracks <!-- --> comment state and skips headings/fields inside comment blocks, matching the grammar's 'comments are decoration' contract; (2) a regression test covers a registry whose only flows are comment-wrapped examples (lint must pass, file must stay unmutated); (3) the Stop hook reason distinguishes flows-lint failures from dangling-evidence-ref failures instead of wrapping both in the #252 message. Fix belongs in the hub templates too (templates/govern/lib/flows.sh) — port via the sync flow.

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

## #5 — Hub: durable validation runner — core launcher + job substrate templates (spec §1–§3)

**Severity:** High
**Model:** opus

Where: shiploop/ sub-repo (anshss/shiploop) — templates/govern/run-validation.sh (NEW) + templates/govern/lib/valjob.sh (NEW) + scaffold component wiring + templates/govern/test/

Observed: spec ACCEPTED (hub-first) — read it from /Users/anshs/Folder/code/aquanode/.specs/2026-07-08-harness-durable-validation-runner-design.md (absolute path; gitignored there, NOT in any worktree). Long billable validations have no durable, orphan-proof launcher anywhere in the fleet; trap-only cleanup leaked live boxes 3x during aquanode #343.

Fix direction — implement spec §1–§3 job side exactly, as HUB TEMPLATES (generic, zero workspace-specific logic):
- §1 launcher: setsid-detached launch of a flow validation script; job-id val-<flowid>-<ts>; job dir logs/govern/validations/<job>/; export VAL_JOB_ID for deploy name-tagging val-<jobid>-<label>; return job-id immediately, non-blocking; GOVERN_VAL_TIMEOUT wall cap (generous, hours) — on expiry kill the job process group + write terminal ERROR; retention pruning of terminal job dirs (keep last N or ~14d).
- §2 job side: manifest deploys.jsonl — one line (id + provider) appended BEFORE provisioning; runner-owned heartbeat wrapper (~30s while the script pgid is alive — heartbeat = process liveness, NOT script cooperation); expose the deterministic orphan verdict (heartbeat >~3min stale OR terminal record OR sticky tombstone) as data for GOVERN_DEPLOY_SWEEP_CMD — the hub NEVER closes boxes itself.
- §3: status.jsonl schema {phase, deploys, verdict, evidence}; tombstone-check helper called at each phase boundary — tombstone present → terminal ABORT, touch nothing; terminal record PASS|FAIL|ABORT|ERROR.
- Wire new template files into scaffold.sh's component map so /shiploop:setup and /shiploop:update distribute them.
- These file formats are the INTERFACE CONTRACT for sibling tickets (delivery, stamping) — implement per spec, do not invent different names/paths.

Done when: bash -n clean; a templates/govern/test/test-valjob.sh (bash 3.2-safe, like siblings) proves with a fake flow script: (1) job survives parent exit; (2) manifest line precedes the mock provision; (3) heartbeat stops within ~60s of pgid SIGKILL; (4) GOVERN_VAL_TIMEOUT kill writes terminal ERROR; (5) a pre-placed tombstone at a boundary yields terminal ABORT with zero side effects; scaffold component map ships the new files; PR opened on anshss/shiploop.

Ref: spec §1–§3 (absolute path above)

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
