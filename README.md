# shiploop on Shiploop

**shiploop** ships on [Shiploop](https://github.com/anshss/shiploop) — a self-improving
multi-agent harness that grinds your ticket backlog across every repo in this workspace
(`shiploop`). A fresh, right-sized headless agent takes each ticket, opens a PR, auto-merges
on green CI where you've allowed it, and writes a durable lesson back into `CLAUDE.md` so the
next run is smarter and cheaper.

## Ship the backlog

```bash
/shiploop:govern          # launch the governor loop over queue/tickets.md
```

Everyday commands:

```bash
npm run status            # what's dirty / ahead / behind across every repo
npm run doctor            # health-check the workspace
/shiploop:investigate     # triage a bug into a ticket
/shiploop:resolve         # close a ticket and promote its lesson into CLAUDE.md
```

Backlog lives in `queue/tickets.md`; per-workspace config in `scripts/lib/workspace.sh`.
Full docs: the `shiploop` skill and <https://github.com/anshss/shiploop>.
