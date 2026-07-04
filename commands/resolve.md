---
description: Close out a ticket the disciplined way — confirm its fix PR is open, delete it from tickets.md, promote any durable lesson, then sweep the session for newly-discovered tickets.
allowed-tools: Bash, Read, Edit, Grep, Glob
---

# /shiploop:resolve

Resolve one or more tickets in this meta-repo's `tickets.md`: `/shiploop:resolve <N>` (or
`17-19`, `17,18,19`). Run from the workspace (main checkout or a worktree).

A ticket is **resolved the moment its fix PR is OPENED — not when it merges** (the user won't report
merges session-to-session, so waiting on merge just lets stale tickets pile up). This command enforces
the full close-out so nothing is left half-done.

First, learn the workspace's GitHub org: `source scripts/lib/workspace.sh` (in the main checkout) and
read `$GITHUB_ORG` + `$REPOS` — use them in the `gh` calls below.

## Playbook (follow in order — every step is mandatory)

1. **Read the ticket(s).** Open `tickets.md` (workspace root) and read each `## #N — Title` entry
   named in `$ARGUMENTS`. Note its **Where**, **Fix direction**, and **Done when**.

2. **Confirm the fix actually exists.** For each ticket, verify a fix PR was opened this session (or
   already exists) that satisfies its "Done when". If there's no PR yet, STOP and say so — do not
   delete a ticket whose fix hasn't shipped. Capture the PR number(s):
   ```bash
   gh pr list --repo "$GITHUB_ORG/<sub-repo>" --state open --json number,title,url --limit 20
   ```

3. **Promote the durable lesson FIRST (if any).** If fixing the ticket taught something stable and
   reusable — an env var, a convention, an architecture gotcha, a load-bearing rule — add it to the
   right `CLAUDE.md` (root for cross-repo, sub-repo for scoped) BEFORE deleting the ticket. The git
   history + PR are the only record once the ticket is gone, so the lesson must land somewhere durable.
   A pure "this was a bug, now fixed" with no reusable lesson gets no CLAUDE.md entry — just delete it.

4. **Delete the ticket entry.** Remove the entire `## #N — Title` block from `tickets.md` (heading
   through its trailing `---`). Do NOT annotate it "RESOLVED" and do NOT renumber any other ticket —
   numbers are stable IDs. Leave the surrounding tickets untouched.

5. **Sweep for NEW tickets (the "did I find something new?" pass).** This is the half that always gets
   skipped — do it explicitly. Review everything you touched and discovered en route to this fix:
   - `git diff` / the PR diff across the sub-repos you worked in,
   - any error, log line, mock, hardcoded stub, TODO, or broken-adjacent code you walked past,
   - anything in the ticket's "Where" area that's still wrong but out of this fix's scope.

   For **each** genuinely new bug / gap / missing capability / follow-up, file its own numbered
   `## #N — Title` entry in `tickets.md` with the standard fields: **Severity / Where / Observed /
   Fix direction / Done when / Ref**. File it through the **collision-safe path** —
   `printf '<body>' | scripts/govern/file-ticket.sh "<Title>" <Severity>` — which allocates the
   number via the shared monotonic counter (max of `tickets.md`'s highest `## #N` and
   `governor/.ticket-seq`, +1, serialized under the bookkeep lock), so two concurrent filers (you +
   a running governor) can never reuse a number (#73). Do NOT hand-append a guessed `## #N`. Each
   queue is an independent serial sequence; the parked queue numbers separately. A discovered gap
   ALWAYS goes to `tickets.md` — never `learnings.md`. If the sweep genuinely finds nothing, say
   "no new tickets found" in one line — don't invent filler.

6. **Commit the tickets.md change directly to `main`** in the main checkout (coordination files are
   never branched/PR'd). Reference the resolving PR number(s) so the trail survives the deletion:
   ```bash
   git add tickets.md CLAUDE.md   # CLAUDE.md only if step 3 added to it
   git commit -m "docs(tickets): resolve #<N> — <summary> (<repo>#<PR>)"
   ```

7. **Report.** Per ticket: resolved + PR link, whether a lesson was promoted, and the list of any new
   tickets filed during the sweep (numbers + titles).

> If a resolving PR is later rejected or abandoned, re-file the ticket — a fresh number is fine.
