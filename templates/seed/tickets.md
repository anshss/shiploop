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
promote any durable lesson to `CLAUDE.md` — only if settled, not already recorded, and statable in
≤3 lines; otherwise it belongs in `CLAUDE-APPENDIX.md`. Use `/resolve <N>` to do this the disciplined way.

The governor reads this file: severity-orders the open tickets (High > Medium > Low > unknown), works
the top one, then deletes it on resolve. Keep entries in the shape below so the parser finds them.

---

### Optional per-ticket fields

- **`Flow:`** — tag this ticket as a flow-registry validation (`--flow <id[,id…]>`); the worker gets
  the flow block(s) injected and bookkeeping stamps the registry on resolve.

> **There is no `Model:` / `Effort:` field.** Worker sizing is a MEASUREMENT, not something you
> declare at filing time. A cheap read-only scout pass greps the real code before dispatch and its
> verdict picks the tier — it knows how many files the fix touches, whether tests cover the area, and
> whether there is a precedent commit, none of which you know while writing the ticket. Entries in
> older queues still carrying these fields are inert; they are not an error, they just do nothing.
> (`GOVERN_MEASURED_SIZING=0` restores the old field-wins precedence if a fleet needs it.)

---

## #1 — Example ticket (delete me)

**Severity:** Low
**Where:** `path/to/file.ts` (which sub-repo / area)
**Observed:** What's wrong or missing, concretely.
**Fix direction:** The intended approach (not a full design).
**Done when:** The acceptance check that closes this.
**Ref:** Link to a log line / PR / investigation, if any.

---
