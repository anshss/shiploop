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
≤3 lines; otherwise it belongs in `CLAUDE-APPENDIX.md`. Then sweep the session diff for gaps the fix
uncovered — fold them into open tickets by default, minting a new number only for work that is
independently dispatchable.

The governor reads this file when you DISPATCH a ticket by number
(`pre-dispatch-check.sh` → `dispatch-packet.sh` → a worker → `resolve-ticket.sh`, or just say "work
on 42"), and deletes the entry on resolve. Nothing is selected for you: there is no backlog sweep.
Naming several as one comma-joined PLAN (`pre-dispatch-check.sh 12,14`) sends them to ONE worker as a
group, gated mechanically (dependency, sub-repo, size, precision; see `governor/README.md`'s
"Batching" section); a bare number dispatches one worker on one ticket. Keep entries in the shape below
so the parser finds them.

---

### Optional per-ticket fields

- **`Flow:`** — tag this ticket as a flow-registry validation (`--flow <id[,id…]>`); the worker gets
  the flow block(s) injected and bookkeeping stamps the registry on resolve.
- **`Fix-Files-Contain:`** — comma-separated `<repo>:<fixed-string>` fingerprints that will exist on
  trunk only once this ticket's fix lands (`repo` = sub-repo folder under the meta root, `.` = the
  meta repo itself; pick a distinctive function name, string, or constant the fix introduces).
  Pre-dispatch greps these against the trunk when the block is already gone from origin/main, so a
  landed ticket skips as resolved while an unimplemented one prints an explicit resolved-unverified
  line instead of being silently dropped. Omit it when the fix has no greppable signature.

> **There is no `Model:` / `Effort:` field.** Model choice is made at dispatch, not at filing time:
> the advisor runs `npm run govern:dispatch -- <N> --model <alias>` when the work needs more than the
> `sonnet` default. Entries in older queues still carrying these fields are inert; they are not an
> error, they just do nothing.

---

## #1 — Example ticket (delete me)

**Severity:** Low
**Where:** `path/to/file.ts` (which sub-repo / area)
**Observed:** What's wrong or missing, concretely.
**Fix direction:** The intended approach (not a full design).
**Done when:** The acceptance check that closes this.
**Ref:** Link to a log line / PR / investigation, if any.

---
