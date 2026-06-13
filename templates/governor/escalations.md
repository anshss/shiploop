# Governor escalations

Parked decisions awaiting the operator. Workers append here when they hit a hard-stop or a doctrine
gap (they PARK the ticket: clean exit, no PR). Format of an open entry:

```
### #N — <short title>           (under "## Open")
- **Reason:** why it's blocked
- **Question:** the specific decision needed
- **Options:** A / B / C (if known)
- **Answer:** _(operator fills this in)_
- **Disposition:** _(operator: do-the-work | defer | keep-open)_
- **Make this a rule?:** _(yes + the rule text → appended to preferences.md)_
```

## Lifecycle (#62 — escalations are no longer write-only)

The selector skips any ticket # that has an entry under `## Open`, so a parked ticket sits here
until answered. The driver + relay close the loop automatically:

1. **Surface (run-end).** `run-loop.sh` writes `governor/pending-escalations.json` — the still-
   unanswered `## Open` entries — and fires `GOVERN_NOTIFY_CMD` (if set) so a headless, no-session
   run still signals that decisions are waiting.
2. **Ask (relay).** The launching `/govern` session reads that JSON and presents each via
   **AskUserQuestion**, then writes the chosen **Answer** + a canonical **Disposition** token back
   into this file (and "Make this a rule?" if the operator wants it added to the doctrine).
3. **Act (next run-start).** `escalations-apply-answers.sh` reads the recorded answers and DRIVES
   an action — answers stop being inert file text:
   - **`do-the-work`** → un-park: the entry moves to `## Resolved` and the ticket (still in
     `tickets.md`) becomes selectable again, so the governor retries it.
   - **`defer`** (defer-indefinitely / won't-do / keep-manual / close) → the ticket block is
     **auto-migrated** out of `tickets.md` into `tickets-parked.md` (renumbered to that queue's
     max+1) and the entry moves to `## Resolved`. This keeps `tickets.md` the live, govern-workable
     set instead of silently filling with decided-but-undead `## Open` skips.
   - **`keep-open`** / unanswered → left exactly as-is.
   - **Make this a rule?** answered with rule text → appended to `preferences.md`.

When resolved, the entry is moved to `## Resolved` with the answer + a dated resolution note.

## Open

_(none yet)_

## Resolved

_(none yet)_
