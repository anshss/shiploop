---
description: Record durable, git-tracked evidence that a ticket was actually validated (interactive-session twin of the governor's #252 auto-promotion).
allowed-tools: Bash, Read
---
# /shiploop:validated

> **Defer to the workspace-local copy.** If the current workspace has installed its own
> `.claude/commands/validated.md` (every scaffolded shiploop workspace at 1.19.2+ does), follow THAT
> copy: it is pinned to the workspace's harness version and its `scripts/govern/validation-record.sh`.
> This global copy is the fallback for a workspace that predates the extracted sink writer; the
> playbook below is identical in shape, but always run the workspace's own script, never a hub path.


Record a ticket as validated: write the durable, git-tracked evidence summary at
`.claude/shiploop/validation/ticket-<N>-<slug>.md` so this session's proof survives after the ticket
block is gone. `$ARGUMENTS` is the ticket number `<N>` (optionally followed by free-text context,
e.g. `/validated 94 the restore round-tripped clean`).

**Load-bearing division of labor:** you gather and state the evidence; the write itself goes through
`scripts/govern/validation-record.sh`, the SAME script the governor's resolve path calls on a
passing autonomous validation (#252). This command is the interactive twin: before it existed, a
ticket you validated BY HAND in a live session recorded nothing durable, since only a
governor-dispatched resolve ever populated the committed sink founder-os context cites as proof.

## Before calling the script: is what you have actually evidence?

**Reading the source and concluding it looks correct is NOT evidence.** Evidence is empirical: a
real id (deployment id, PR number, request id), real command output, a screenshot, a PASS/FAIL
verdict from something you actually ran or observed this session (a live deploy, a `gstack browse`
walkthrough, a test suite's real output, a database query's actual rows). If all you have is "I read
the code and the logic is right," stop: that is not validation, and recording it as such would
misrepresent what happened. Go run the thing first, or leave the ticket unvalidated.

## What to do

1. **Parse `<N>`** from `$ARGUMENTS` (leading integer). Refuse if it isn't a number.
2. **Find the ticket's title.** If the ticket's `## #N` heading still exists in `queue/tickets.md`
   (or `tickets.md` at the workspace root, check both), read the title from that heading. If the
   block is already gone (you resolved and deleted it earlier this session), use the title you
   already know from that work, never invent one.
3. **Collect the PR(s)**, if any, that this validation rode in on, as `<repo>#<number>` (e.g.
   `alpha#142`). Zero or more.
4. **State the evidence** in your own words: the empirical thing from the section above. Keep it
   to what you actually observed: ids, output, verdict. Multi-line evidence is fine; write it to a
   scratch file and pass `--evidence-file` instead of trying to cram it into one shell argument.
5. **Call the script**:
   ```bash
   bash scripts/govern/validation-record.sh \
     --ticket <N> --title "<title>" \
     --evidence "<what you actually observed, PASS/FAIL and all>" \
     --pr <repo>#<number> \
     --source "interactive session" --gating self
   ```
   Repeat `--pr` for each PR. Omit it entirely when there is none yet.

`--gating self` is not optional and not a formality: it stamps the record as **self-attested**, meaning
you asserted this evidence and nothing mechanical checked it. The resolve path passes `--gating machine`
instead, because a structured report had to claim a real live test before the writer could be reached.
A later reader weighs the two differently, which only works if you never claim the stronger one.

6. **Report the printed path** to the operator (the script prints ONLY the repo-relative path on
   stdout). If it says the file already existed, that means someone already recorded this ticket:
   say so rather than treating it as a failure.

Never clobbers a pre-existing (possibly hand-richer) summary: a second call for the same ticket is
always safe, and simply confirms the existing record. Nothing here writes to `tickets.md`; ticket
bookkeeping (deleting a resolved ticket's block, filing a new one) is the ticket-sweep Stop hook's
job, not this command's.
