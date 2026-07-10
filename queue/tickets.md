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

## #6 — Hub: durable validation runner — pending-results delivery + live-jobs surface templates (spec §4)

**Severity:** Medium
**Model:** sonnet

Where: shiploop/ sub-repo (anshss/shiploop) — templates/govern/ NEW pending-results emit/apply (reuse the escalations-emit-pending.sh atomic tmp+mv pattern) + small integrations: govern-supervise.sh pass, SessionStart hook template, a flows-status/govern-validations live-jobs listing + scaffold component wiring

Observed: spec ACCEPTED (hub-first) — /Users/anshs/Folder/code/aquanode/.specs/2026-07-08-harness-durable-validation-runner-design.md §4 (absolute path; NOT in any worktree). A validation finishing with no governor active lands in silence; supervisor-only adoption is insufficient.

Fix direction — spec §4 exactly, generic hub templates: on a terminal record in a job's status.jsonl, append a pending-result entry; three readers apply — (1) governor supervisor next pass, (2) SessionStart hook surfaces unadopted results, (3) flows status / govern validations on demand. Apply = evidence-stamp on PASS, escalation entry on FAIL/ABORT, then mark consumed. Consumption serialized under the bookkeep mutex — racing readers never double-stamp/double-escalate. Live-jobs surface lists job-id, phase, deploy-ids, heartbeat age.

Interface contract: job dir logs/govern/validations/<job>/, status.jsonl, heartbeat per spec §1–§3 — OWNED by sibling ticket #5 (core); consume the spec formats, do NOT edit #5's files; use a fixture job dir in tests.

Done when: templates/govern/test/ fixture proves: pending entry emitted atomically for terminal PASS and FAIL; each reader applies + marks consumed exactly once under the mutex (two-reader race test); live listing shows phase + heartbeat age; scaffold component map ships the files; bash -n clean; PR opened on anshss/shiploop.

Ref: spec §4; siblings #5 (core), #6-ish (stamping), workspace ticket #3 (parser fix)

---

## #7 — Hub: durable validation runner — registry stamping via cas_edit + evidence promotion templates (spec §5)

**Severity:** Medium
**Model:** sonnet

Where: shiploop/ sub-repo (anshss/shiploop) — templates/govern/lib/flows.sh (extend govern::flows_stamp) + evidence write path validation/evidence/ + scaffold component wiring

Observed: spec ACCEPTED (hub-first) — /Users/anshs/Folder/code/aquanode/.specs/2026-07-08-harness-durable-validation-runner-design.md §5 (absolute path; NOT in any worktree). The durable runner needs deterministic registry stamping on terminal PASS/FAIL.

Fix direction — spec §5 exactly, generic hub templates:
- On terminal PASS/FAIL, stamp validation/flows.md for the flow id: Status, Validated (repo@sha pins), Evidence pointer, Env — via govern::cas_edit UNDER the bookkeep mutex (the runner and a concurrent governor are two independent writers). Reuse/extend govern::flows_stamp.
- Durable summary → validation/evidence/<flow-id>.md (git-tracked tier-2 sink). NEVER write .claude/context/validation/ (legacy path).
- DEPENDENCY: workspace ticket #3 (flow-block parser comment-blindness) is being fixed in parallel by another worker in the same templates/govern/lib/flows.sh file — keep your diff surgical (flows_stamp + evidence write only), rebase on conflict, do NOT fix the parser yourself.

Done when: stamping a fixture flow id updates exactly its block via cas_edit under the mutex; evidence file written to validation/evidence/; templates/govern/test/ regression covers a stamp racing a concurrent registry edit (CAS retry path); scaffold component map ships anything new; bash -n clean; PR opened on anshss/shiploop.

Ref: spec §5; siblings #5 (core — owns status.jsonl), #6 (delivery — calls this stamp on apply), #3 (parser fix, same file — merge-order note in both PRs)

---
