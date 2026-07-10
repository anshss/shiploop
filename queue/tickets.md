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

## #1 — Example ticket (delete me)

**Severity:** Low
**Model:** sonnet
**Where:** `path/to/file.ts` (which sub-repo / area)
**Observed:** What's wrong or missing, concretely.
**Fix direction:** The intended approach (not a full design).
**Done when:** The acceptance check that closes this.
**Ref:** Link to a log line / PR / investigation, if any.

---

## #3 — flows lint parses flow blocks inside HTML comments — false-positive Stop-hook block + in-comment mutation

**Severity:** Medium
**Model:** sonnet

Where: scripts/govern/lib/flows.sh — govern::flow_ids / govern::flow_block / govern::flow_set_field

Observed: the flow block parser matches '^## <id>' headings with no multi-line HTML-comment awareness. The scaffolded validation/flows.md carried two commented-out example flows (<!-- ... ## deploy.example ... -->); the lint parsed them as real flows, their placeholder backend/** globs tripped the zero-match FAIL, flow_set_field auto-degraded Status→STALE INSIDE the comment blocks (dirtying the file), and the Stop hook (ticket-sweep-reminder.sh) blocked every session end — mislabeling the flows-lint output as a missing-evidence-summary (#252) error. Workaround applied: examples removed from flows.md (commit e466250).

Done when: (1) the parser tracks <!-- --> comment state and skips headings/fields inside comment blocks, matching the grammar's 'comments are decoration' contract; (2) a regression test covers a registry whose only flows are comment-wrapped examples (lint must pass, file must stay unmutated); (3) the Stop hook reason distinguishes flows-lint failures from dangling-evidence-ref failures instead of wrapping both in the #252 message. Fix belongs in the hub templates too (templates/govern/lib/flows.sh) — port via the sync flow.

---
